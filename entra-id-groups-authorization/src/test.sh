#!/usr/bin/env bash
set -euo pipefail

GRAPH_BASE_URL="https://graph.microsoft.com/v1.0"
HOST="${1:-}"
SCOPE_INPUT="${2:-https://energy.azure.com/.default}"
SKIP_ENDPOINT="${3:-}"
stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

if [[ -z "$HOST" ]]; then
  echo "Usage: $0 <adme-instance-host> [audience-or-scope] [--skip-endpoint]" >&2
  exit 1
fi

if [[ -n "$SKIP_ENDPOINT" && "$SKIP_ENDPOINT" != "--skip-endpoint" ]]; then
  echo "Usage: $0 <adme-instance-host> [audience-or-scope] [--skip-endpoint]" >&2
  exit 1
fi

normalize_scope() {
  local value="$1"

  if [[ "$value" == scope:* ]]; then
    printf '%s\n' "${value#scope:}"
  elif [[ "$value" == */.default || "$value" == */access_as_user || "$value" == */user_impersonation ]]; then
    printf '%s\n' "$value"
  else
    printf '%s/.default\n' "$value"
  fi
}

resource_hint_from_scope() {
  local scope="$1"

  case "$scope" in
    */.default)
      printf '%s\n' "${scope%/.default}"
      ;;
    */access_as_user)
      printf '%s\n' "${scope%/access_as_user}"
      ;;
    */user_impersonation)
      printf '%s\n' "${scope%/user_impersonation}"
      ;;
    *)
      printf '%s\n' "$scope"
      ;;
  esac
}

is_guid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

decode_jwt_payload_json() {
  local token="$1"
  local payload padded

  payload="${token#*.}"
  payload="${payload%%.*}"
  case $((${#payload} % 4)) in
    2) padded="${payload}==" ;;
    3) padded="${payload}=" ;;
    0) padded="$payload" ;;
    *) echo "ERROR: Unexpected JWT payload length while decoding token" >&2; exit 1 ;;
  esac

  printf '%s' "$padded" | tr '_-' '/+' | base64 -d 2>/dev/null
}

graph_get_json_allow_failure() {
  local url="$1"
  az rest -m GET -u "$url" -o json 2>"$stderr_file"
}

SCOPE="$(normalize_scope "$SCOPE_INPUT")"
RESOURCE_HINT="$(resource_hint_from_scope "$SCOPE")"
ENDPOINT="https://$HOST"
ENTITLEMENTS_HOST="$ENDPOINT/api/entitlements/v2"

resolve_resource_metadata() {
  local resource_hint="$1"
  local sp_lookup_json='{"value":[]}'
  local app_lookup_json='{"value":[]}'
  local resolved_app_id=""
  local query_result=""

  if is_guid "$resource_hint"; then
    if query_result="$(
      graph_get_json_allow_failure \
        "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$resource_hint'&\$select=id,appId,displayName,servicePrincipalNames,appRoles,oauth2PermissionScopes"
    )"; then
      sp_lookup_json="$query_result"
    else
      return 0
    fi
  else
    if query_result="$(
      graph_get_json_allow_failure \
        "$GRAPH_BASE_URL/servicePrincipals?\$filter=servicePrincipalNames/any(n:n eq '$resource_hint')&\$select=id,appId,displayName,servicePrincipalNames,appRoles,oauth2PermissionScopes"
    )"; then
      sp_lookup_json="$query_result"
    fi

    if [[ "$(jq -r '.value | length' <<<"$sp_lookup_json")" == "0" ]]; then
      if query_result="$(
        graph_get_json_allow_failure \
          "$GRAPH_BASE_URL/applications?\$filter=identifierUris/any(n:n eq '$resource_hint')&\$select=id,appId,displayName,api"
      )"; then
        app_lookup_json="$query_result"
      else
        return 0
      fi
      resolved_app_id="$(jq -r '.value[0].appId // empty' <<<"$app_lookup_json")"
      if [[ -n "$resolved_app_id" ]]; then
        if query_result="$(
          graph_get_json_allow_failure \
            "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$resolved_app_id'&\$select=id,appId,displayName,servicePrincipalNames,appRoles,oauth2PermissionScopes"
        )"; then
          sp_lookup_json="$query_result"
        else
          return 0
        fi
      fi
    fi
  fi

  if [[ "$(jq -r '.value | length' <<<"$sp_lookup_json")" == "0" ]]; then
    return 0
  fi

  if [[ "$(jq -r '.value | length' <<<"$app_lookup_json")" == "0" ]]; then
    resolved_app_id="$(jq -r '.value[0].appId // empty' <<<"$sp_lookup_json")"
    if [[ -n "$resolved_app_id" ]]; then
      if ! query_result="$(
        graph_get_json_allow_failure \
          "$GRAPH_BASE_URL/applications?\$filter=appId eq '$resolved_app_id'&\$select=id,appId,displayName,api"
      )"; then
        query_result='{"value":[]}'
      fi
      app_lookup_json="$query_result"
    fi
  fi

  jq -n \
    --argjson sp "$(jq '.value[0]' <<<"$sp_lookup_json")" \
    --argjson app "$app_lookup_json" '
    ($sp.appRoles // []) as $roles
    | ($sp.oauth2PermissionScopes // []) as $scopes
    | {
        resolved: true,
        appId: $sp.appId,
        displayName: $sp.displayName,
        servicePrincipalNames: ($sp.servicePrincipalNames // []),
        delegatedSupported: (($scopes | length) > 0),
        appOnlySupported: ([$roles[]? | select((.allowedMemberTypes // []) | index("Application"))] | length > 0),
        capability: (
          if (($roles | length) == 0 and ($scopes | length) > 0) then "delegated-only"
          elif (($roles | length) > 0 and ($scopes | length) == 0) then "app-only"
          elif (($roles | length) > 0 and ($scopes | length) > 0) then "mixed"
          else "no-exposed-permissions"
          end
        ),
        preAuthorizedApplications: [($app.value[0].api.preAuthorizedApplications // [])[]? | {appId,delegatedPermissionIds}]
      }'
}

az account show >/dev/null 2>&1 || az login >/dev/null
USER_ACCESS_TOKEN="$(az account get-access-token --scope "$SCOPE" --query accessToken -o tsv)"
claims_json="$(decode_jwt_payload_json "$USER_ACCESS_TOKEN")"
resource_metadata_json="$(resolve_resource_metadata "$RESOURCE_HINT" || true)"

echo "=== ADME Token Test ==="
echo "Host: $HOST"
echo "Audience scope: $SCOPE"
echo "Resource hint: $RESOURCE_HINT"
echo

echo "=== Resource Capability Summary ==="
if [[ -n "$resource_metadata_json" ]]; then
  jq '.' <<<"$resource_metadata_json"
else
  jq -n \
    --arg resource_hint "$RESOURCE_HINT" \
    '{resolved:false, resourceHint:$resource_hint, note:"Unable to resolve service principal metadata in the current tenant; token + JWT claims still provide audience proof."}'
fi
echo

echo "=== Access Token Claims (selected) ==="
jq '{aud, scp, roles}' <<<"$claims_json"
echo

if [[ "$SKIP_ENDPOINT" == "--skip-endpoint" ]]; then
  echo "Skipping ADME entitlements endpoint call because --skip-endpoint was provided."
  exit 0
fi

endpoint_status=0
if az rest --method get --url "$ENTITLEMENTS_HOST/info" \
  --headers "Authorization=Bearer $USER_ACCESS_TOKEN" "Accept=application/json"; then
  :
else
  endpoint_status=$?
fi

exit "$endpoint_status"