#!/usr/bin/env bash
#
# adme-entra-migration.sh
# =======================
# Customer-facing helper for the ADME Entra ID app migration.
#
# Why this script exists
# ----------------------
# Microsoft is replacing the "Azure Data Manager for Energy" (ADME) first-party
# Entra app:
#
#     old (dffa): dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
#     new (bd0c): bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc
#
# Customer tenants that currently depend on the old app need to refresh the old
# service principal, provision the new one, move client-app permissions, and
# verify the resulting token paths.
#
# What this script does today
# ---------------------------
#   * migrate adme-audience
#       - refreshes the old resource service principal in the customer tenant
#       - ensures the new resource service principal exists
#       - ensures Microsoft Azure CLI has the delegated grant needed for the
#         new ADME scope
#   * migrate api-permissions
#       - patches the configured client app toward the new ADME
#         requiredResourceAccess
#       - by default, prints one tenant-wide admin-consent action for the
#         customer app after the manifest update
#       - with --auto-grant, creates both the new ADME app-role assignment and
#         delegated grant for the client app
#   * verify
#       - validates customer-tenant state, grant wiring, and the post-migration
#         token paths
#
# Idempotency and operator expectations
# -------------------------------------
# The mutating commands are intended to be safe to re-run:
#   * migrate adme-audience rechecks current state before patching/creating
#     objects
#   * migrate api-permissions validates and reapplies the target client-app
#     configuration as needed
# verify is read-only with respect to Microsoft Graph, although it can request
# tokens using the configured Azure CLI and client-app credentials.
#
# Required roles and access
# -------------------------
#   * migrate adme-audience / migrate api-permissions:
#       Application Administrator, Cloud Application Administrator, or Global
#       Administrator in the customer tenant
#   * verify:
#       Azure CLI access to the target tenant
#
# Prerequisites
# -------------
#   * Azure Cloud Shell is the recommended execution environment
#   * Required tools on PATH: az, jq
#   * Additional tool used by verify: base64
#   * Optional for the enhanced delegated verify proof: python3 with the msal
#     package
#   * Sign in before running: az login --tenant <tenant-id>
#   * If you use AZURE_CONFIG_DIR, set it in the shell before running this script
#
# Current workflow limits
# -----------------------
#   * This is a single-client-app operational script, not a batch migration
#     tool
#   * It does not perform Azure portal follow-up steps for the operator
#   * The default client-app consent path remains operator-visible via one
#     tenant-wide admin-consent action
#   * It validates customer-tenant state only; home-tenant application checks
#     are not part of the customer workflow
#   * Every run writes structured INFO/WARN/ERROR lines to stderr and to a
#     timestamped log file under ./migration-logs/ unless --output-logging
#     overrides the directory
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/adme-entra-migration"
STATE_DIR_EXPLICIT=0
OUTPUT_LOGGING_DIR="./migration-logs"
LOG_FILE=""
ASSUME_YES=0
AUTO_GRANT=0
ALLOW_RECREATE_DFFA=0
APP_REGISTRATIONS_PORTAL_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"

CUSTOMER_TENANT_ID=""
CUSTOMER_CONFIG_DIR=""

OLD_RESOURCE_APP_ID="${OLD_RESOURCE_APP_ID:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}"
NEW_RESOURCE_APP_ID="${NEW_RESOURCE_APP_ID:-bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc}"
OLD_RESOURCE_IDENTIFIER_URI="${OLD_RESOURCE_IDENTIFIER_URI:-https://energy-old.azure.com}"
NEW_RESOURCE_IDENTIFIER_URI="${NEW_RESOURCE_IDENTIFIER_URI:-https://energy.azure.com}"
OLD_RESOURCE_SERVICE_PRINCIPAL_ID="${OLD_RESOURCE_SERVICE_PRINCIPAL_ID:-}"
NEW_RESOURCE_APP_ROLE_ID="${NEW_RESOURCE_APP_ROLE_ID:-f1454897-e4e4-440e-9e04-bc379d7629f7}"
NEW_RESOURCE_APP_ROLE_VALUE="${NEW_RESOURCE_APP_ROLE_VALUE:-ADME.ApplicationAccess}"
NEW_RESOURCE_SCOPE_ID="${NEW_RESOURCE_SCOPE_ID:-66e904da-2872-4e72-bff6-a88a6c4375ea}"
NEW_RESOURCE_SCOPE_VALUE="${NEW_RESOURCE_SCOPE_VALUE:-access_as_user}"
CLIENT_APP_ID="${CLIENT_APP_ID:-}"
CLIENT_APP_OBJECT_ID="${CLIENT_APP_OBJECT_ID:-}"
CLIENT_SERVICE_PRINCIPAL_ID="${CLIENT_SERVICE_PRINCIPAL_ID:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"

AZURE_CLI_APP_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"

REQUIRED_ROLE_NAMES=(
  "Application Administrator"
  "Cloud Application Administrator"
  "Global Administrator"
)

usage() {
  cat <<'EOF'
Usage:
  adme-entra-migration.sh [--output-logging dir] [--yes] migrate adme-audience [--allow-recreate-dffa]
  adme-entra-migration.sh [--output-logging dir] [--yes] migrate api-permissions [--auto-grant]
  adme-entra-migration.sh [--output-logging dir] verify

Commands:
  migrate adme-audience    Refresh the stale old-resource service principal, provision the new resource service principal, and wire the Azure CLI delegated grant.
                             --allow-recreate-dffa: if refresh stays stale after bounded retries, allow a delete/recreate fallback with explicit confirmation.
  migrate api-permissions  Update the client app to the new resource permissions.
                             Default: update requiredResourceAccess only and print one tenant-wide admin-consent action for both customer-app grants.
                             --auto-grant: create both the new app-role assignment and delegated grant programmatically.
                             Requires Application Administrator, Cloud Application Administrator, or Global Administrator.
  verify                 Validate the post-migration state and both post-migration token paths.
                           Uses az + jq only; python3 + msal enables an extra forced-refresh delegated-token proof.

Options:
  --output-logging dir Directory for structured log files. Defaults to ./migration-logs.
  --yes                 Skip the interactive confirmation prompt in TTY mode.
  --allow-recreate-dffa Only for migrate adme-audience. After refresh failure, allow the destructive dffa delete/recreate fallback.
  --auto-grant          Only for migrate api-permissions. Create both the customer-app app-role assignment and delegated grant programmatically.
  -h, --help            Show this help text.

Prerequisites:
  Required tools: az, jq
  Additional tool used by verify: base64
  Optional for enhanced delegated verify proof: python3 with the msal package
  See entra-id-groups-authorization/PREREQUISITES.md for Cloud Shell and Linux/WSL setup guidance.
EOF
}

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

init_logging() {
  mkdir -p "$OUTPUT_LOGGING_DIR"
  LOG_FILE="$OUTPUT_LOGGING_DIR/adme-entra-migration-$(date -u +%Y%m%dT%H%M%SZ).log"
  : >"$LOG_FILE"
}

