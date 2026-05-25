#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — verify local CLI prerequisites
# ============================================================================
set -euo pipefail

REQUIRED=(
  "az:2.56.0"
  "kubectl:1.28.0"
  "helm:3.12.0"
  "jq:1.5"
)

echo "=========================================================================="
echo " Checking local CLI prerequisites"
echo "=========================================================================="

ok=0
fail=0

semver_ge() {
  # returns 0 if $1 >= $2 (lexicographically per dotted segment)
  [[ "$(printf '%s\n%s' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

check() {
  local bin="$1" min="$2" version
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FAIL] ${bin} not found in PATH (need >= ${min})"
    fail=$((fail + 1))
    return
  fi
  case "$bin" in
    az)      version=$(az version 2>/dev/null | jq -r '."azure-cli"') ;;
    kubectl) version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' | sed 's/^v//') ;;
    helm)    version=$(helm version --short 2>/dev/null | sed -E 's/^v([0-9.]+).*/\1/') ;;
    jq)      version=$(jq --version 2>/dev/null | sed 's/^jq-//') ;;
    *)       version="?" ;;
  esac
  if semver_ge "${version}" "${min}"; then
    echo "[ OK ] ${bin} ${version} (>= ${min})"
    ok=$((ok + 1))
  else
    echo "[WARN] ${bin} ${version} found but minimum is ${min}"
    fail=$((fail + 1))
  fi
}

for entry in "${REQUIRED[@]}"; do
  check "${entry%%:*}" "${entry##*:}"
done

echo "--------------------------------------------------------------------------"
echo " Optional plugins"
echo "--------------------------------------------------------------------------"

if command -v kubectl >/dev/null 2>&1 && kubectl krew version >/dev/null 2>&1; then
  echo "[ OK ] kubectl-krew installed"
  if kubectl plugin list 2>/dev/null | grep -q "kubectl-cnpg"; then
    cnpg_ver=$(kubectl cnpg version 2>/dev/null | head -1 || echo "unknown")
    echo "[ OK ] kubectl-cnpg plugin (${cnpg_ver})"
  else
    echo "[WARN] kubectl-cnpg not installed. Run: kubectl krew install cnpg"
  fi
else
  echo "[WARN] krew not installed. Install per https://krew.sigs.k8s.io/docs/user-guide/setup/install/"
fi

echo "=========================================================================="
echo " Result: ${ok} OK, ${fail} warnings/failures"
echo "=========================================================================="
exit 0
