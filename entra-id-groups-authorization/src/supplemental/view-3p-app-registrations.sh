#!/usr/bin/env bash
set -euo pipefail

# ========= INPUTS =========
# Old 1P FPA AppId: dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
# New 1P FPA AppId: bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc
resourceAppId="${1:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}" # Target resource application (AppId)
# =========================

GRAPH_BASE_URL="https://graph.microsoft.com/v1.0"

tenantId="$(az account show --query tenantId -o tsv)"
stderrFile="$(mktemp)"
trap 'rm -f "$stderrFile"' EXIT

echo "=== 3P App Registrations with API Permissions to Resource ==="
echo "Resource AppId: ${resourceAppId}"
echo "Tenant: ${tenantId}"
echo

# Resolve the resource service principal to confirm it exists
echo "=== Resolve Resource Service Principal (by appId) ==="
if ! resourceSpJson=$(az rest -m GET \
  -u "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$resourceAppId'&\$select=id,appId,displayName" \
  -o json 2>"$stderrFile"); then
  stderrText="$(tr '\n' ' ' <"$stderrFile" | sed 's/[[:space:]]\+/ /g')"
  echo "ERROR: Failed to query service principal for appId ${resourceAppId}: ${stderrText}" >&2
  exit 1
fi

resourceSpId="$(jq -r '.value[0].id // empty' <<<"$resourceSpJson")"
resourceDisplayName="$(jq -r '.value[0].displayName // empty' <<<"$resourceSpJson")"

if [[ -n "$resourceSpId" ]]; then
  echo "Resource SP Id: ${resourceSpId}"
  echo "Resource Display Name: ${resourceDisplayName}"
else
  echo "WARNING: Resource service principal not found in this tenant."
  echo "         Will still scan app registrations for requiredResourceAccess references."
fi
echo

# Use OData $filter with lambda any() to query only apps that declare
# requiredResourceAccess referencing the target resource appId.
# This is an advanced query requiring ConsistencyLevel: eventual and $count=true.
echo "=== Scanning App Registrations for requiredResourceAccess referencing ${resourceAppId} ==="
echo

matchCount=0
nextLink="$GRAPH_BASE_URL/applications?\$filter=requiredResourceAccess/any(r:r/resourceAppId eq '$resourceAppId')&\$select=id,appId,displayName,requiredResourceAccess&\$count=true&\$top=100"

while [[ -n "$nextLink" ]]; do
  if ! pageJson=$(az rest -m GET -u "$nextLink" \
    --headers "ConsistencyLevel=eventual" \
    -o json 2>"$stderrFile"); then
    stderrText="$(tr '\n' ' ' <"$stderrFile" | sed 's/[[:space:]]\+/ /g')"
    echo "ERROR: Failed to list applications: ${stderrText}" >&2
    exit 1
  fi

  # Process each matching app returned by the server-side filter
  jq -c --arg targetAppId "$resourceAppId" '
    .value[]
    | {
        appId,
        displayName,
        objectId: .id,
        permissionsToResource: [
          .requiredResourceAccess[]
          | select(.resourceAppId == $targetAppId)
          | .resourceAccess[]
          | {id, type}
        ]
      }
  ' <<<"$pageJson" | while IFS= read -r entry; do
    matchCount=$((matchCount + 1))
    echo "--- Match ---"
    jq '.' <<<"$entry"
    echo
  done

  nextLink="$(jq -r '.["@odata.nextLink"] // empty' <<<"$pageJson")"
done

echo "=== Scan Complete ==="
echo