log() {
  local level="$1"
  shift
  local line

  line="$(printf '%s [%s] %s' "$(timestamp)" "$level" "$*")"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

log_step() {
  log INFO "STEP: $*"
}

log_success() {
  log INFO "OK: $*"
}

log_warn() {
  log WARN "$*"
}

die() {
  log ERROR "$*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_az() {
  local config_dir="$1"
  shift

  if [[ -n "$config_dir" ]]; then
    AZURE_CONFIG_DIR="$config_dir" az "$@"
  else
    az "$@"
  fi
}

graph_request_json() {
  local config_dir="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"

  if [[ -n "$body" ]]; then
    run_az "$config_dir" rest --method "$method" --url "$url" --body "$body" -o json
  else
    run_az "$config_dir" rest --method "$method" --url "$url" -o json
  fi
}

current_tenant_id() {
  local config_dir="$1"
  run_az "$config_dir" account show --query tenantId -o tsv
}

current_config_dir() {
  if [[ -n "${CUSTOMER_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$CUSTOMER_CONFIG_DIR"
  elif [[ -n "${AZURE_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$AZURE_CONFIG_DIR"
  else
    printf '\n'
  fi
}

service_principal_json_by_id() {
  local config_dir="$1"
  local sp_id="$2"

  graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id"
}

service_principal_exists_by_id() {
  local config_dir="$1"
  local sp_id="$2"

  run_az "$config_dir" rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id" >/dev/null 2>&1
}

old_resource_service_principal_is_refreshed() {
  local sp_json="$1"

  jq -e --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($old) != null and index($shared) == null
  ' <<<"$sp_json" >/dev/null
}

old_resource_service_principal_has_stale_shared_audience() {
  local sp_json="$1"

  jq -e --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($old) != null and index($shared) != null
  ' <<<"$sp_json" >/dev/null
}

new_resource_service_principal_owns_shared_audience() {
  local sp_json="$1"

  jq -e --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($shared) != null
  ' <<<"$sp_json" >/dev/null
}

assert_tenant() {
  local label="$1"
  local config_dir="$2"
  local expected_tenant_id="$3"
  local actual_tenant_id

  actual_tenant_id="$(current_tenant_id "$config_dir")"
  [[ "$actual_tenant_id" == "$expected_tenant_id" ]] || die "$label Azure CLI context is tenant $actual_tenant_id, expected $expected_tenant_id"
  log_success "$label Azure CLI context is ready for tenant $expected_tenant_id"
}

ensure_not_placeholder() {
  local var_name="$1"
  local var_value="$2"

  if [[ "$var_value" == *"<"* && "$var_value" == *">"* ]]; then
    die "$var_name still contains a placeholder value — update it in your config file"
  fi
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
    *) die "Unexpected JWT payload length while decoding token" ;;
  esac

  printf '%s' "$padded" | tr '_-' '/+' | base64 -d 2>/dev/null
}

python3_has_msal() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import msal' >/dev/null 2>&1
}

load_runtime_state() {
  local state_env_file=""
  local state_source="environment"
  local client_secret_override=""
  local has_client_secret_override=0
  local var_name=""
  local placeholder_vars=()

  if [[ -n "${CLIENT_SECRET:-}" ]]; then
    client_secret_override="$CLIENT_SECRET"
    has_client_secret_override=1
  fi

  if [[ "$STATE_DIR_EXPLICIT" -eq 1 ]]; then
    state_env_file="$STATE_DIR/sim-state.env"
    [[ -f "$state_env_file" ]] || die "Runtime state file not found: $state_env_file"
    # shellcheck disable=SC1090
    source "$state_env_file"
    state_source="$state_env_file"
  fi

  if [[ "$has_client_secret_override" -eq 1 ]]; then
    CLIENT_SECRET="$client_secret_override"
  fi

  CUSTOMER_TENANT_ID="${CUSTOMER_TENANT_ID:-}"
  CUSTOMER_CONFIG_DIR="$(current_config_dir)"
  NEW_RESOURCE_IDENTIFIER_URI="${NEW_RESOURCE_IDENTIFIER_URI:-}"
  OLD_RESOURCE_IDENTIFIER_URI="${OLD_RESOURCE_IDENTIFIER_URI:-}"
  OLD_RESOURCE_APP_ID="${OLD_RESOURCE_APP_ID:-}"
  OLD_RESOURCE_SERVICE_PRINCIPAL_ID="${OLD_RESOURCE_SERVICE_PRINCIPAL_ID:-}"
  NEW_RESOURCE_APP_ID="${NEW_RESOURCE_APP_ID:-}"
  NEW_RESOURCE_APP_ROLE_ID="${NEW_RESOURCE_APP_ROLE_ID:-}"
  NEW_RESOURCE_APP_ROLE_VALUE="${NEW_RESOURCE_APP_ROLE_VALUE:-}"
  NEW_RESOURCE_SCOPE_ID="${NEW_RESOURCE_SCOPE_ID:-}"
  NEW_RESOURCE_SCOPE_VALUE="${NEW_RESOURCE_SCOPE_VALUE:-}"
  CLIENT_APP_ID="${CLIENT_APP_ID:-}"
  CLIENT_APP_OBJECT_ID="${CLIENT_APP_OBJECT_ID:-}"
  CLIENT_SERVICE_PRINCIPAL_ID="${CLIENT_SERVICE_PRINCIPAL_ID:-}"
  CLIENT_SECRET="${CLIENT_SECRET:-}"

  placeholder_vars=(
    OLD_RESOURCE_APP_ID
    OLD_RESOURCE_IDENTIFIER_URI
    NEW_RESOURCE_APP_ID
    NEW_RESOURCE_IDENTIFIER_URI
  )

  case "$COMMAND/$SUBCOMMAND" in
    migrate/adme-audience)
      placeholder_vars+=(
        OLD_RESOURCE_SERVICE_PRINCIPAL_ID
        NEW_RESOURCE_SCOPE_VALUE
      )
      ;;
    migrate/api-permissions)
      placeholder_vars+=(
        NEW_RESOURCE_APP_ROLE_ID
        NEW_RESOURCE_APP_ROLE_VALUE
        NEW_RESOURCE_SCOPE_ID
        NEW_RESOURCE_SCOPE_VALUE
        CLIENT_APP_ID
        CLIENT_APP_OBJECT_ID
        CLIENT_SERVICE_PRINCIPAL_ID
      )
      ;;
    verify/)
      placeholder_vars+=(
        OLD_RESOURCE_SERVICE_PRINCIPAL_ID
        NEW_RESOURCE_SCOPE_VALUE
        CLIENT_APP_ID
        CLIENT_SERVICE_PRINCIPAL_ID
      )
      ;;
    *)
      die "Unsupported command for runtime-state validation: $COMMAND/$SUBCOMMAND"
      ;;
  esac

  for var_name in "${placeholder_vars[@]}"; do
    [[ -n "${!var_name}" ]] || continue
    ensure_not_placeholder "$var_name" "${!var_name}"
  done

  if [[ -z "$CUSTOMER_TENANT_ID" ]]; then
    CUSTOMER_TENANT_ID="$(current_tenant_id "$CUSTOMER_CONFIG_DIR")"
  fi

  if [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] && ! service_principal_exists_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID"; then
    log_warn "Configured OLD_RESOURCE_SERVICE_PRINCIPAL_ID $OLD_RESOURCE_SERVICE_PRINCIPAL_ID was not found; resolving the old resource service principal again by appId $OLD_RESOURCE_APP_ID"
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID=""
  fi

  if [[ -z "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]]; then
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_APP_ID")"
  fi

  case "$COMMAND/$SUBCOMMAND" in
    migrate/adme-audience)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] || die "OLD_RESOURCE_SERVICE_PRINCIPAL_ID could not be resolved for appId $OLD_RESOURCE_APP_ID"
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
      ;;
    migrate/api-permissions)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$NEW_RESOURCE_APP_ROLE_ID" ]] || die "NEW_RESOURCE_APP_ROLE_ID is required from $state_source or the environment"
      [[ -n "$NEW_RESOURCE_APP_ROLE_VALUE" ]] || die "NEW_RESOURCE_APP_ROLE_VALUE is required from $state_source or the environment"
      [[ -n "$NEW_RESOURCE_SCOPE_ID" ]] || die "NEW_RESOURCE_SCOPE_ID is required from $state_source or the environment"
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
      [[ -n "$CLIENT_APP_ID" ]] || die "CLIENT_APP_ID is required from $state_source or the environment"
      [[ -n "$CLIENT_APP_OBJECT_ID" ]] || die "CLIENT_APP_OBJECT_ID is required from $state_source or the environment"
      [[ -n "$CLIENT_SERVICE_PRINCIPAL_ID" ]] || die "CLIENT_SERVICE_PRINCIPAL_ID is required from $state_source or the environment"
      ;;
    verify/)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] || die "OLD_RESOURCE_SERVICE_PRINCIPAL_ID could not be resolved for appId $OLD_RESOURCE_APP_ID"
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
      [[ -n "$CLIENT_APP_ID" ]] || die "CLIENT_APP_ID is required from $state_source or the environment"
      [[ -n "$CLIENT_SERVICE_PRINCIPAL_ID" ]] || die "CLIENT_SERVICE_PRINCIPAL_ID is required from $state_source or the environment"
      ;;
    *)
      die "Unsupported runtime-state command context: $COMMAND ${SUBCOMMAND:-}"
      ;;
  esac
}

