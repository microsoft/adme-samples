#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  refresh-1p-app-sp.sh [apply|cleanup|show] [appId] [state-file]

Commands:
  apply    Add a unique temporary tag to the existing service principal to trigger an in-place refresh.
  cleanup  Restore the original tags from the saved state file.
  show     Print the current service principal summary.

Defaults:
  appId defaults to dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
  state-file defaults to /tmp/entra-sp-refresh-<appId>.json

Examples:
  ./refresh-1p-app-sp.sh show
  ./refresh-1p-app-sp.sh apply
  ./refresh-1p-app-sp.sh cleanup
  ./refresh-1p-app-sp.sh apply bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc /tmp/bd0c-refresh.json
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_command az
require_command jq

command_name="${1:-show}"
fpaAppId="${2:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}"
stateFile="${3:-/tmp/entra-sp-refresh-${fpaAppId}.json}"

service_principal_json() {
  local sp_id="$1"
  az rest -m GET \
    -u "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id" -o json
}

resolve_sp_id() {
  az rest -m GET \
    -u "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '$fpaAppId'" \
    --query "value[0].id" -o tsv 2>/dev/null || true
}

expected_service_principal_names_json() {
  case "$1" in
    dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e)
      jq -cn --arg appId "$1" --arg oldUri "https://energy-old.azure.com" --arg sharedUri "https://energy.azure.com" \
        '[$appId, $oldUri, $sharedUri]'
      ;;
    bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc)
      jq -cn --arg appId "$1" --arg apiUri "api://$1" --arg newUri "https://energy-new.azure.com" --arg sharedUri "https://energy.azure.com" \
        '[$appId, $apiUri, $newUri, $sharedUri]'
      ;;
    *)
      jq -cn --arg appId "$1" '[$appId]'
      ;;
  esac
}

validated_service_principal_json() {
  local sp_id="$1"
  local expected_app_id="$2"
  local sp_json expected_names_json

  sp_json="$(service_principal_json "$sp_id")"
  expected_names_json="$(expected_service_principal_names_json "$expected_app_id")"

  jq -e \
    --arg appId "$expected_app_id" \
    --argjson expectedNames "$expected_names_json" '
      (.servicePrincipalNames // []) as $actualNames
      |
      .appId == $appId
      and ((.displayName // "") | length > 0)
      and all($expectedNames[]; . as $expectedName | ($actualNames | index($expectedName) != null))
    ' <<<"$sp_json" >/dev/null || die "Resolved service principal $sp_id does not match the expected identity for appId $expected_app_id"

  printf '%s\n' "$sp_json"
}

show_sp() {
  local spId="$1"
  service_principal_json "$spId" | jq '{
      id,
      appId,
      displayName,
      servicePrincipalNames,
      tags,
      appOwnerOrganizationId,
      accountEnabled
    }'
}

spId="$(resolve_sp_id)"
[[ -n "$spId" && "$spId" != "null" ]] || die "Service principal for appId $fpaAppId was not found in the current tenant."

case "$command_name" in
  show)
    echo "Tenant: $(az account show --query tenantId -o tsv)"
    echo "AppId: $fpaAppId"
    echo "ServicePrincipalId: $spId"
    show_sp "$spId"
    ;;
  apply)
    spJson="$(validated_service_principal_json "$spId" "$fpaAppId")"
    originalTags="$(jq -c '.tags // []' <<<"$spJson")"

    refreshTag="ADME.RefreshProbe.$(date -u +%Y%m%dT%H%M%SZ).$(printf '%s' "${fpaAppId}-$$-$(date -u +%s)" | sha256sum | cut -c1-8)"
    patchedTags="$(jq -cn --argjson tags "$originalTags" --arg refreshTag "$refreshTag" '$tags + [$refreshTag] | unique')"

    jq -cn \
      --arg appId "$fpaAppId" \
      --arg spId "$spId" \
      --arg refreshTag "$refreshTag" \
      --argjson originalTags "$originalTags" \
      '{appId: $appId, spId: $spId, refreshTag: $refreshTag, originalTags: $originalTags}' >"$stateFile"

    az rest -m PATCH \
      -u "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" \
      --body "$(jq -cn --argjson tags "$patchedTags" '{tags: $tags}')" >/dev/null

    echo "Applied refresh tag: $refreshTag"
    echo "State file: $stateFile"
    show_sp "$spId"
    ;;
  cleanup)
    [[ -f "$stateFile" ]] || die "State file not found: $stateFile"

    restoreAppId="$(jq -r '.appId' "$stateFile")"
    restoreSpId="$(jq -r '.spId' "$stateFile")"
    restoreTags="$(jq -c '.originalTags' "$stateFile")"
    [[ "$restoreAppId" == "$fpaAppId" ]] || die "State file appId $restoreAppId does not match requested appId $fpaAppId"
    validated_service_principal_json "$restoreSpId" "$restoreAppId" >/dev/null

    az rest -m PATCH \
      -u "https://graph.microsoft.com/v1.0/servicePrincipals/$restoreSpId" \
      --body "$(jq -cn --argjson tags "$restoreTags" '{tags: $tags}')" >/dev/null

    echo "Restored tags from: $stateFile"
    show_sp "$restoreSpId"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $command_name"
    ;;
esac
