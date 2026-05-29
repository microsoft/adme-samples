#!/usr/bin/env bash
set -euo pipefail

# ========= INPUTS =========
fpaAppId="${1:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}" # 1P FPA/ADME application (AppId)
roleValueFilter="${2:-ADME.ApplicationAccess}"        # expected app role value
# =========================

GRAPH_BASE_URL="https://graph.microsoft.com/v1.0"
tenant_id="$(az account show --query tenantId -o tsv)"
stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

graph_get_json() {
  local url="$1"
  local stderr_text

  if ! az rest -m GET -u "$url" -o json 2>"$stderr_file"; then
    stderr_text="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g')"
    echo "ERROR: Graph request failed for tenant ${tenant_id}: ${stderr_text}" >&2
    exit 1
  fi
}

echo "=== 1P FPA Application Details ==="
echo "Tenant: ${tenant_id}"
echo

echo "=== Resolve 1P FPA Service Principal (by appId) ==="
sp_lookup_json="$(
  graph_get_json \
    "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$fpaAppId'&\$select=id,appId,displayName"
)"
fpaResSpId="$(jq -r '.value[0].id // empty' <<<"$sp_lookup_json")"
echo "fpaResSpId: ${fpaResSpId:-<not found>}"
echo

if [[ -z "${fpaResSpId:-}" ]]; then
  echo "ERROR: 1P FPA Service Principal not found. Cannot proceed."
  exit 1
fi

full_sp_json="$(graph_get_json "$GRAPH_BASE_URL/servicePrincipals/$fpaResSpId")"
app_lookup_json="$(
  graph_get_json \
    "$GRAPH_BASE_URL/applications?\$filter=appId eq '$fpaAppId'&\$select=id,appId,displayName,api"
)"
roleId="$(
  jq -r \
    --arg role_value "$roleValueFilter" \
    '[.appRoles[]? | select(.value == $role_value)][0].id // empty' \
    <<<"$full_sp_json"
)"

echo "=== 1P FPA (ADME) Resource Capability Summary ==="
jq -n \
  --argjson sp "$full_sp_json" \
  --arg role_id "${roleId:-}" '
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
      ),
      roleIdForFilter: (if $role_id == "" then "<not found>" else $role_id end)
    }'
echo

# 1) FPA Resource Service Principal – role definitions
echo "=== 1P FPA (ADME) Resource SP (appRoles & summary) ==="
jq '{
  id, appId, displayName, servicePrincipalNames,
  appRoles: [.appRoles[]? | {id,value,displayName,allowedMemberTypes,description,origin}],
  signInAudience, appRoleAssignmentRequired
}' <<<"$full_sp_json"
echo

echo "=== 1P FPA (ADME): OAuth2 Permission Scopes (Delegated Permissions) ==="
jq '{
  oauth2PermissionScopes: [.oauth2PermissionScopes[]? | {id,value,adminConsentDisplayName,adminConsentDescription,type,userConsentDisplayName,userConsentDescription,isEnabled}]
}' <<<"$full_sp_json"
echo

echo "=== 1P FPA (ADME): preAuthorizedApplications (Application object) ==="
jq '{
  applicationObjectId: (.value[0].id // "<not found in current tenant>"),
  applicationDisplayName: (.value[0].displayName // "<not found in current tenant>"),
  preAuthorizedApplications: [(.value[0].api.preAuthorizedApplications // [])[]? | {appId,delegatedPermissionIds}],
  note: (
    if (.value | length) == 0 then
      "No local application object found for this appId in the current tenant. This is expected for first-party apps such as dffa/bd0c."
    else
      null
    end
  )
}' <<<"$app_lookup_json"
echo

echo "=== 1P FPA (ADME): resolve appRoleId for '$roleValueFilter' ==="
echo "roleId for $roleValueFilter: ${roleId:-<not found>}"
echo

# 2) Who is granted to FPA? (resource-centric view)
echo "=== 1P FPA (ADME): clients with Application Permissions (appRoleAssignedTo) ==="
app_assignments_json="$(graph_get_json "$GRAPH_BASE_URL/servicePrincipals/$fpaResSpId/appRoleAssignedTo")"
jq '.value[]? | {assignmentId:.id, principalId, appRoleId, createdDateTime}' <<<"$app_assignments_json"
echo

echo "=== 1P FPA (ADME): clients with Delegated Permissions (oauth2PermissionGrants to FPA resource) ==="
delegated_grants_json="$(
  graph_get_json \
    "$GRAPH_BASE_URL/oauth2PermissionGrants?\$filter=resourceId eq '$fpaResSpId'"
)"
jq '.value[]? | {grantId:.id, clientId, scope, consentType, createdDateTime, expiryTime}' <<<"$delegated_grants_json"
echo

# 3) Enterprise App facets
echo "=== 1P FPA (ADME) Enterprise App (SP) – owners & assignment flags ==="
owners_json="$(graph_get_json "$GRAPH_BASE_URL/servicePrincipals/$fpaResSpId/owners")"
jq '.value[]? | {id,displayName,userPrincipalName,appId}' <<<"$owners_json"
jq '{id,displayName,appRoleAssignmentRequired,accountEnabled,tags}' <<<"$full_sp_json"
echo

echo "=== 1P FPA Details Complete ==="