find_service_principal_id_by_app_id() {
  local config_dir="$1"
  local app_id="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '$app_id'" \
    | jq -r '.value[0].id // empty'
}

filename_safe_timestamp() {
  local iso_timestamp="$1"

  printf '%s\n' "${iso_timestamp//[:-]/}"
}

ensure_service_principal() {
  local label="$1"
  local config_dir="$2"
  local tenant_id="$3"
  local app_id="$4"
  local existing_sp_id created_json stderr_file create_error fallback_json

  existing_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
  if [[ -n "$existing_sp_id" ]]; then
    log INFO "$label service principal already exists: $existing_sp_id"
    printf '%s\n' "$existing_sp_id"
    return 0
  fi

  stderr_file="$(mktemp)"
  if created_json="$(AZURE_CONFIG_DIR="$config_dir" az ad sp create --id "$app_id" -o json 2>"$stderr_file")"; then
    rm -f "$stderr_file"
    printf '%s\n' "$(jq -r '.id' <<<"$created_json")"
    return 0
  fi

  create_error="$(<"$stderr_file")"
  rm -f "$stderr_file"
  log_warn "$label service principal creation via az ad sp create failed: ${create_error:-<no stderr>}"

  fallback_json="$(jq -cn --arg appId "$app_id" '{appId: $appId}')"
  if created_json="$(graph_request_json "$config_dir" POST "https://graph.microsoft.com/v1.0/servicePrincipals" "$fallback_json" 2>/dev/null)"; then
    log INFO "$label service principal created via Microsoft Graph fallback"
    printf '%s\n' "$(jq -r '.id' <<<"$created_json")"
    return 0
  fi

  existing_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
  if [[ -n "$existing_sp_id" ]]; then
    log INFO "$label service principal became available after failed create attempt: $existing_sp_id"
    printf '%s\n' "$existing_sp_id"
    return 0
  fi

  die "$label service principal could not be created automatically in tenant $tenant_id"
}

wait_for_service_principal() {
  local label="$1"
  local config_dir="$2"
  local app_id="$3"
  local attempt sp_id

  for attempt in 1 2 3 4 5; do
    sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
    if [[ -n "$sp_id" ]]; then
      log_success "$label service principal is available on attempt $attempt"
      printf '%s\n' "$sp_id"
      return 0
    fi
    sleep 2
  done

  die "$label service principal did not appear after creation attempts"
}

current_principal_oid_and_type() {
  local graph_token_json graph_access_token claims_json principal_oid principal_type

  graph_token_json="$(run_az "$CUSTOMER_CONFIG_DIR" account get-access-token --resource-type ms-graph -o json)"
  graph_access_token="$(jq -r '.accessToken // empty' <<<"$graph_token_json")"
  [[ -n "$graph_access_token" ]] || die "Could not acquire a Microsoft Graph token for role validation"
  claims_json="$(decode_jwt_payload_json "$graph_access_token")"
  principal_oid="$(jq -r '.oid // empty' <<<"$claims_json")"
  principal_type="$(jq -r '.idtyp // "user"' <<<"$claims_json")"
  [[ -n "$principal_oid" ]] || die "Could not resolve the current principal object ID from the Graph token"
  printf '%s\t%s\n' "$principal_oid" "$principal_type"
}

current_principal_role_names() {
  local principal_oid="$1"
  local assignments_json

  assignments_json="$(graph_request_json \
    "$CUSTOMER_CONFIG_DIR" \
    GET \
    "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId eq '$principal_oid'&\$expand=roleDefinition")"
  jq -r '.value[].roleDefinition.displayName // empty' <<<"$assignments_json"
}

assert_tenant_admin_role() {
  local principal_oid principal_type role_names required_role

  read -r principal_oid principal_type < <(current_principal_oid_and_type)
  role_names="$(current_principal_role_names "$principal_oid")"
  if [[ -z "$role_names" ]]; then
    die "Current $principal_type principal $principal_oid does not have an active Application Administrator or Cloud Application Administrator role assignment in tenant $CUSTOMER_TENANT_ID"
  fi

  while IFS= read -r required_role; do
    [[ -n "$required_role" ]] || continue
    if grep -Fxq "$required_role" <<<"$role_names"; then
      log_success "Current $principal_type principal $principal_oid has required role '$required_role'"
      return 0
    fi
  done < <(printf '%s\n' "${REQUIRED_ROLE_NAMES[@]}")

  die "Current $principal_type principal $principal_oid is missing the required role. Found: $(paste -sd ', ' <<<"$role_names")"
}

make_refresh_probe_tag() {
  printf 'ADME.RefreshProbe.%s.%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

patch_service_principal_tags() {
  local config_dir="$1"
  local sp_id="$2"
  local tags_json="$3"
  local body

  body="$(jq -cn --argjson tags "$tags_json" '{tags: $tags}')"
  graph_request_json "$config_dir" PATCH "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id" "$body" >/dev/null
}

ensure_oauth2_permission_grant() {
  local label="$1"
  local config_dir="$2"
  local client_sp_id="$3"
  local resource_sp_id="$4"
  local scope_value="$5"
  local existing_json existing_grant_id existing_scope merged_scope body

  existing_json="$(graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$client_sp_id' and resourceId eq '$resource_sp_id' and consentType eq 'AllPrincipals'")"
  existing_grant_id="$(jq -r '.value[0].id // empty' <<<"$existing_json")"

  if [[ -n "$existing_grant_id" ]]; then
    existing_scope="$(jq -r '.value[0].scope // empty' <<<"$existing_json")"
    if jq -e --arg existing "$existing_scope" --arg desired "$scope_value" '($existing | split(" ")) | index($desired) != null' >/dev/null <<<"{}"; then
      log INFO "$label already exists with scope '$existing_scope'"
      return 0
    fi

    merged_scope="$(jq -nr --arg existing "$existing_scope" --arg desired "$scope_value" '[$existing, $desired] | join(" ") | split(" ") | map(select(length > 0)) | unique | join(" ")')"
    body="$(jq -cn --arg scope "$merged_scope" '{scope: $scope}')"
    graph_request_json "$config_dir" PATCH "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$existing_grant_id" "$body" >/dev/null
    log_success "Updated $label to scope '$merged_scope'"
    return 0
  fi

  body="$(jq -cn \
    --arg clientId "$client_sp_id" \
    --arg resourceId "$resource_sp_id" \
    --arg scope "$scope_value" \
    '{
      clientId: $clientId,
      consentType: "AllPrincipals",
      resourceId: $resourceId,
      scope: $scope
    }')"
  graph_request_json "$config_dir" POST "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" "$body" >/dev/null
  log_success "Created $label with scope '$scope_value'"
}

