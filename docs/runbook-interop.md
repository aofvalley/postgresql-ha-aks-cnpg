# Runbook — Interoperabilidad Flex Server ↔ CNPG-on-AKS

> Demo bidireccional `pg_dump | pg_restore` entre **Azure Database for PostgreSQL — Flexible Server** (PaaS managed) y el cluster CNPG (self-managed sobre AKS). Pensado para el bloque "Interoperabilidad" del run-of-show de Demo (≈ 6-8 min).

## Por qué importa

| Mensaje | Cómo se evidencia en la demo |
|---|---|
| Flex y CNPG **hablan el mismo protocolo** — son el mismo PostgreSQL bajo distinto packaging. | Mismas herramientas (`pg_dump`/`pg_restore`), schema portable sin retoques. |
| **No hay vendor lock-in**: lo que está en Flex se mueve a CNPG y viceversa. | Demo en las dos direcciones, sin tooling propietario. |
| Auth **asimétrica pero ambas passwordless desde el dev**: Entra ID (Flex) y secret gestionado por el operador (CNPG). | `az account get-access-token` para Flex; `kubectl get secret` para CNPG. |
| El **operador del Success Program** las trata como una sola flota. | Mismo runbook, mismo `psql`, mismo dataset moviéndose. |

## Pre-requisitos

| Cosa | Cómo se valida |
|---|---|
| `az login` activo en la suscripción `<your-subscription-name>` | `az account show` |
| Eres AAD admin del Flex `demo-flex-postgres` | `az postgres flexible-server ad-admin list -g rg-existing-flex --server-name demo-flex-postgres` |
| Firewall del Flex permite tu IP (la regla `AllowAllAzureServicesAndResourcesWithinAzureIps` ya cubre el caso) | `az postgres flexible-server firewall-rule list -g rg-existing-flex -n demo-flex-postgres -o table` |
| Cluster CNPG `pg-demo` Healthy en `aks-pgha-demo` | `kubectl --context aks-pgha-demo cnpg status pg-demo -n pg-demo` |
| `pg_dump`/`pg_restore` versión **17+** en el portátil (Flex es PG17) | `pg_dump --version` |

> Si los AKS están parados para ahorrar coste (`make stop`), arranca con `make start` y espera ~10 min.

## Variables (.env)

```bash
FLEX_FQDN=demo-flex-postgres.postgres.database.azure.com
FLEX_RG=rg-existing-flex
FLEX_SERVER=demo-flex-postgres
FLEX_AAD_ADMIN=demo-admin@example.com
INTEROP_DB=app_demo
INTEROP_BLOB_CONTAINER=interop-dumps     # solo usado por el Job bonus
CNPG_LOCAL_PORT=5433
```

## Datasets (intencionadamente ligeros)

| Lado | Tabla | Filas | Por qué esta forma |
|---|---|---|---|
| Flex `app_demo` | `demo_skus(sku_id, ref, family, price_eur, updated_at)` | 5 | Catálogo "operacional", lo típico que vive en PaaS. |
| CNPG `app_demo` | `demo_audit(event_id, event_type, actor, payload jsonb, occurred_at)` | 5 | Cola de auditoría, lo típico que se construye custom en cluster. |

La elección hace evidente al público que **cada lado tiene su propio dato** antes de empezar, y que **el otro lado recibe limpiamente** lo que llega.

## Demo paso a paso

### 0) Setup idempotente (puede ejecutarse antes de la sesión)

```bash
cd poc-postgresql-ha-aks-cnpg
bash scripts/14-demo-interop-bidir.sh prepare
```

Crea `app_demo` en Flex (vía Azure CLI) y en CNPG (vía port-forward + `psql` superuser), siembra las tablas y verifica `count(*)`.

### 1) Flex → CNPG (en vivo)

```bash
bash scripts/14-demo-interop-bidir.sh flex-to-cnpg
```

Lo que verá Demo en pantalla:

1. `pg_dump` saca `demo_skus` de Flex (token AAD via `az`, no password).
2. `pg_restore` la inserta en CNPG (port-forward + secret del operador).
3. Verificación: 5 filas restauradas, y la tabla `demo_audit` del lado CNPG sigue intacta (no contaminada).
4. Tiempo total estampado en ms.

**Mensaje a decir**: *"Mismo formato, ningún driver propietario. El dump que sacaría un dev de Flex se restaura tal cual aquí."*

### 2) CNPG → Flex (en vivo, inverso)

```bash
bash scripts/14-demo-interop-bidir.sh cnpg-to-flex
```

1. `pg_dump` saca `demo_audit` de CNPG.
2. `pg_restore` la inserta en Flex.
3. Verificación: 5 filas en Flex, `demo_skus` intacta del paso anterior.

**Mensaje a decir**: *"El camino inverso es idéntico. Si mañana queréis colapsar CNPG y consolidar en Flex, o al revés, la herramienta es la misma."*

### 3) Cleanup (opcional, post-demo)

```bash
bash scripts/14-demo-interop-bidir.sh cleanup
```

