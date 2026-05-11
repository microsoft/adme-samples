#!/usr/bin/env bash
set -euo pipefail

# ========= INPUTS =========
# Old 1P FPA AppId: dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
# New 1P FPA AppId: bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc
fpaAppId="${1:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}" # 1P FPA/ADME application (AppId)
# =========================

tenantId="$(az account show --query tenantId -o tsv)"
stderrFile="$(mktemp)"
trap 'rm -f "$stderrFile"' EXIT

echo "=== 1P FPA Application Details ==="
echo "AppId: ${fpaAppId}"
echo "Tenant: ${tenantId}"
echo

echo "=== Resolve 1P FPA Service Principal (by appId) ==="
if ! fpaSpId=$(az rest -m GET \
  -u "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '$fpaAppId'" \
  --query "value[0].id" -o tsv 2>"$stderrFile"); then
  stderrText="$(tr '\n' ' ' <"$stderrFile" | sed 's/[[:space:]]\+/ /g')"
  if [[ "$stderrText" == *"Insufficient privileges to complete the operation."* ]]; then
    echo "ERROR: Missing Microsoft Graph directory read permissions to resolve the 1P FPA service principal for appId ${fpaAppId} in tenant ${tenantId}." >&2
  fi
  echo "${stderrText}" >&2
  exit 1
fi

if [[ -n "${fpaSpId}" ]]; then
  echo "fpaSpId: ${fpaSpId}"
else
  echo "fpaSpId: <not found>"
fi