count_matching_oauth2_permission_grants() {
  local config_dir="$1"
  local client_sp_id="$2"
  local resource_sp_id="$3"
  local scope_value="$4"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$client_sp_id' and resourceId eq '$resource_sp_id' and consentType eq 'AllPrincipals'" \
    | jq -r --arg scope "$scope_value" '[.value[] | select(((.scope // "") | split(" ") | index($scope) != null))] | length'
}

customer_app_admin_consent_portal_url() {
  printf '%s\n' "$APP_REGISTRATIONS_PORTAL_URL"
}

log_customer_app_admin_consent_guidance() {
  local level="$1"
  local portal_url="$2"

  log "$level" "Complete one tenant-wide admin-consent action for the updated customer app to grant both the bd0c app role and delegated scope."
  log "$level" "Azure portal: App registrations -> client app -> API permissions -> Grant admin consent"
  log "$level" "Portal link: $portal_url"
  log "$level" "Locate the client app by appId: $CLIENT_APP_ID"
}

application_json_by_object_id() {
  local config_dir="$1"
  local application_object_id="$2"
  graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/applications/$application_object_id"
}

build_new_resource_required_resource_access_json() {
  local current_required_resource_access_json="${1:-[]}"

  jq -cn \
    --argjson currentRequiredResourceAccess "$current_required_resource_access_json" \
    --arg oldResourceAppId "$OLD_RESOURCE_APP_ID" \
    --arg resourceAppId "$NEW_RESOURCE_APP_ID" \
    --arg roleId "$NEW_RESOURCE_APP_ROLE_ID" \
    --arg scopeId "$NEW_RESOURCE_SCOPE_ID" \
    '
      ($currentRequiredResourceAccess // [])
      | map(select(.resourceAppId != $oldResourceAppId and .resourceAppId != $resourceAppId))
      + [
          {
            resourceAppId: $resourceAppId,
            resourceAccess: [
              {id: $roleId, type: "Role"},
              {id: $scopeId, type: "Scope"}
            ]
          }
        ]
    '
}

normalized_unrelated_required_resource_access_json() {
  local application_json="$1"

  jq -c \
    --arg oldResourceAppId "$OLD_RESOURCE_APP_ID" \
    --arg newResourceAppId "$NEW_RESOURCE_APP_ID" '
      (.requiredResourceAccess // [])
      | map(select(.resourceAppId != $oldResourceAppId and .resourceAppId != $newResourceAppId))
      | map(.resourceAccess = ((.resourceAccess // []) | sort_by(.type, .id)))
      | sort_by(.resourceAppId, (.resourceAccess | map(.type + ":" + .id) | join("|")))
    ' <<<"$application_json"
}

required_resource_access_has_new_resource() {
  local application_json="$1"

  jq -e \
    --arg resourceAppId "$NEW_RESOURCE_APP_ID" \
    --arg roleId "$NEW_RESOURCE_APP_ROLE_ID" \
    --arg scopeId "$NEW_RESOURCE_SCOPE_ID" '
      (.requiredResourceAccess // []) as $rra
      | [$rra[] | select(.resourceAppId == $resourceAppId)] as $newEntries
      | (($newEntries | length) == 1)
      and ((($newEntries[0].resourceAccess // []) | length) == 2)
      and any($newEntries[0].resourceAccess[]?; .id == $roleId and .type == "Role")
      and any($newEntries[0].resourceAccess[]?; .id == $scopeId and .type == "Scope")
    ' <<<"$application_json" >/dev/null
}

required_resource_access_has_old_resource() {
  local application_json="$1"

  jq -e \
    --arg oldResourceAppId "$OLD_RESOURCE_APP_ID" '
      any((.requiredResourceAccess // [])[]?; .resourceAppId == $oldResourceAppId)
    ' <<<"$application_json" >/dev/null
}

required_resource_access_matches_new_resource() {
  local application_json="$1"
  local baseline_application_json="${2:-$1}"
  local current_unrelated baseline_unrelated

  current_unrelated="$(normalized_unrelated_required_resource_access_json "$application_json")"
  baseline_unrelated="$(normalized_unrelated_required_resource_access_json "$baseline_application_json")"

  required_resource_access_has_new_resource "$application_json" || return 1
  if required_resource_access_has_old_resource "$application_json"; then
    return 1
  fi

  [[ "$current_unrelated" == "$baseline_unrelated" ]]
}

patch_required_resource_access_to_new_resource() {
  local current_application_json current_required_resource_access desired_rra body updated_application_json

  current_application_json="$(application_json_by_object_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_OBJECT_ID")"
  log INFO "Current client app requiredResourceAccess: $(jq -c '.requiredResourceAccess // []' <<<"$current_application_json")"
  if required_resource_access_matches_new_resource "$current_application_json" "$current_application_json"; then
    log INFO "client app requiredResourceAccess already references new resource"
    return 0
  fi

  current_required_resource_access="$(jq -c '.requiredResourceAccess // []' <<<"$current_application_json")"
  desired_rra="$(build_new_resource_required_resource_access_json "$current_required_resource_access")"
  body="$(jq -cn --argjson requiredResourceAccess "$desired_rra" '{requiredResourceAccess: $requiredResourceAccess}')"
  graph_request_json "$CUSTOMER_CONFIG_DIR" PATCH "https://graph.microsoft.com/v1.0/applications/$CLIENT_APP_OBJECT_ID" "$body" >/dev/null

  updated_application_json="$(application_json_by_object_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_OBJECT_ID")"
  required_resource_access_matches_new_resource "$updated_application_json" "$current_application_json" \
    || die "client app requiredResourceAccess did not update to new resource while preserving unrelated entries"
  log_success "Updated client app requiredResourceAccess to new resource"
  log INFO "Updated client app requiredResourceAccess: $(jq -c '.requiredResourceAccess // []' <<<"$updated_application_json")"
}

find_matching_app_role_assignment_id() {
  local resource_sp_id="$1"
  local assignments_json

  # Microsoft Graph rejected the preferred combined filter
  # (`principalId eq <guid> and appRoleId eq <guid>`) on this collection in
  # live probing with "Filtering on more than one resource not supported", so
  # keep the query broad and filter client-side until pagination becomes a
  # demonstrated problem.
  assignments_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo")"
  jq -r \
    --arg principalId "$CLIENT_SERVICE_PRINCIPAL_ID" \
    --arg appRoleId "$NEW_RESOURCE_APP_ROLE_ID" \
    '.value[] | select(.principalId == $principalId and .appRoleId == $appRoleId) | .id' \
    <<<"$assignments_json" \
    | head -n 1
}

count_matching_app_role_assignments() {
  local resource_sp_id="$1"
  local assignments_json

  # See note in find_matching_app_role_assignment_id(): the combined server-side
  # filter is not supported here, so count matches after the broad fetch.
  assignments_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo")"
  jq -r \
    --arg principalId "$CLIENT_SERVICE_PRINCIPAL_ID" \
    --arg appRoleId "$NEW_RESOURCE_APP_ROLE_ID" \
    '[.value[] | select(.principalId == $principalId and .appRoleId == $appRoleId)] | length' \
    <<<"$assignments_json"
}

ensure_app_role_assignment() {
  local resource_sp_id="$1"
  local existing_assignment_id body

  existing_assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id")"
  if [[ -n "$existing_assignment_id" ]]; then
    log INFO "client app already has app role assignment $existing_assignment_id on new resource"
    return 0
  fi

  body="$(jq -cn \
    --arg principalId "$CLIENT_SERVICE_PRINCIPAL_ID" \
    --arg resourceId "$resource_sp_id" \
    --arg appRoleId "$NEW_RESOURCE_APP_ROLE_ID" \
    '{
      principalId: $principalId,
      resourceId: $resourceId,
      appRoleId: $appRoleId
    }')"
  graph_request_json "$CUSTOMER_CONFIG_DIR" POST "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo" "$body" >/dev/null
  log_success "Created client app -> new resource app role assignment"
}

wait_for_app_role_assignment() {
  local resource_sp_id="$1"
  local attempt assignment_id

  for attempt in 1 2 3; do
    assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id")"
    if [[ -n "$assignment_id" ]]; then
      log_success "Verified client app app role assignment on attempt $attempt: $assignment_id"
      printf '%s\n' "$assignment_id"
      return 0
    fi
    sleep 3
  done

  die "client app app role assignment to new resource was not visible after creation"
}

extract_json_claim_from_text() {
  local key="$1"
  local text="$2"

  sed -nE "s/.*\"$key\": \"([^\"]+)\".*/\\1/p" <<<"$text" | head -n 1
}

run_get_token_py() {
  local tenant_id client_id client_secret resource_uri authority

  tenant_id="${APP_TENANT_ID:-}"
  [[ -n "$tenant_id" ]] || die "APP_TENANT_ID is not set. Provide it via environment or config."

  client_id="${APP_CLIENT_ID:-${APP_ID:-${CLIENT_ID:-}}}"
  [[ -n "$client_id" ]] || die "APP_CLIENT_ID is not set. Provide it via environment or config."

  client_secret="${APP_CLIENT_SECRET:-}"
  [[ -n "$client_secret" ]] || die "APP_CLIENT_SECRET is required for the app-only token proof."

  resource_uri="${RESOURCE_APP_ID_URI:-}"
  if [[ -z "$resource_uri" ]]; then
    [[ -n "${API_APP_ID:-}" ]] || die "RESOURCE_APP_ID_URI or API_APP_ID must be set for the app-only token proof."
    resource_uri="api://${API_APP_ID}"
  fi

  authority="https://login.microsoftonline.com/$tenant_id"

  (
    set -euo pipefail

    local sp_config_dir token_json access_token claims_json

    sp_config_dir="$(mktemp -d)"
    trap 'rm -rf "$sp_config_dir"' EXIT

    AZURE_CONFIG_DIR="$sp_config_dir" az login \
      --service-principal \
      --username "$client_id" \
      --password "$client_secret" \
      --tenant "$tenant_id" \
      --allow-no-subscriptions \
      --output none >/dev/null

    token_json="$(
      AZURE_CONFIG_DIR="$sp_config_dir" az account get-access-token \
        --resource "$resource_uri" \
        --tenant "$tenant_id" \
        -o json
    )"
    access_token="$(jq -r '.accessToken // empty' <<<"$token_json")"
    [[ -n "$access_token" ]] || die "Azure CLI did not return an app-only access token"

    claims_json="$(decode_jwt_payload_json "$access_token" | jq '.')"

    printf 'Using client credentials flow (application permissions).\n'
    printf 'Client type: confidential\n'
    printf 'Authority: %s\n' "$authority"
    printf 'Client ID: %s\n' "$client_id"
    printf 'Resource (scope): %s/.default\n' "$resource_uri"
    printf '✅ Access Token: %s\n' "$access_token"
    printf '=== Access Token Payload ===\n'
    printf '%s\n' "$claims_json"
  )
}

acquire_azure_cli_delegated_token_force_refresh() {
  local delegated_scope="$1"
  local config_dir="$2"
  local tenant_id="$3"

  if python3_has_msal; then
    AZURE_CONFIG_DIR="$config_dir" \
    AAD_TENANT_ID="$tenant_id" \
    AZURE_CLI_CLIENT_ID="$AZURE_CLI_APP_ID" \
    REQUESTED_SCOPE="$delegated_scope" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

import msal

cache_path = Path(os.environ["AZURE_CONFIG_DIR"]) / "msal_token_cache.json"
tenant_id = os.environ["AAD_TENANT_ID"]
client_id = os.environ["AZURE_CLI_CLIENT_ID"]
scope = os.environ["REQUESTED_SCOPE"]

if not cache_path.exists():
    print(json.dumps({
        "error": "missing_token_cache",
        "error_description": f"Azure CLI token cache not found at {cache_path}",
    }))
    raise SystemExit(0)

cache = msal.SerializableTokenCache()
cache.deserialize(cache_path.read_text() or "{}")
app = msal.PublicClientApplication(
    client_id,
    authority=f"https://login.microsoftonline.com/{tenant_id}",
    token_cache=cache,
)
accounts = [account for account in app.get_accounts() if account.get("realm") == tenant_id]
if not accounts:
    print(json.dumps({
        "error": "missing_cached_account",
        "error_description": f"No Azure CLI account for tenant {tenant_id} was found in {cache_path}",
    }))
    raise SystemExit(0)

result = app.acquire_token_silent_with_error([scope], account=accounts[0], force_refresh=True)
if result is None:
    print(json.dumps({
        "error": "empty_result",
        "error_description": f"MSAL returned no token or error while requesting {scope}",
    }))
    raise SystemExit(0)

print(json.dumps(result))
PY
    return 0
  fi

  jq -cn --arg scope "$delegated_scope" '{
    skipped: true,
    reason: "python3_msal_unavailable",
    warning: ("Skipping delegated forced-refresh proof for scope " + $scope + " because python3 with the msal package is unavailable. The Graph delegated-grant wiring check still ran.")
  }'
}

acquire_azure_cli_delegated_token() {
  local delegated_scope="$1"
  local config_dir="$2"
  local tenant_id="$3"
  local az_output

  if az_output="$(
    AZURE_CONFIG_DIR="$config_dir" \
      az account get-access-token \
        --tenant "$tenant_id" \
        --scope "$delegated_scope" \
        -o json 2>&1
  )"; then
    jq -c '{
      access_token: .accessToken,
      expires_on: .expiresOn,
      token_type: .tokenType,
      source: "az_account_get_access_token"
    }' <<<"$az_output"
    return 0
  fi

  jq -cn \
    --arg error "az_account_get_access_token_failed" \
    --arg error_description "$az_output" \
    '{error: $error, error_description: $error_description}'
}

run_verify() {
  local dffa_customer_sp_json dffa_customer_sp_names
  local bd0c_customer_sp_id bd0c_customer_sp_json bd0c_customer_sp_names
  local client_application_json
  local app_role_assignment_count
  local app_only_output app_only_aud app_only_azp app_only_secret
  local app_only_proof_ran=0
  local delegated_scope delegated_json delegated_claims_json delegated_aud delegated_scp delegated_azp
  local delegated_error delegated_error_description
  local delegated_skip delegated_warning delegated_proof_ran=0
  local dffa_assignment_count dffa_delegated_grant_count azure_cli_customer_sp_id
  local azure_cli_delegated_grant_count client_delegated_grant_count admin_consent_url
  local verify_failures=0 admin_consent_pending=0 stale_old_resource_manifest_warning=0

  log_step "Loading runtime state and validating verification prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"

  log_step "Checking customer-tenant service principal state"
  dffa_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
  dffa_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$dffa_customer_sp_json")"
  if old_resource_service_principal_is_refreshed "$dffa_customer_sp_json"; then
    log_success "Verified customer old resource servicePrincipalNames: $dffa_customer_sp_names"
    log_success "Verified customer old resource no longer owns shared audience $NEW_RESOURCE_IDENTIFIER_URI"
  else
    log ERROR "FAIL: customer old resource servicePrincipalNames are not refreshed to the old identifierUri: $dffa_customer_sp_names"
    verify_failures=$((verify_failures + 1))
  fi

  bd0c_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"
  [[ -n "$bd0c_customer_sp_id" ]] || die "Customer new resource service principal not found"
  bd0c_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$bd0c_customer_sp_id")"
  bd0c_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$bd0c_customer_sp_json")"
  if new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json"; then
    log_success "Verified customer new resource servicePrincipalNames: $bd0c_customer_sp_names"
    log_success "Verified customer new resource owns shared audience $NEW_RESOURCE_IDENTIFIER_URI"
  else
    log ERROR "FAIL: customer new resource servicePrincipalNames do not include $NEW_RESOURCE_IDENTIFIER_URI: $bd0c_customer_sp_names"
    verify_failures=$((verify_failures + 1))
  fi

  log_step "Checking the client app requiredResourceAccess for the new resource"
  client_application_json="$(application_json_by_object_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_OBJECT_ID")"
  if required_resource_access_has_new_resource "$client_application_json"; then
    log_success "Verified client app requiredResourceAccess includes the new resource Role + Scope"
    if required_resource_access_has_old_resource "$client_application_json"; then
      log WARN "WARN: client app requiredResourceAccess still includes stale old-resource entries alongside the new resource"
      stale_old_resource_manifest_warning=1
    fi
  else
    log ERROR "FAIL: client app requiredResourceAccess is not updated to the new resource"
    verify_failures=$((verify_failures + 1))
  fi

  log_step "Checking the new resource app-role assignment for client app"
  app_role_assignment_count="$(count_matching_app_role_assignments "$bd0c_customer_sp_id")"
  case "$app_role_assignment_count" in
    1)
      log_success "Verified new resource app role assignment count for client app is 1"
      ;;
    0)
      admin_consent_pending=1
      log_warn "Client app app-role grant for new resource is missing (admin consent pending on the default path)"
      ;;
    *)
      log ERROR "FAIL: expected exactly one new resource app role assignment for client app, found $app_role_assignment_count"
      verify_failures=$((verify_failures + 1))
      ;;
  esac

  app_only_secret="${CLIENT_SECRET:-}"
  if [[ "$app_role_assignment_count" == "1" && -n "$app_only_secret" ]]; then
    log_step "Validating the post-migration app-only token"
    if ! app_only_output="$(
      AZURE_CONFIG_DIR="$CUSTOMER_CONFIG_DIR" \
      APP_TENANT_ID="$CUSTOMER_TENANT_ID" \
      API_APP_ID="$NEW_RESOURCE_APP_ID" \
      RESOURCE_APP_ID_URI="$NEW_RESOURCE_IDENTIFIER_URI" \
      APP_CLIENT_ID="$CLIENT_APP_ID" \
      APP_CLIENT_SECRET="$app_only_secret" \
      AUTH_FLOW=client_credentials \
      run_get_token_py 2>&1 | sed -E 's#^(✅ Access Token: ).*$#\1[REDACTED]#'
    )"; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        log INFO "app-only: $line"
      done <<<"${app_only_output:-}"
      die "Post-migration app-only token acquisition failed"
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log INFO "app-only: $line"
    done <<<"$app_only_output"
    app_only_aud="$(extract_json_claim_from_text "aud" "$app_only_output")"
    app_only_azp="$(extract_json_claim_from_text "azp" "$app_only_output")"
    [[ "$app_only_aud" == "$NEW_RESOURCE_APP_ID" ]] || die "App-only token aud '$app_only_aud' did not match new resource appId '$NEW_RESOURCE_APP_ID'"
    [[ "$app_only_azp" == "$CLIENT_APP_ID" ]] || die "App-only token azp '$app_only_azp' did not match client app appId '$CLIENT_APP_ID'"
    app_only_proof_ran=1
    log_success "Verified app-only token aud=$app_only_aud azp=$app_only_azp"
  elif [[ "$app_role_assignment_count" == "0" ]]; then
    log_warn "Skipping the app-only token proof because the customer app app-role grant is still pending admin consent"
  elif [[ "$app_role_assignment_count" != "1" ]]; then
    log_warn "Skipping the app-only token proof because the app-role grant state is already failing verification"
  else
    log_warn "Skipping the app-only token proof because CLIENT_SECRET was not provided in the environment or config file"
  fi

  log_step "Checking the Azure CLI delegated grant wiring for new resource"
  azure_cli_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"
  [[ -n "$azure_cli_customer_sp_id" ]] || die "Customer Microsoft Azure CLI service principal not found"
  azure_cli_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$azure_cli_customer_sp_id" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"
  if (( azure_cli_delegated_grant_count >= 1 )); then
    log_success "Verified Azure CLI delegated grant wiring for new resource scope '$NEW_RESOURCE_SCOPE_VALUE'"
  else
    log ERROR "FAIL: customer Azure CLI delegated grant for new resource scope '$NEW_RESOURCE_SCOPE_VALUE' is missing"
    verify_failures=$((verify_failures + 1))
  fi

  admin_consent_portal_url="$(customer_app_admin_consent_portal_url)"
  client_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"
  if [[ "$client_delegated_grant_count" == "0" ]]; then
    admin_consent_pending=1
    log_warn "Client app delegated grant for new resource scope '$NEW_RESOURCE_SCOPE_VALUE' is missing"
  else
    log_success "Verified client app delegated grant wiring for new resource scope '$NEW_RESOURCE_SCOPE_VALUE'"
  fi

  if [[ "$admin_consent_pending" -eq 1 ]]; then
    log_warn "Admin-consent state: pending for the customer app"
    log_customer_app_admin_consent_guidance WARN "$admin_consent_portal_url"
  else
    log_success "Admin-consent state: complete for the customer app"
  fi

  if (( azure_cli_delegated_grant_count >= 1 )); then
    log_step "Validating the post-migration delegated token with a forced refresh to avoid stale Azure CLI cache hits"
    delegated_scope="$NEW_RESOURCE_IDENTIFIER_URI/$NEW_RESOURCE_SCOPE_VALUE"
    delegated_json="$(acquire_azure_cli_delegated_token_force_refresh "$delegated_scope" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID")"
    delegated_skip="$(jq -r '.skipped // false' <<<"$delegated_json")"
    delegated_warning="$(jq -r '.warning // empty' <<<"$delegated_json")"
    if [[ "$delegated_skip" == "true" ]]; then
      [[ -n "$delegated_warning" ]] || delegated_warning="Skipping delegated forced-refresh proof because python3 with msal is unavailable."
      log_warn "$delegated_warning"
    else
      delegated_error="$(jq -r '.error // empty' <<<"$delegated_json")"
      delegated_error_description="$(jq -r '.error_description // empty' <<<"$delegated_json")"
      if [[ -n "$delegated_error" ]]; then
        if jq -e '(.error_codes // []) | index(65001) != null' >/dev/null <<<"$delegated_json"; then
          delegated_json="$(acquire_azure_cli_delegated_token "$delegated_scope" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID")"
          delegated_error="$(jq -r '.error // empty' <<<"$delegated_json")"
          if [[ -z "$delegated_error" ]]; then
            log_warn "Azure CLI MSAL force-refresh returned consent_required for scope $delegated_scope; using az account get-access-token fallback and validating token claims to reject stale cache hits"
          else
            log_warn "Azure CLI forced-refresh delegated token request still requires one-time interactive consent for scope $delegated_scope"
            log_warn "Run once: AZURE_CONFIG_DIR=\"$CUSTOMER_CONFIG_DIR\" az login --tenant \"$CUSTOMER_TENANT_ID\" --scope \"$delegated_scope\" --allow-no-subscriptions"
            die "Post-migration delegated verification is blocked until the operator completes the one-time Azure CLI consent for $delegated_scope with az login --allow-no-subscriptions"
          fi
        else
          [[ -n "$delegated_error_description" ]] || delegated_error_description="<no description>"
          die "Post-migration delegated token acquisition failed: $delegated_error ($delegated_error_description)"
        fi
      fi

      delegated_claims_json="$(decode_jwt_payload_json "$(jq -r '.access_token // empty' <<<"$delegated_json")")"
      delegated_aud="$(jq -r '.aud // empty' <<<"$delegated_claims_json")"
      delegated_scp="$(jq -r '.scp // empty' <<<"$delegated_claims_json")"
      delegated_azp="$(jq -r '.azp // empty' <<<"$delegated_claims_json")"
      [[ "$delegated_aud" == "$NEW_RESOURCE_APP_ID" ]] || die "Delegated token aud '$delegated_aud' did not match new resource appId '$NEW_RESOURCE_APP_ID'"
      [[ "$delegated_scp" == "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "Delegated token scp '$delegated_scp' did not match '$NEW_RESOURCE_SCOPE_VALUE'"
      [[ "$delegated_azp" == "$AZURE_CLI_APP_ID" ]] || die "Delegated token azp '$delegated_azp' did not match Microsoft Azure CLI appId '$AZURE_CLI_APP_ID'"
      delegated_proof_ran=1
      log_success "Verified delegated token aud=$delegated_aud azp=$delegated_azp scp=$delegated_scp"
    fi
  else
    log_warn "Skipping the delegated token proof because the Azure CLI delegated grant is missing"
  fi

  dffa_assignment_count="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$OLD_RESOURCE_SERVICE_PRINCIPAL_ID/appRoleAssignedTo" | jq -r --arg principalId "$CLIENT_SERVICE_PRINCIPAL_ID" '[.value[] | select(.principalId == $principalId)] | length')"
  dffa_delegated_grant_count="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=resourceId eq '$OLD_RESOURCE_SERVICE_PRINCIPAL_ID'" | jq -r '.value | length')"
  log INFO "Stale old resource grants (informational only): appRoleAssignedTo matches for client app=$dffa_assignment_count, oauth2PermissionGrants=$dffa_delegated_grant_count"

  if (( verify_failures > 0 )); then
    log ERROR "SUMMARY: verify found $verify_failures failing check(s)"
    die "verify detected broken migration state"
  fi

  if [[ "$admin_consent_pending" -eq 1 && "$stale_old_resource_manifest_warning" -eq 1 ]]; then
    log WARN "SUMMARY: verify completed with admin-consent pending and stale old-resource requiredResourceAccess entries still present on the customer app"
  elif [[ "$admin_consent_pending" -eq 1 ]]; then
    log WARN "SUMMARY: verify completed with admin-consent pending for the customer app"
  elif [[ "$stale_old_resource_manifest_warning" -eq 1 ]]; then
    log WARN "SUMMARY: verify completed with stale old-resource requiredResourceAccess entries still present on the customer app"
  elif [[ "$app_only_proof_ran" -eq 1 && "$delegated_proof_ran" -eq 1 ]]; then
    log INFO "SUMMARY: verify complete — post-migration state and both token paths are healthy"
  elif [[ "$app_only_proof_ran" -eq 1 ]]; then
    log INFO "SUMMARY: verify complete — post-migration state is healthy; app-only token proof passed and delegated force-refresh proof was skipped"
  elif [[ "$delegated_proof_ran" -eq 1 ]]; then
    log INFO "SUMMARY: verify complete — post-migration delegated token path is healthy (app-only proof was skipped)"
  else
    log INFO "SUMMARY: verify complete — post-migration state is healthy; app-only proof was skipped and delegated force-refresh proof was skipped"
  fi
}

confirm_if_needed() {
  local action_label="$1"

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log INFO "Skipping confirmation because --yes was provided"
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    local response
    read -r -p "Proceed with $action_label? [y/N] " response
    case "$response" in
      y|Y|yes|YES)
        return 0
        ;;
      *)
        die "Aborted by operator"
        ;;
    esac
  fi

  log INFO "Non-interactive session detected; proceeding without confirmation prompt"
}