Borra `app_demo` en ambos lados (idempotente; no toca `adventureworks` ni `test01` del Flex).

## Q&A previsto

| Pregunta de Alex | Respuesta corta |
|---|---|
| ¿Por qué `pg_dump` y no replicación lógica? | Para demo en vivo `pg_dump` es determinista y rápido; replicación lógica es viable (`pglogical`, publicaciones nativas) y la dejamos como siguiente paso si quieren CDC continuo Flex↔CNPG. |
| ¿Se puede pipear sin pasar por archivo intermedio? | Sí: `pg_dump … \| pg_restore …`. Usamos archivo temporal solo para reportar el tamaño y poder reusar el dump si la demo falla a media. |
| ¿Y si quisierais correrlo en un Job de Kubernetes con identidad? | Está documentado el manifest `manifests/11-interop-job.yaml`. Ver sección "Bonus" abajo. |
| ¿Funciona también con extensiones (postgis, pgvector)? | Si la extensión está disponible en ambos lados (Flex permite-list + CNPG image), sí. El dump no incluye binarios, solo `CREATE EXTENSION`. |
| ¿Y la versión? Flex es 17, CNPG es 16. | Por ahora limitamos el dataset a features compatibles con 16. La práctica recomendada es alinear versiones; CNPG 17 está soportado, alinearlos es un Bicep+Cluster CR refresh. |

## Bonus — versión "in-cluster" con Workload Identity

Para CI/CD que orqueste migraciones desde **dentro** del cluster sin password en ningún lado, el manifest `manifests/11-interop-job.yaml` muestra el patrón:

- `ServiceAccount` `pg-interop` anotado con `azure.workload.identity/client-id` apuntando a la UAMI `mi-stpghademo7141-backup` (la misma que ya hace Barman backups).
- `FederatedIdentityCredential` nueva: `fic-pg-interop-pg-demo` con subject `system:serviceaccount:pg-demo:pg-interop`.
- En Flex, se registra esa UAMI como rol AAD via `pgaadauth_create_principal('mi-stpghademo7141-backup', false, false)` + GRANTs.
- El Job intercambia el SA-token de K8s por un AAD token contra `ossrdbms-aad.database.windows.net/.default` y lo usa como `PGPASSWORD` para `pg_dump`/`pg_restore`.

**No se ejecuta en la sesión** (para no añadir riesgo en directo). Se enseña el YAML en pantalla si Alex pide ver el caso "CI/CD passwordless".

Comandos para configurarlo una vez:

```bash
# 1. Federated credential
OIDC=$(az aks show -g rg-pgha-demo -n aks-pgha-demo \
        --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create \
  --name fic-pg-interop-pg-demo \
  --identity-name mi-stpghademo7141-backup \
  --resource-group rg-pgha-demo \
  --issuer "$OIDC" \
  --subject system:serviceaccount:pg-demo:pg-interop \
  --audiences api://AzureADTokenExchange

# 2. AAD principal en Flex (conectado como AAD admin)
PGPASSWORD=$(az account get-access-token --resource https://ossrdbms-aad.database.windows.net --query accessToken -o tsv) \
psql "host=demo-flex-postgres.postgres.database.azure.com sslmode=require user=demo-admin@example.com dbname=postgres" \
  -c "SELECT * FROM pgaadauth_create_principal('mi-stpghademo7141-backup', false, false);"

# 3. Ejecutar el Job
kubectl --context aks-pgha-demo apply -f manifests/11-interop-job.yaml
kubectl --context aks-pgha-demo -n pg-demo logs -f job/pg-interop-flex-to-cnpg
```

## Troubleshooting rápido

| Síntoma | Causa probable | Fix |
|---|---|---|
| `psql: server closed the connection unexpectedly` contra Flex | Firewall bloqueando tu IP | `az postgres flexible-server firewall-rule create ... --start-ip-address <tu-IP>` |
| `FATAL: AADSTS70011: scope is not valid` | Token solicitado para resource incorrecto | El script usa `https://ossrdbms-aad.database.windows.net`. Verifica que `az account get-access-token --resource` lo refleja. |
| `pg_restore: warning: errors ignored on restore` | Tipo o feature v17-only en el dump | Acota a `--no-publications --no-subscriptions` (ya activado) y verifica que el schema no usa `MERGE WHEN NOT MATCHED BY SOURCE` u otras 17-isms. |
| Port-forward muere a mitad | El pod primario rotó (failover) | Re-ejecuta el comando; el script crea uno nuevo automáticamente. |
| `permission denied for schema public` en Flex | UAMI sin GRANTs | Re-ejecuta el bloque GRANT del paso 2 del bonus. |

## Referencias

- [Microsoft Learn — Use Microsoft Entra ID for authentication with Flexible Server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Microsoft Learn — Workload Identity en AKS](https://learn.microsoft.com/azure/aks/workload-identity-overview)
- [PostgreSQL docs — pg_dump / pg_restore](https://www.postgresql.org/docs/17/app-pgdump.html)
- [CloudNativePG — Connect to a cluster](https://cloudnative-pg.io/documentation/current/connection_pooling/)
