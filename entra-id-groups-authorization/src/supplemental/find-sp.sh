#!/usr/bin/env bash
set -euo pipefail

# ========= INPUTS =========
# Old 1P FPA AppId: dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
# New 1P FPA AppId: bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc
target_resource="${1:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}" # 1P FPA/ADME application (AppId or identifier URI)
# =========================

GRAPH_BASE_URL="https://graph.microsoft.com/v1.0"
tenantId="$(az account show --query tenantId -o tsv)"
stderrFile="$(mktemp)"
trap 'rm -f "$stderrFile"' EXIT

graph_get_json() {
  local url="$1"
  local stderrText

  if ! az rest -m GET -u "$url" -o json 2>"$stderrFile"; then
    stderrText="$(tr '\n' ' ' <"$stderrFile" | sed 's/[[:space:]]\+/ /g')"
    if [[ "$stderrText" == *"Insufficient privileges to complete the operation."* ]]; then
      echo "ERROR: Missing Microsoft Graph directory read permissions in tenant ${tenantId}." >&2
    fi
    echo "${stderrText}" >&2
    exit 1
  fi
}

graph_get_json_allow_failure() {
  local url="$1"
  az rest -m GET -u "$url" -o json 2>"$stderrFile"
}

is_guid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

resolutionMethod="appId"
spLookupJson=""
appLookupJson='{"value":[]}'

if is_guid "$target_resource"; then
  spLookupJson="$(
    graph_get_json \
      "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$target_resource'&\$select=id,appId,displayName,servicePrincipalNames"
  )"
else
  resolutionMethod="servicePrincipalNames/any()"
  if spLookupJson="$(
    graph_get_json_allow_failure \
      "$GRAPH_BASE_URL/servicePrincipals?\$filter=servicePrincipalNames/any(n:n eq '$target_resource')&\$select=id,appId,displayName,servicePrincipalNames"
  )"; then
    :
  else
    resolutionMethod="applications identifierUris fallback"
    appLookupJson="$(
      graph_get_json \
        "$GRAPH_BASE_URL/applications?\$filter=identifierUris/any(n:n eq '$target_resource')&\$select=id,appId,displayName,identifierUris,api"
    )"
    resolvedAppId="$(jq -r '.value[0].appId // empty' <<<"$appLookupJson")"
    if [[ -n "$resolvedAppId" ]]; then
      spLookupJson="$(
        graph_get_json \
          "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$resolvedAppId'&\$select=id,appId,displayName,servicePrincipalNames"
      )"
    else
      spLookupJson='{"value":[]}'
    fi
  fi

  if [[ "$(jq -r '.value | length' <<<"$spLookupJson")" == "0" ]]; then
    resolutionMethod="applications identifierUris fallback"
    appLookupJson="$(
      graph_get_json \
        "$GRAPH_BASE_URL/applications?\$filter=identifierUris/any(n:n eq '$target_resource')&\$select=id,appId,displayName,identifierUris,api"
    )"
    resolvedAppId="$(jq -r '.value[0].appId // empty' <<<"$appLookupJson")"
    if [[ -n "$resolvedAppId" ]]; then
      spLookupJson="$(
        graph_get_json \
          "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$resolvedAppId'&\$select=id,appId,displayName,servicePrincipalNames"
      )"
    fi
  fi
fi

fpaSpId="$(jq -r '.value[0].id // empty' <<<"$spLookupJson")"
resolvedAppId="$(jq -r '.value[0].appId // empty' <<<"$spLookupJson")"

echo "=== 1P FPA Application Details ==="
echo "Input: ${target_resource}"
echo "Input type: $(if is_guid "$target_resource"; then echo "appId"; else echo "identifierUri"; fi)"
echo "Resolution method: ${resolutionMethod}"
echo "Resolved appId: ${resolvedAppId:-<not found>}"
echo "Tenant: ${tenantId}"
echo

echo "=== Resolve 1P FPA Service Principal ==="
if [[ -n "${fpaSpId}" ]]; then
  echo "fpaSpId: ${fpaSpId}"
else
  echo "fpaSpId: <not found>"
  exit 1
fi
echo

fullSpJson="$(graph_get_json "$GRAPH_BASE_URL/servicePrincipals/$fpaSpId")"
if [[ "$(jq -r '.value | length' <<<"$appLookupJson")" == "0" ]]; then
  appLookupJson="$(
    graph_get_json \
      "$GRAPH_BASE_URL/applications?\$filter=appId eq '$resolvedAppId'&\$select=id,appId,displayName,api"
  )"
fi

echo "=== 1P FPA (ADME) Resource Capability Summary ==="
jq -n \
  --argjson sp "$fullSpJson" '
  ($sp.appRoles // []) as $roles
  | ($sp.oauth2PermissionScopes // []) as $scopes
  | {
      appRoleCount: ($roles | length),
      delegatedScopeCount: ($scopes | length),
      delegatedSupported: (($scopes | length) > 0),
      appOnlySupported: ([$roles[]? | select((.allowedMemberTypes // []) | index("Application"))] | length > 0),
      capability: (
        if (($roles | length) == 0 and ($scopes | length) > 0) then "delegated-only"
        elif (($roles | length) > 0 and ($scopes | length) == 0) then "app-only"
        elif (($roles | length) > 0 and ($scopes | length) > 0) then "mixed"
        else "no-exposed-permissions"
        end
      )
    }'
echo

echo "=== 1P FPA (ADME) Resource SP (appRoles & summary) ==="
jq '{
  id, appId, displayName, servicePrincipalNames,
  appRoles: [.appRoles[]? | {id,value,displayName,allowedMemberTypes,description,origin}],
  signInAudience, appRoleAssignmentRequired
}' <<<"$fullSpJson"
echo

echo "=== 1P FPA (ADME): OAuth2 Permission Scopes (Delegated Permissions) ==="
jq '{
  oauth2PermissionScopes: [.oauth2PermissionScopes[]? | {id,value,adminConsentDisplayName,adminConsentDescription,type,userConsentDisplayName,userConsentDescription,isEnabled}]
}' <<<"$fullSpJson"
echo

echo "=== 1P FPA (ADME): preAuthorizedApplications (Application object) ==="
jq '{
  applicationObjectId: (.value[0].id // "<not found in current tenant>"),
  applicationDisplayName: (.value[0].displayName // "<not found in current tenant>"),
  preAuthorizedApplications: [(.value[0].api.preAuthorizedApplications // [])[]? | {appId,delegatedPermissionIds}],
  note: (
    if (.value | length) == 0 then
      "No local application object found for this appId in the current tenant."
    else
      null
    end
  )
}' <<<"$appLookupJson"