confirm_destructive_if_needed() {
  local action_label="$1"

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log INFO "Skipping destructive confirmation because --yes was provided"
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    local response
    read -r -p "Proceed with $action_label? [y/N] " response
    case "$response" in
      y|Y|yes|YES)
        return 0
        ;;
      *)
        die "Aborted by operator"
        ;;
    esac
  fi

  die "Refusing to proceed with $action_label in non-interactive mode without --yes"
}

delete_service_principal() {
  local label="$1"
  local config_dir="$2"
  local sp_id="$3"
  local stderr_file delete_error

  stderr_file="$(mktemp)"
  if run_az "$config_dir" rest --method DELETE --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id" >/dev/null 2>"$stderr_file"; then
    rm -f "$stderr_file"
    log_success "Deleted $label service principal $sp_id"
    return 0
  fi

  delete_error="$(<"$stderr_file")"
  rm -f "$stderr_file"
  die "Failed to delete $label service principal $sp_id: ${delete_error:-<no stderr>}"
}

run_migrate_tenant_admin() {
  local dffa_customer_sp_json original_tags probe_tag patched_tags
  local refresh_attempt refreshed_dffa_sp_json refreshed_dffa_sp_names refresh_succeeded
  local bd0c_customer_sp_id bd0c_customer_sp_json bd0c_customer_sp_names azure_cli_customer_sp_id
  local recreated_dffa_sp_json recreated_dffa_sp_names

  log_step "Loading runtime state and validating adme-audience prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant_admin_role

  dffa_customer_sp_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
  original_tags="$(jq -c '.tags // []' <<<"$dffa_customer_sp_json")"

  log INFO "Preflight:"
  log INFO "  customer tenant: $CUSTOMER_TENANT_ID"
  log INFO "  old resource customer servicePrincipalId: $OLD_RESOURCE_SERVICE_PRINCIPAL_ID"
  log INFO "  expected refreshed old resource identifierUri: $OLD_RESOURCE_IDENTIFIER_URI"
  log INFO "  new resource appId to provision in customer tenant: $NEW_RESOURCE_APP_ID"
  log INFO "  expected new resource identifierUri: $NEW_RESOURCE_IDENTIFIER_URI"
  if [[ "$ALLOW_RECREATE_DFFA" -eq 1 ]]; then
    log INFO "  fallback mode: --allow-recreate-dffa enabled"
  else
    log INFO "  fallback mode: default safe stop if refresh remains stale"
  fi
  confirm_if_needed "adme-audience migration"

  probe_tag="$(make_refresh_probe_tag)"
  patched_tags="$(jq -cn --argjson tags "$original_tags" --arg probeTag "$probe_tag" '$tags + [$probeTag] | unique')"

  log_step "Applying a temporary refresh probe tag to the stale old resource customer service principal"
  patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$patched_tags"
  log_success "Applied refresh probe tag $probe_tag"
  trap 'patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$original_tags" >/dev/null 2>&1' EXIT

  log_step "Polling for the refreshed old resource servicePrincipalNames"
  refresh_succeeded=0
  for refresh_attempt in 1 2 3; do
    refreshed_dffa_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
    refreshed_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$refreshed_dffa_sp_json")"
    if old_resource_service_principal_is_refreshed "$refreshed_dffa_sp_json"; then
      log_success "old resource customer servicePrincipalNames refreshed on attempt $refresh_attempt: $refreshed_dffa_sp_names"
      refresh_succeeded=1
      break
    fi

    log INFO "old resource customer servicePrincipalNames not refreshed on attempt $refresh_attempt/3 yet: $refreshed_dffa_sp_names"
    sleep 5
  done

  log_step "Removing the temporary refresh probe tag"
  patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$original_tags"
  trap - EXIT
  log_success "Removed refresh probe tag $probe_tag"

  if [[ "$refresh_succeeded" -ne 1 ]]; then
    log_warn "old resource customer servicePrincipalNames remained stale after 3 refresh attempts: $refreshed_dffa_sp_names"

    if [[ "$ALLOW_RECREATE_DFFA" -ne 1 ]]; then
      die "old resource customer servicePrincipalNames still include $NEW_RESOURCE_IDENTIFIER_URI after the probe-tag PATCH. Review output-logging/ and rerun with --allow-recreate-dffa if you want to approve the delete/recreate fallback."
    fi
  fi

  log_step "Ensuring new resource exists in the customer tenant"
  bd0c_customer_sp_id="$(ensure_service_principal "customer new resource" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$NEW_RESOURCE_APP_ID")"
  bd0c_customer_sp_id="$(wait_for_service_principal "customer new resource" "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"

  bd0c_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$bd0c_customer_sp_id")"
  bd0c_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$bd0c_customer_sp_json")"
  new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json" || die "customer new resource servicePrincipalNames do not include $NEW_RESOURCE_IDENTIFIER_URI"
  log_success "Verified customer new resource servicePrincipalNames: $bd0c_customer_sp_names"

  if [[ "$refresh_succeeded" -ne 1 ]]; then
    old_resource_service_principal_has_stale_shared_audience "$refreshed_dffa_sp_json" \
      || die "Refusing delete/recreate because the old resource stale condition is not proven. Expected both $OLD_RESOURCE_IDENTIFIER_URI and $NEW_RESOURCE_IDENTIFIER_URI on the old resource service principal."
    new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json" \
      || die "Refusing delete/recreate because the new resource does not currently own $NEW_RESOURCE_IDENTIFIER_URI."

    log_step "Preparing the bounded delete/recreate fallback for the stale old resource service principal"
    log INFO "Before recreate old resource servicePrincipalNames: $refreshed_dffa_sp_names"
    log INFO "Before recreate new resource servicePrincipalNames: $bd0c_customer_sp_names"
    confirm_destructive_if_needed "deleting and recreating the stale old resource customer service principal"

    delete_service_principal "customer old resource" "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID"
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(ensure_service_principal "customer old resource" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$OLD_RESOURCE_APP_ID")"
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(wait_for_service_principal "customer old resource" "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_APP_ID")"
    recreated_dffa_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
    recreated_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$recreated_dffa_sp_json")"
    log INFO "After recreate old resource servicePrincipalNames: $recreated_dffa_sp_names"
    old_resource_service_principal_is_refreshed "$recreated_dffa_sp_json" \
      || die "Recreated old resource servicePrincipalNames still include $NEW_RESOURCE_IDENTIFIER_URI; stop and review the home-tenant application metadata before retrying."
    log_success "Verified recreated old resource servicePrincipalNames: $recreated_dffa_sp_names"
  fi

  log_step "Ensuring Azure CLI can request the new resource delegated scope non-interactively"
  azure_cli_customer_sp_id="$(ensure_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$AZURE_CLI_APP_ID")"
  azure_cli_customer_sp_id="$(wait_for_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"
  ensure_oauth2_permission_grant \
    "customer Microsoft Azure CLI delegated new resource grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$azure_cli_customer_sp_id" \
    "$bd0c_customer_sp_id" \
    "$NEW_RESOURCE_SCOPE_VALUE"

  log INFO "SUMMARY: migrate adme-audience complete"
  log INFO "  old resource customer servicePrincipalId=$OLD_RESOURCE_SERVICE_PRINCIPAL_ID now advertises $OLD_RESOURCE_IDENTIFIER_URI"
  log INFO "  new resource customer servicePrincipalId=$bd0c_customer_sp_id now advertises $NEW_RESOURCE_IDENTIFIER_URI"
}