# Now show the resource-centric view: who has been granted permissions (consent)
if [[ -n "$resourceSpId" ]]; then
  echo "=== Clients with Application Permissions (appRoleAssignedTo) to ${resourceDisplayName} ==="
  assignmentsJson="$(az rest -m GET \
    -u "$GRAPH_BASE_URL/servicePrincipals/$resourceSpId/appRoleAssignedTo" \
    -o json 2>/dev/null || echo '{"value":[]}')"
  assignmentCount="$(jq '.value | length' <<<"$assignmentsJson")"

  if (( assignmentCount > 0 )); then
    jq -c '.value[] | {assignmentId:.id, principalId, principalDisplayName, appRoleId, principalType, createdDateTime}' <<<"$assignmentsJson" | while IFS= read -r entry; do
      jq '.' <<<"$entry"
    done
  else
    echo "(none)"
  fi
  echo

  echo "=== Clients with Delegated Permissions (oauth2PermissionGrants) to ${resourceDisplayName} ==="
  delegatedJson="$(az rest -m GET \
    -u "$GRAPH_BASE_URL/oauth2PermissionGrants?\$filter=resourceId eq '$resourceSpId'" \
    -o json 2>/dev/null || echo '{"value":[]}')"
  delegatedCount="$(jq '.value | length' <<<"$delegatedJson")"

  if (( delegatedCount > 0 )); then
    jq -c '.value[] | {grantId:.id, clientId, scope, consentType, createdDateTime}' <<<"$delegatedJson" | while IFS= read -r entry; do
      jq '.' <<<"$entry"
    done
  else
    echo "(none)"
  fi
  echo

  # For each unique principal from app role assignments, resolve the SP and
  # look up the corresponding app registration to show requiredResourceAccess
  echo "=== Resolving App Registrations from Granted Service Principals ==="
  echo

  mapfile -t principalIds < <(jq -r '
    [.value[] | select(.principalType == "ServicePrincipal") | .principalId]
    | unique
    | .[]
  ' <<<"$assignmentsJson")

  # Also include clientIds from delegated grants
  mapfile -t delegatedClientIds < <(jq -r '
    [.value[].clientId]
    | unique
    | .[]
  ' <<<"$delegatedJson")

  # Merge and deduplicate
  allSpIds=()
  for id in "${principalIds[@]+"${principalIds[@]}"}" "${delegatedClientIds[@]+"${delegatedClientIds[@]}"}"; do
    allSpIds+=("$id")
  done
  mapfile -t uniqueSpIds < <(printf '%s\n' "${allSpIds[@]+"${allSpIds[@]}"}" | sort -u)

  for spId in "${uniqueSpIds[@]+"${uniqueSpIds[@]}"}"; do
    [[ -n "$spId" ]] || continue

    spJson="$(az rest -m GET \
      -u "$GRAPH_BASE_URL/servicePrincipals/$spId?\$select=id,appId,displayName,appOwnerOrganizationId,servicePrincipalType" \
      -o json 2>/dev/null || echo '{}')"

    spAppId="$(jq -r '.appId // empty' <<<"$spJson")"
    spDisplayName="$(jq -r '.displayName // empty' <<<"$spJson")"
    spOwnerOrg="$(jq -r '.appOwnerOrganizationId // empty' <<<"$spJson")"
    spType="$(jq -r '.servicePrincipalType // empty' <<<"$spJson")"

    echo "--- Service Principal: ${spDisplayName:-$spId} ---"
    echo "  SP Object Id: $spId"
    echo "  App Id: ${spAppId:-<unknown>}"
    echo "  Owner Org: ${spOwnerOrg:-<unknown>}"
    echo "  SP Type: ${spType:-<unknown>}"

    if [[ "$spOwnerOrg" == "$tenantId" && -n "$spAppId" ]]; then
      # Customer-owned app — look up the app registration
      appJson="$(az rest -m GET \
        -u "$GRAPH_BASE_URL/applications?\$filter=appId eq '$spAppId'&\$select=id,appId,displayName,requiredResourceAccess" \
        -o json 2>/dev/null || echo '{"value":[]}')"

      appObjectId="$(jq -r '.value[0].id // empty' <<<"$appJson")"
      if [[ -n "$appObjectId" ]]; then
        echo "  App Object Id: $appObjectId"
        echo "  requiredResourceAccess:"
        jq -c --arg targetAppId "$resourceAppId" '
          .value[0].requiredResourceAccess // []
          | map(select(.resourceAppId == $targetAppId))
        ' <<<"$appJson" | jq '.'
      else
        echo "  App Registration: <not found in this tenant — may be external>"
      fi
    else
      echo "  App Registration: <external — owned by org $spOwnerOrg>"
    fi
    echo
  done
fi

echo "=== 3P App Registration Scan Complete ==="