run_migrate_app_owner() {
  local bd0c_customer_sp_id matching_assignment_id assignment_count admin_consent_url
  local client_delegated_grant_count

  log_step "Loading runtime state and validating api-permissions prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant_admin_role

  bd0c_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"
  [[ -n "$bd0c_customer_sp_id" ]] || die "Customer new resource service principal not found. Run 'migrate adme-audience' first."

  admin_consent_portal_url="$(customer_app_admin_consent_portal_url)"

  log INFO "Preflight:"
  log INFO "  customer tenant: $CUSTOMER_TENANT_ID"
  log INFO "  client app appId: $CLIENT_APP_ID"
  log INFO "  new resource appId: $NEW_RESOURCE_APP_ID"
  log INFO "  new resource servicePrincipalId: $bd0c_customer_sp_id"
  log INFO "  app role to grant: $NEW_RESOURCE_APP_ROLE_VALUE ($NEW_RESOURCE_APP_ROLE_ID)"
  log INFO "  delegated scope to preserve in requiredResourceAccess: $NEW_RESOURCE_SCOPE_VALUE ($NEW_RESOURCE_SCOPE_ID)"
  if [[ "$AUTO_GRANT" -eq 1 ]]; then
    log INFO "  customer-app consent mode: --auto-grant"
  else
    log INFO "  customer-app consent mode: default manual admin-consent action"
    log_customer_app_admin_consent_guidance INFO "$admin_consent_portal_url"
  fi
  confirm_if_needed "api-permissions migration"

  log_step "Validating the requiredResourceAccess PATCH contract against client app"
  patch_required_resource_access_to_new_resource

  log INFO "Old resource grants are left in place intentionally if they exist; they are now stale informational artifacts."
  log INFO "SUMMARY: migrate api-permissions complete"
  log INFO "  client app requiredResourceAccess now references new resource"

  if [[ "$AUTO_GRANT" -eq 1 ]]; then
    log_step "Ensuring the new resource app role assignment exists for client app"
    ensure_app_role_assignment "$bd0c_customer_sp_id"
    matching_assignment_id="$(wait_for_app_role_assignment "$bd0c_customer_sp_id")"
    assignment_count="$(count_matching_app_role_assignments "$bd0c_customer_sp_id")"
    [[ "$assignment_count" == "1" ]] || die "Expected exactly one matching new resource app role assignment for client app, found $assignment_count"

    log_step "Ensuring the new resource delegated grant exists for client app"
    ensure_oauth2_permission_grant \
      "client app delegated new resource grant" \
      "$CUSTOMER_CONFIG_DIR" \
      "$CLIENT_SERVICE_PRINCIPAL_ID" \
      "$bd0c_customer_sp_id" \
      "$NEW_RESOURCE_SCOPE_VALUE"
    client_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"
    (( client_delegated_grant_count >= 1 )) || die "Expected the client app delegated grant for new resource scope '$NEW_RESOURCE_SCOPE_VALUE' to exist after --auto-grant"

    log_success "Verified client app delegated grant wiring for new resource scope '$NEW_RESOURCE_SCOPE_VALUE'"
    log INFO "  customer app grants were created programmatically (--auto-grant)"
    log INFO "  new resource app role assignment id=$matching_assignment_id"
  else
    matching_assignment_id="$(find_matching_app_role_assignment_id "$bd0c_customer_sp_id")"
    assignment_count="$(count_matching_app_role_assignments "$bd0c_customer_sp_id")"
    client_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"

    log INFO "  customer app grants were not modified on the default path"
    log INFO "  existing customer-app grant state (informational): appRoleAssignments=$assignment_count delegatedGrants=$client_delegated_grant_count"
    if [[ -n "$matching_assignment_id" ]]; then
      log INFO "  existing new resource app role assignment id=$matching_assignment_id"
    fi
    log_customer_app_admin_consent_guidance INFO "$admin_consent_portal_url"
  fi
}

canonicalize_migrate_subcommand() {
  case "$1" in
    adme-audience|tenant-admin)
      printf 'adme-audience\n'
      ;;
    api-permissions|app-owner)
      printf 'api-permissions\n'
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

parse_global_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-dir)
        STATE_DIR="${2:?Missing value for --state-dir}"
        STATE_DIR_EXPLICIT=1
        shift 2
        ;;
      --output-logging)
        OUTPUT_LOGGING_DIR="${2:?Missing value for --output-logging}"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  case "$1" in
    migrate)
      [[ $# -ge 2 ]] || die "Missing subcommand after 'migrate'"
      COMMAND="migrate"
      SUBCOMMAND="$(canonicalize_migrate_subcommand "$2")"
      shift 2
      ;;
    verify)
      COMMAND="verify"
      SUBCOMMAND=""
      shift
      ;;
    *)
      die "Unknown command: $1"
      ;;
  esac

  parse_command_options "$@"
}

parse_command_options() {
  case "$COMMAND/$SUBCOMMAND" in
    migrate/api-permissions)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --auto-grant)
            AUTO_GRANT=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "Unknown option for 'migrate api-permissions': $1"
            ;;
        esac
      done
      ;;
    migrate/adme-audience)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --allow-recreate-dffa)
            ALLOW_RECREATE_DFFA=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "Unexpected argument for '$COMMAND ${SUBCOMMAND:-}': $1"
            ;;
        esac
      done
      ;;
    verify/)
      [[ $# -eq 0 ]] || die "Unexpected argument for '$COMMAND ${SUBCOMMAND:-}': $1"
      ;;
    *)
      die "Unsupported command: $COMMAND ${SUBCOMMAND:-}"
      ;;
  esac
}

COMMAND=""
SUBCOMMAND=""
parse_global_options "$@"
init_logging

case "$COMMAND/$SUBCOMMAND" in
  migrate/adme-audience)
    run_migrate_tenant_admin
    ;;
  migrate/api-permissions)
    run_migrate_app_owner
    ;;
  verify/)
    run_verify
    ;;
  *)
    usage
    die "Unsupported command: $COMMAND ${SUBCOMMAND:-}"
    ;;
esac
