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
#       - refreshes the old resource (dffa) service principal in the customer tenant
#       - ensures the new resource (bd0c) service principal exists
#       - ensures Microsoft Azure CLI has the delegated grant needed for the
#         new ADME scope
#   * migrate api-permissions
#       - patches the client app selected by --client-id toward the new ADME
#         requiredResourceAccess
#       - by default, prints one tenant-wide admin-consent action for the
#         customer app after the manifest update
#       - with --auto-grant, creates the delegated grant and, when applicable,
#         the new ADME app-role assignment for the client app
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
#   * It validates customer-tenant state by default; when HOME_CONFIG_DIR is
#     available, migrate adme-audience can use home-tenant application metadata
#     as the canonical servicePrincipalNames source for direct repair.
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
CLIENT_ID_ARG=""
CLIENT_SECRET_OVERRIDDEN=0
APP_REGISTRATIONS_PORTAL_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"

CUSTOMER_TENANT_ID=""
CUSTOMER_CONFIG_DIR=""
HOME_TENANT_ID="${HOME_TENANT_ID:-}"
HOME_CONFIG_DIR="${HOME_CONFIG_DIR:-}"

DEFAULT_OLD_RESOURCE_APP_ID="dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e"
DEFAULT_NEW_RESOURCE_APP_ID="bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc"
DEFAULT_OLD_RESOURCE_IDENTIFIER_URI="https://energy-old.azure.com"
DEFAULT_NEW_RESOURCE_IDENTIFIER_URI="https://energy.azure.com"

OLD_RESOURCE_APP_ID_SOURCE="default"
NEW_RESOURCE_APP_ID_SOURCE="default"
OLD_RESOURCE_IDENTIFIER_URI_SOURCE="default"
NEW_RESOURCE_IDENTIFIER_URI_SOURCE="default"
OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE="unset"
[[ -n "${OLD_RESOURCE_APP_ID:-}" ]] && OLD_RESOURCE_APP_ID_SOURCE="environment"
[[ -n "${NEW_RESOURCE_APP_ID:-}" ]] && NEW_RESOURCE_APP_ID_SOURCE="environment"
[[ -n "${OLD_RESOURCE_IDENTIFIER_URI:-}" ]] && OLD_RESOURCE_IDENTIFIER_URI_SOURCE="environment"
[[ -n "${NEW_RESOURCE_IDENTIFIER_URI:-}" ]] && NEW_RESOURCE_IDENTIFIER_URI_SOURCE="environment"
[[ -n "${OLD_RESOURCE_SERVICE_PRINCIPAL_ID:-}" ]] && OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE="environment"

OLD_RESOURCE_APP_ID="${OLD_RESOURCE_APP_ID:-$DEFAULT_OLD_RESOURCE_APP_ID}"
NEW_RESOURCE_APP_ID="${NEW_RESOURCE_APP_ID:-$DEFAULT_NEW_RESOURCE_APP_ID}"
OLD_RESOURCE_IDENTIFIER_URI="${OLD_RESOURCE_IDENTIFIER_URI:-$DEFAULT_OLD_RESOURCE_IDENTIFIER_URI}"
NEW_RESOURCE_IDENTIFIER_URI="${NEW_RESOURCE_IDENTIFIER_URI:-$DEFAULT_NEW_RESOURCE_IDENTIFIER_URI}"
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

TARGET_RESOURCE_SERVICE_PRINCIPAL_ID=""
TARGET_RESOURCE_SERVICE_PRINCIPAL_JSON=""
TARGET_RESOURCE_HAS_ENABLED_APP_ROLES=""

usage() {
  cat <<'EOF'
Usage:
  adme-entra-migration.sh [--state-dir dir] [--output-logging dir] [--yes] migrate adme-audience [--allow-recreate-dffa]
  adme-entra-migration.sh [--state-dir dir] [--output-logging dir] [--yes] migrate api-permissions --client-id id [--auto-grant]
  adme-entra-migration.sh [--state-dir dir] [--output-logging dir] verify [--client-id id] [--client-secret secret]

Commands:
  migrate adme-audience    Refresh the stale old resource (dffa) service principal, provision the new resource (bd0c) service principal, and wire the Azure CLI delegated grant.
                             --allow-recreate-dffa: if refresh stays stale after bounded retries, allow a delete/recreate fallback with explicit confirmation.
  migrate api-permissions  Update the selected client app to the new resource (bd0c) permissions.
                             Default: update requiredResourceAccess only and print one tenant-wide admin-consent action for the customer-app permissions required by the target resource.
                             --client-id: client appId or client servicePrincipalId to migrate.
                             --auto-grant: create the delegated grant and, when applicable, the new app-role assignment programmatically.
                             Requires Application Administrator, Cloud Application Administrator, or Global Administrator.
  verify                 Without --client-id, validate tenant audience migration and Azure CLI delegated token issuance.
                           --client-id: optional client appId or client servicePrincipalId for selected-client app-only token proof.
                           --client-secret: optional selected-client secret for the app-only token proof. Prefer CLIENT_SECRET env to avoid shell history.
                           App configuration/admin-consent status belongs to adme-entra-inventory.sh; ADME endpoint smoke belongs to test.sh.
                           Uses az + jq only; python3 + msal enables an extra forced-refresh Azure CLI delegated-token proof.

Options:
  --state-dir dir      Load simulator/runtime state from dir/sim-state.env.
  --output-logging dir Directory for structured log files. Defaults to ./migration-logs.
  --yes                 Skip the interactive confirmation prompt in TTY mode.
  --allow-recreate-dffa Only for migrate adme-audience. After refresh failure, allow the destructive dffa delete/recreate fallback.
  --client-id id        For migrate api-permissions and verify. Client appId or client servicePrincipalId to migrate/verify.
  --client-secret secret Only for verify. Secret value for the selected client app-only token proof; never logged.
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

internal_force_tier2_fallback_enabled() {
  case "${ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK:-false}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
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

old_resource_service_principal_names_are_refreshed() {
  local sp_names_json="${1:-[]}"

  jq -en \
    --argjson names "$sp_names_json" \
    --arg old "$OLD_RESOURCE_IDENTIFIER_URI" \
    --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
      ($names // []) | index($old) != null and index($shared) == null
    ' >/dev/null
}

old_resource_service_principal_has_stale_shared_audience() {
  local sp_json="$1"

  jq -e --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($old) != null and index($shared) != null
  ' <<<"$sp_json" >/dev/null
}

service_principal_names_json() {
  local sp_json="$1"

  jq -c '.servicePrincipalNames // []' <<<"$sp_json"
}

service_principal_names_json_matches_target() {
  local current_sp_names_json="${1:-[]}"
  local target_sp_names_json="${2:-[]}"

  jq -en \
    --argjson current "$current_sp_names_json" \
    --argjson target "$target_sp_names_json" '
      (($current // []) | unique | sort) == (($target // []) | unique | sort)
    ' >/dev/null
}

service_principal_names_json_has_no_duplicates() {
  local sp_names_json="${1:-[]}"

  jq -en \
    --argjson names "$sp_names_json" '
      ($names // []) as $value
      | ($value | length) == ($value | unique | length)
    ' >/dev/null
}

build_old_resource_target_service_principal_names_json() {
  local current_sp_names_json="${1:-[]}"

  jq -cn \
    --argjson current "$current_sp_names_json" \
    --arg old "$OLD_RESOURCE_IDENTIFIER_URI" \
    --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
      (($current // []) | map(select(. != $shared))) + [$old]
      | unique
    '
}

new_resource_service_principal_owns_shared_audience() {
  local sp_json="$1"

  jq -e --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($shared) != null
  ' <<<"$sp_json" >/dev/null
}

service_principal_names_json_owns_shared_audience() {
  local sp_names_json="${1:-[]}"

  jq -en \
    --argjson names "$sp_names_json" \
    --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '
      ($names // []) | index($shared) != null
    ' >/dev/null
}

target_resource_service_principal_json() {
  local sp_id="$1"

  if [[ "$TARGET_RESOURCE_SERVICE_PRINCIPAL_ID" != "$sp_id" || -z "$TARGET_RESOURCE_SERVICE_PRINCIPAL_JSON" ]]; then
    TARGET_RESOURCE_SERVICE_PRINCIPAL_JSON="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$sp_id")"
    TARGET_RESOURCE_SERVICE_PRINCIPAL_ID="$sp_id"
  fi

  printf '%s\n' "$TARGET_RESOURCE_SERVICE_PRINCIPAL_JSON"
}

target_resource_has_enabled_app_roles() {
  local sp_json="$1"

  jq -e '
    any((.appRoles // [])[]?; (.isEnabled // true))
  ' <<<"$sp_json" >/dev/null
}

target_resource_has_configured_scope() {
  local sp_json="$1"

  jq -e \
    --arg scopeId "$NEW_RESOURCE_SCOPE_ID" \
    --arg scopeValue "$NEW_RESOURCE_SCOPE_VALUE" '
      any((.oauth2PermissionScopes // [])[]?;
        (.isEnabled // true)
        and .id == $scopeId
        and .value == $scopeValue
      )
    ' <<<"$sp_json" >/dev/null
}

target_resource_has_configured_app_role() {
  local sp_json="$1"

  jq -e \
    --arg roleId "$NEW_RESOURCE_APP_ROLE_ID" \
    --arg roleValue "$NEW_RESOURCE_APP_ROLE_VALUE" '
      any((.appRoles // [])[]?;
        (.isEnabled // true)
        and .id == $roleId
        and .value == $roleValue
      )
    ' <<<"$sp_json" >/dev/null
}

target_resource_requires_app_role_assignment() {
  if [[ "${TARGET_RESOURCE_HAS_ENABLED_APP_ROLES:-}" == "1" ]]; then
    return 0
  fi
  if [[ "${TARGET_RESOURCE_HAS_ENABLED_APP_ROLES:-}" == "0" ]]; then
    return 1
  fi
  [[ -n "$NEW_RESOURCE_APP_ROLE_ID" ]]
}

target_resource_permission_shape_label() {
  if target_resource_requires_app_role_assignment; then
    printf 'Role + Scope\n'
  else
    printf 'Scope-only\n'
  fi
}

validate_target_resource_permissions_contract() {
  local sp_id="$1"
  local sp_json enabled_app_role_count enabled_scope_count

  sp_json="$(target_resource_service_principal_json "$sp_id")"
  TARGET_RESOURCE_HAS_ENABLED_APP_ROLES="0"

  target_resource_has_configured_scope "$sp_json" \
    || die "Target resource service principal $sp_id does not expose enabled scope '$NEW_RESOURCE_SCOPE_VALUE' ($NEW_RESOURCE_SCOPE_ID)"

  if target_resource_has_enabled_app_roles "$sp_json"; then
    TARGET_RESOURCE_HAS_ENABLED_APP_ROLES="1"
    [[ -n "$NEW_RESOURCE_APP_ROLE_ID" ]] || die "NEW_RESOURCE_APP_ROLE_ID is required because target resource service principal $sp_id exposes enabled app roles"
    [[ -n "$NEW_RESOURCE_APP_ROLE_VALUE" ]] || die "NEW_RESOURCE_APP_ROLE_VALUE is required because target resource service principal $sp_id exposes enabled app roles"
    target_resource_has_configured_app_role "$sp_json" \
      || die "Target resource service principal $sp_id does not expose enabled app role '$NEW_RESOURCE_APP_ROLE_VALUE' ($NEW_RESOURCE_APP_ROLE_ID)"
  fi

  enabled_app_role_count="$(jq -r '[.appRoles[]? | select(.isEnabled // true)] | length' <<<"$sp_json")"
  enabled_scope_count="$(jq -r '[.oauth2PermissionScopes[]? | select(.isEnabled // true)] | length' <<<"$sp_json")"
  log INFO "Target resource capabilities: permissionShape=$(target_resource_permission_shape_label | tr -d '\n') enabledAppRoles=$enabled_app_role_count enabledScopes=$enabled_scope_count"
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

config_file_defines_var() {
  local file="$1"
  local var_name="$2"

  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${var_name}=" "$file"
}

mark_resource_config_sources_from_state_file() {
  local state_env_file="$1"

  config_file_defines_var "$state_env_file" OLD_RESOURCE_APP_ID \
    && OLD_RESOURCE_APP_ID_SOURCE="$state_env_file"
  config_file_defines_var "$state_env_file" NEW_RESOURCE_APP_ID \
    && NEW_RESOURCE_APP_ID_SOURCE="$state_env_file"
  config_file_defines_var "$state_env_file" OLD_RESOURCE_IDENTIFIER_URI \
    && OLD_RESOURCE_IDENTIFIER_URI_SOURCE="$state_env_file"
  config_file_defines_var "$state_env_file" NEW_RESOURCE_IDENTIFIER_URI \
    && NEW_RESOURCE_IDENTIFIER_URI_SOURCE="$state_env_file"
  config_file_defines_var "$state_env_file" OLD_RESOURCE_SERVICE_PRINCIPAL_ID \
    && OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE="$state_env_file"
}

resource_config_source() {
  local var_name="$1"

  case "$var_name" in
    OLD_RESOURCE_APP_ID) printf '%s\n' "$OLD_RESOURCE_APP_ID_SOURCE" ;;
    NEW_RESOURCE_APP_ID) printf '%s\n' "$NEW_RESOURCE_APP_ID_SOURCE" ;;
    OLD_RESOURCE_IDENTIFIER_URI) printf '%s\n' "$OLD_RESOURCE_IDENTIFIER_URI_SOURCE" ;;
    NEW_RESOURCE_IDENTIFIER_URI) printf '%s\n' "$NEW_RESOURCE_IDENTIFIER_URI_SOURCE" ;;
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID) printf '%s\n' "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

using_non_default_resource_config() {
  [[ "$OLD_RESOURCE_APP_ID" != "$DEFAULT_OLD_RESOURCE_APP_ID" \
    || "$NEW_RESOURCE_APP_ID" != "$DEFAULT_NEW_RESOURCE_APP_ID" \
    || "$OLD_RESOURCE_IDENTIFIER_URI" != "$DEFAULT_OLD_RESOURCE_IDENTIFIER_URI" \
    || "$NEW_RESOURCE_IDENTIFIER_URI" != "$DEFAULT_NEW_RESOURCE_IDENTIFIER_URI" ]]
}

log_verify_resource_override_hint() {
  if [[ "$COMMAND/$SUBCOMMAND" != "verify/" || "$STATE_DIR_EXPLICIT" -eq 1 ]]; then
    return
  fi

  if using_non_default_resource_config; then
    log_warn "verify is using non-default ADME resource configuration from the current shell/environment."
    log_warn "  OLD_RESOURCE_APP_ID=$OLD_RESOURCE_APP_ID (source: $(resource_config_source OLD_RESOURCE_APP_ID))"
    log_warn "  NEW_RESOURCE_APP_ID=$NEW_RESOURCE_APP_ID (source: $(resource_config_source NEW_RESOURCE_APP_ID))"
    log_warn "  OLD_RESOURCE_IDENTIFIER_URI=$OLD_RESOURCE_IDENTIFIER_URI (source: $(resource_config_source OLD_RESOURCE_IDENTIFIER_URI))"
    log_warn "  NEW_RESOURCE_IDENTIFIER_URI=$NEW_RESOURCE_IDENTIFIER_URI (source: $(resource_config_source NEW_RESOURCE_IDENTIFIER_URI))"
    log_warn "For standard dffa/bd0c verification, unset resource overrides or run from a clean shell. For simulator/custom verification, prefer --state-dir <dir>."
  fi
}

die_unresolved_old_resource_service_principal() {
  log ERROR "OLD_RESOURCE_SERVICE_PRINCIPAL_ID could not be resolved in tenant $CUSTOMER_TENANT_ID for OLD_RESOURCE_APP_ID $OLD_RESOURCE_APP_ID (source: $(resource_config_source OLD_RESOURCE_APP_ID))"
  log ERROR "Current resource config: OLD_RESOURCE_APP_ID=$OLD_RESOURCE_APP_ID ($(resource_config_source OLD_RESOURCE_APP_ID)); NEW_RESOURCE_APP_ID=$NEW_RESOURCE_APP_ID ($(resource_config_source NEW_RESOURCE_APP_ID)); OLD_RESOURCE_IDENTIFIER_URI=$OLD_RESOURCE_IDENTIFIER_URI ($(resource_config_source OLD_RESOURCE_IDENTIFIER_URI)); NEW_RESOURCE_IDENTIFIER_URI=$NEW_RESOURCE_IDENTIFIER_URI ($(resource_config_source NEW_RESOURCE_IDENTIFIER_URI))"

  if [[ "$STATE_DIR_EXPLICIT" -eq 0 && "$OLD_RESOURCE_APP_ID" != "$DEFAULT_OLD_RESOURCE_APP_ID" ]]; then
    log ERROR "For standard dffa/bd0c verification, unset OLD_RESOURCE_APP_ID OLD_RESOURCE_SERVICE_PRINCIPAL_ID NEW_RESOURCE_APP_ID OLD_RESOURCE_IDENTIFIER_URI NEW_RESOURCE_IDENTIFIER_URI, then rerun verify."
    log ERROR "For simulator or custom-resource verification, pass --state-dir <dir> or set OLD_RESOURCE_APP_ID to an appId that has a service principal in the customer tenant."
  else
    log ERROR "Confirm the old resource service principal exists in the customer tenant, or run adme-entra-inventory.sh to inspect current audience state."
  fi

  exit 1
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
    CLIENT_SECRET_OVERRIDDEN=1
  fi

  if [[ "$STATE_DIR_EXPLICIT" -eq 1 ]]; then
    state_env_file="$STATE_DIR/sim-state.env"
    [[ -f "$state_env_file" ]] || die "Runtime state file not found: $state_env_file"
    mark_resource_config_sources_from_state_file "$state_env_file"
    # shellcheck disable=SC1090
    source "$state_env_file"
    state_source="$state_env_file"
  fi

  if [[ "$has_client_secret_override" -eq 1 ]]; then
    CLIENT_SECRET="$client_secret_override"
  fi

  CUSTOMER_TENANT_ID="${CUSTOMER_TENANT_ID:-}"
  CUSTOMER_CONFIG_DIR="$(current_config_dir)"
  HOME_TENANT_ID="${HOME_TENANT_ID:-}"
  HOME_CONFIG_DIR="${HOME_CONFIG_DIR:-}"
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
        NEW_RESOURCE_SCOPE_ID
        NEW_RESOURCE_SCOPE_VALUE
      )
      ;;
    verify/)
      placeholder_vars+=(
        OLD_RESOURCE_SERVICE_PRINCIPAL_ID
        NEW_RESOURCE_SCOPE_VALUE
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

  log_verify_resource_override_hint

  if [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] && ! service_principal_exists_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID"; then
    log_warn "Configured OLD_RESOURCE_SERVICE_PRINCIPAL_ID $OLD_RESOURCE_SERVICE_PRINCIPAL_ID (source: $(resource_config_source OLD_RESOURCE_SERVICE_PRINCIPAL_ID)) was not found in tenant $CUSTOMER_TENANT_ID; resolving the old resource (dffa) service principal again by OLD_RESOURCE_APP_ID $OLD_RESOURCE_APP_ID (source: $(resource_config_source OLD_RESOURCE_APP_ID))"
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID=""
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE="unresolved"
  fi

  if [[ -z "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]]; then
    OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_APP_ID")"
    [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] && OLD_RESOURCE_SERVICE_PRINCIPAL_ID_SOURCE="resolved from OLD_RESOURCE_APP_ID"
  fi

  case "$COMMAND/$SUBCOMMAND" in
    migrate/adme-audience)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] || die "OLD_RESOURCE_SERVICE_PRINCIPAL_ID could not be resolved for appId $OLD_RESOURCE_APP_ID"
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
      ;;
    migrate/api-permissions)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$NEW_RESOURCE_SCOPE_ID" ]] || die "NEW_RESOURCE_SCOPE_ID is required from $state_source or the environment"
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
      ;;
    verify/)
      [[ -n "$CUSTOMER_TENANT_ID" ]] || die "CUSTOMER_TENANT_ID is required from $state_source or the current Azure CLI context"
      [[ -n "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" ]] || die_unresolved_old_resource_service_principal
      [[ -n "$NEW_RESOURCE_SCOPE_VALUE" ]] || die "NEW_RESOURCE_SCOPE_VALUE is required from $state_source or the environment"
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

resolve_selected_client() {
  local client_id="$1"
  local purpose="$2"
  local service_principal_json application_json
  local selected_display_name

  [[ -n "$client_id" ]] || die "--client-id is required for '$purpose'"

  if service_principal_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$client_id" 2>/dev/null)"; then
    CLIENT_SERVICE_PRINCIPAL_ID="$(jq -r '.id // empty' <<<"$service_principal_json")"
    CLIENT_APP_ID="$(jq -r '.appId // empty' <<<"$service_principal_json")"
  else
    CLIENT_APP_ID="$client_id"
    CLIENT_SERVICE_PRINCIPAL_ID="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_ID")"
    [[ -n "$CLIENT_SERVICE_PRINCIPAL_ID" ]] || die "No client service principal found for --client-id '$client_id'. Pass a client appId or client servicePrincipalId from the customer tenant."
    service_principal_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID")"
  fi

  [[ -n "$CLIENT_APP_ID" ]] || die "Resolved client service principal '$client_id' is missing appId"
  [[ -n "$CLIENT_SERVICE_PRINCIPAL_ID" ]] || die "Unable to resolve client servicePrincipalId from --client-id '$client_id'"

  if ! application_json="$(application_json_by_app_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_ID" 2>/dev/null)"; then
    die "No customer-owned application registration found for client appId '$CLIENT_APP_ID'. $purpose requires a local app registration."
  fi
  CLIENT_APP_OBJECT_ID="$(jq -r '.id // empty' <<<"$application_json")"
  [[ -n "$CLIENT_APP_OBJECT_ID" ]] || die "Resolved client app '$CLIENT_APP_ID' is missing application object id"

  selected_display_name="$(jq -r '.displayName // "<unnamed>"' <<<"$application_json")"
  log INFO "Resolved --client-id '$client_id' to client app '$selected_display_name'"
  log INFO "  client appId: $CLIENT_APP_ID"
  log INFO "  client applicationObjectId: $CLIENT_APP_OBJECT_ID"
  log INFO "  client servicePrincipalId: $CLIENT_SERVICE_PRINCIPAL_ID"
}

select_matching_client_secret_for_verify() {
  local state_client_app_id="$1"
  local matched_secret=""

  if [[ "$CLIENT_SECRET_OVERRIDDEN" -eq 1 ]]; then
    return 0
  fi

  case "$CLIENT_APP_ID" in
    "${SIM_3P_CLIENT_APP_ID:-}")
      matched_secret="${SIM_3P_CLIENT_SECRET:-}"
      ;;
    "${SIM_3P_CLIENT_2_APP_ID:-}")
      matched_secret="${SIM_3P_CLIENT_2_SECRET:-}"
      ;;
    "${SIM_3P_CLIENT_3_APP_ID:-}")
      matched_secret="${SIM_3P_CLIENT_3_SECRET:-}"
      ;;
  esac

  if [[ -n "$matched_secret" ]]; then
    CLIENT_SECRET="$matched_secret"
    log INFO "Using matching simulator client secret from runtime state for selected client appId $CLIENT_APP_ID"
    return 0
  fi

  if [[ -n "${CLIENT_SECRET:-}" && "$state_client_app_id" != "$CLIENT_APP_ID" ]]; then
    log_warn "Ignoring CLIENT_SECRET from runtime state because it belongs to client appId $state_client_app_id, but verify selected client appId $CLIENT_APP_ID"
    CLIENT_SECRET=""
  fi
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

patch_service_principal_names() {
  local config_dir="$1"
  local sp_id="$2"
  local sp_names_json="$3"
  local body stderr_file patch_error

  body="$(jq -cn --argjson servicePrincipalNames "$sp_names_json" '{servicePrincipalNames: $servicePrincipalNames}')"
  stderr_file="$(mktemp)"
  if run_az "$config_dir" rest --method PATCH --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id" --body "$body" -o json >/dev/null 2>"$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  fi

  patch_error="$(<"$stderr_file")"
  rm -f "$stderr_file"
  printf '%s\n' "${patch_error:-<no stderr>}"
  return 1
}

format_service_principal_names_patch_error() {
  local patch_error="$1"

  if [[ "$patch_error" == *"Property servicePrincipalNames on the service principal does not match the application object"* ]]; then
    printf '%s\n' "Graph rejected the direct repair because servicePrincipalNames are controlled by the home application object. Direct PATCH cannot fix this tenant state; use the default safe stop or the approved delete/recreate fallback."
    return 0
  fi

  printf '%s\n' "$patch_error"
}

ensure_oauth2_permission_grant() {
  local label="$1"
  local config_dir="$2"
  local client_sp_id="$3"
  local resource_sp_id="$4"
  local scope_value="$5"
  local existing_json existing_grant_id existing_scope merged_scope body stderr_file grant_error

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
  stderr_file="$(mktemp)"
  if ! run_az "$config_dir" rest --method POST --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" --body "$body" -o json >/dev/null 2>"$stderr_file"; then
    grant_error="$(<"$stderr_file")"
    rm -f "$stderr_file"
    if [[ "$grant_error" == *"Permission entry already exists"* ]]; then
      log INFO "$label is already satisfied by an existing permission entry or the resource application's pre-authorized-client consent model"
      return 0
    fi
    die "Failed to create $label: ${grant_error:-<no stderr>}"
  fi
  rm -f "$stderr_file"
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

  if target_resource_requires_app_role_assignment; then
    log "$level" "Complete one tenant-wide admin-consent action for the updated customer app to grant both the target-resource app role and delegated scope."
  else
    log "$level" "Complete one tenant-wide admin-consent action for the updated customer app to grant the target-resource delegated scope."
  fi
  log "$level" "Azure portal: App registrations -> client app -> API permissions -> Grant admin consent"
  log "$level" "Portal link: $portal_url"
  log "$level" "Locate the client app by appId: $CLIENT_APP_ID"
}

application_json_by_object_id() {
  local config_dir="$1"
  local application_object_id="$2"
  graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/applications/$application_object_id"
}

application_json_by_app_id() {
  local config_dir="$1"
  local app_id="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/applications?\$filter=appId eq '$app_id'&\$select=id,appId,displayName,identifierUris" \
    | jq -c -e '.value[0] // empty'
}

home_tenant_context_is_usable() {
  local actual_tenant_id

  [[ -n "${HOME_CONFIG_DIR:-}" ]] || return 1

  if [[ -n "${HOME_TENANT_ID:-}" ]]; then
    if ! actual_tenant_id="$(current_tenant_id "$HOME_CONFIG_DIR" 2>/dev/null)"; then
      log_warn "HOME_CONFIG_DIR is set, but Azure CLI home-tenant context could not be read; direct repair will use customer-tenant state only."
      return 1
    fi
    if [[ "$actual_tenant_id" != "$HOME_TENANT_ID" ]]; then
      log_warn "HOME_CONFIG_DIR points to tenant $actual_tenant_id, expected home tenant $HOME_TENANT_ID; direct repair will use customer-tenant state only."
      return 1
    fi
  fi

  return 0
}

home_application_service_principal_names_json() {
  local label="$1"
  local app_id="$2"
  local app_json

  home_tenant_context_is_usable || return 1

  if ! app_json="$(application_json_by_app_id "$HOME_CONFIG_DIR" "$app_id" 2>/dev/null)"; then
    log_warn "Home-tenant application metadata for $label appId $app_id was not available; direct repair will use customer-tenant state only."
    return 1
  fi

  jq -c --arg appId "$app_id" '
    ([$appId] + (.identifierUris // []))
    | map(select(. != null and . != ""))
    | unique
  ' <<<"$app_json"
}

assert_internal_tier2_fallback_fixture() {
  [[ -n "${STATE_JSON_FILE:-}" ]] || die "ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK is only supported with simulator state; STATE_JSON_FILE is not set."
  [[ -f "$STATE_JSON_FILE" ]] || die "ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK is only supported with simulator state; file not found: $STATE_JSON_FILE"

  jq -e --arg appId "$OLD_RESOURCE_APP_ID" '
    (.internal.forceTier2Fallback // false) == true
    and (.apps.simDffa.appId // "") == $appId
  ' "$STATE_JSON_FILE" >/dev/null \
    || die "ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK is only supported for simulator state created by the internal simulator with that flag enabled."
}

build_new_resource_required_resource_access_json() {
  local current_required_resource_access_json="${1:-[]}"
  local include_role="false"

  if target_resource_requires_app_role_assignment; then
    include_role="true"
  fi

  jq -cn \
    --argjson currentRequiredResourceAccess "$current_required_resource_access_json" \
    --arg oldResourceAppId "$OLD_RESOURCE_APP_ID" \
    --arg resourceAppId "$NEW_RESOURCE_APP_ID" \
    --arg roleId "$NEW_RESOURCE_APP_ROLE_ID" \
    --arg scopeId "$NEW_RESOURCE_SCOPE_ID" \
    --arg includeRole "$include_role" \
    '
      def desired_entries:
        ([{id: $scopeId, type: "Scope"}]
         + if $includeRole == "true" then [{id: $roleId, type: "Role"}] else [] end);
      def existing_new_resource_entries($current):
        [
          $current[]?
          | select(.resourceAppId == $resourceAppId)
          | .resourceAccess[]?
          | if $includeRole == "true" then .
            else select(.type != "Role")
            end
        ];
      def normalize_entries($entries):
        $entries
        | map(select((.id // "") != "" and (.type // "") != ""))
        | unique_by(.type, .id)
        | sort_by(.type, .id);
      ($currentRequiredResourceAccess // []) as $current
      | (normalize_entries(existing_new_resource_entries($current) + desired_entries)) as $mergedNewResourceAccess
      | ($current
          | map(select(.resourceAppId != $oldResourceAppId and .resourceAppId != $resourceAppId)))
        + [
            {
              resourceAppId: $resourceAppId,
              resourceAccess: $mergedNewResourceAccess
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
  local expect_role="false"

  if target_resource_requires_app_role_assignment; then
    expect_role="true"
  fi

  jq -e \
    --arg resourceAppId "$NEW_RESOURCE_APP_ID" \
    --arg roleId "$NEW_RESOURCE_APP_ROLE_ID" \
    --arg scopeId "$NEW_RESOURCE_SCOPE_ID" '
      (.requiredResourceAccess // []) as $rra
      | [$rra[] | select(.resourceAppId == $resourceAppId)] as $newEntries
      | (($newEntries | length) == 1)
      and any($newEntries[0].resourceAccess[]?; .id == $scopeId and .type == "Scope")
      and (
        if $expectRole == "true" then
          any($newEntries[0].resourceAccess[]?; .id == $roleId and .type == "Role")
        else
          all($newEntries[0].resourceAccess[]?; .type != "Role")
        end
      )
    ' --arg expectRole "$expect_role" <<<"$application_json" >/dev/null
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
    log INFO "client app requiredResourceAccess already references new resource (bd0c)"
    return 0
  fi

  current_required_resource_access="$(jq -c '.requiredResourceAccess // []' <<<"$current_application_json")"
  desired_rra="$(build_new_resource_required_resource_access_json "$current_required_resource_access")"
  body="$(jq -cn --argjson requiredResourceAccess "$desired_rra" '{requiredResourceAccess: $requiredResourceAccess}')"
  graph_request_json "$CUSTOMER_CONFIG_DIR" PATCH "https://graph.microsoft.com/v1.0/applications/$CLIENT_APP_OBJECT_ID" "$body" >/dev/null

  updated_application_json="$(application_json_by_object_id "$CUSTOMER_CONFIG_DIR" "$CLIENT_APP_OBJECT_ID")"
  required_resource_access_matches_new_resource "$updated_application_json" "$current_application_json" \
    || die "client app requiredResourceAccess did not update to new resource (bd0c) while preserving unrelated entries"
  log_success "Updated client app requiredResourceAccess to new resource (bd0c)"
  log INFO "Updated client app requiredResourceAccess: $(jq -c '.requiredResourceAccess // []' <<<"$updated_application_json")"
}

find_matching_app_role_assignment_id() {
  local resource_sp_id="$1"
  local assignments_json

  if ! target_resource_requires_app_role_assignment || [[ -z "$NEW_RESOURCE_APP_ROLE_ID" ]]; then
    printf '\n'
    return 0
  fi

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

  if ! target_resource_requires_app_role_assignment || [[ -z "$NEW_RESOURCE_APP_ROLE_ID" ]]; then
    printf '0\n'
    return 0
  fi

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

  if ! target_resource_requires_app_role_assignment || [[ -z "$NEW_RESOURCE_APP_ROLE_ID" ]]; then
    log INFO "Skipping app-role assignment because the target resource exposes no enabled app roles"
    return 0
  fi

  existing_assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id")"
  if [[ -n "$existing_assignment_id" ]]; then
    log INFO "client app already has app role assignment $existing_assignment_id on new resource (bd0c)"
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
  log_success "Created client app -> new resource (bd0c) app role assignment"
}

wait_for_app_role_assignment() {
  local resource_sp_id="$1"
  local attempt assignment_id

  if ! target_resource_requires_app_role_assignment || [[ -z "$NEW_RESOURCE_APP_ROLE_ID" ]]; then
    printf '\n'
    return 0
  fi

  for attempt in 1 2 3; do
    assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id")"
    if [[ -n "$assignment_id" ]]; then
      log_success "Verified client app app role assignment on attempt $attempt: $assignment_id"
      printf '%s\n' "$assignment_id"
      return 0
    fi
    sleep 3
  done

  die "client app app role assignment to new resource (bd0c) was not visible after creation"
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
  local app_only_output app_only_aud app_only_azp app_only_secret
  local app_only_proof_attempted=0 app_only_proof_ran=0
  local delegated_scope delegated_json delegated_claims_json delegated_aud delegated_scp delegated_azp
  local delegated_error delegated_error_description
  local delegated_skip delegated_warning delegated_proof_ran=0
  local azure_cli_customer_sp_id azure_cli_delegated_grant_count
  local verify_failures=0
  local selected_client_verify=0 state_client_app_id

  log_step "Loading runtime state and validating verification prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"

  if [[ -n "$CLIENT_ID_ARG" ]]; then
    selected_client_verify=1
    state_client_app_id="$CLIENT_APP_ID"
    resolve_selected_client "$CLIENT_ID_ARG" "verify"
    select_matching_client_secret_for_verify "$state_client_app_id"
  else
    log INFO "Running tenant/audience verification because --client-id was not provided; selected-client app-only proof is skipped."
    if [[ "$CLIENT_SECRET_OVERRIDDEN" -eq 1 && -n "${CLIENT_SECRET:-}" ]]; then
      log_warn "Ignoring CLIENT_SECRET because verify without --client-id does not run the selected-client app-only proof. Use verify --client-id <client-app-id> to test app-only."
    fi
  fi

  log_step "Checking customer-tenant service principal state"
  dffa_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
  dffa_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$dffa_customer_sp_json")"
  if old_resource_service_principal_is_refreshed "$dffa_customer_sp_json"; then
    log_success "Verified customer old resource (dffa) servicePrincipalNames: $dffa_customer_sp_names"
    log_success "Verified customer old resource (dffa) no longer owns shared audience $NEW_RESOURCE_IDENTIFIER_URI"
  else
    log ERROR "FAIL: customer old resource (dffa) servicePrincipalNames are not refreshed to the old identifierUri: $dffa_customer_sp_names"
    verify_failures=$((verify_failures + 1))
  fi

  bd0c_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"
  [[ -n "$bd0c_customer_sp_id" ]] || die "Customer new resource (bd0c) service principal not found"
  bd0c_customer_sp_json="$(target_resource_service_principal_json "$bd0c_customer_sp_id")"
  validate_target_resource_permissions_contract "$bd0c_customer_sp_id"
  bd0c_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$bd0c_customer_sp_json")"
  if new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json"; then
    log_success "Verified customer new resource (bd0c) servicePrincipalNames: $bd0c_customer_sp_names"
    log_success "Verified customer new resource (bd0c) owns shared audience $NEW_RESOURCE_IDENTIFIER_URI"
  else
    log ERROR "FAIL: customer new resource (bd0c) servicePrincipalNames do not include $NEW_RESOURCE_IDENTIFIER_URI: $bd0c_customer_sp_names"
    verify_failures=$((verify_failures + 1))
  fi

  if [[ "$selected_client_verify" -eq 1 ]]; then
    log_step "Validating selected-client runtime token proof"
    log INFO "Selected-client verify is token-focused; run adme-entra-inventory.sh for API-permission and admin-consent status."
    app_only_secret="${CLIENT_SECRET:-}"
    if ! target_resource_requires_app_role_assignment; then
      log INFO "Skipping the selected-client app-only token proof because the target resource exposes no enabled app roles."
      log INFO "Use verify without --client-id for the Azure CLI delegated token proof, and use test.sh to call the ADME endpoint."
    elif [[ -n "$app_only_secret" ]]; then
      log_step "Validating the post-migration app-only token"
      app_only_proof_attempted=1
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
        log ERROR "FAIL: Post-migration app-only token acquisition failed"
        log_warn "App-only proof uses the selected client app secret value for appId $CLIENT_APP_ID."
        log_warn "Remedy: export CLIENT_SECRET=<CLIENT_SECRET> with the secret value (not the secret ID), then rerun verify --client-id $CLIENT_APP_ID."
        log_warn "If you do not have the secret value, create a new client secret for this app registration; Entra cannot reveal existing secret values."
        verify_failures=$((verify_failures + 1))
      else
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          log INFO "app-only: $line"
        done <<<"$app_only_output"
        app_only_aud="$(extract_json_claim_from_text "aud" "$app_only_output")"
        app_only_azp="$(extract_json_claim_from_text "azp" "$app_only_output")"
        if [[ "$app_only_aud" != "$NEW_RESOURCE_APP_ID" ]]; then
          log ERROR "FAIL: App-only token aud '$app_only_aud' did not match new resource (bd0c) appId '$NEW_RESOURCE_APP_ID'"
          verify_failures=$((verify_failures + 1))
        elif [[ "$app_only_azp" != "$CLIENT_APP_ID" ]]; then
          log ERROR "FAIL: App-only token azp '$app_only_azp' did not match client app appId '$CLIENT_APP_ID'"
          verify_failures=$((verify_failures + 1))
        else
          app_only_proof_ran=1
          log_success "Verified app-only token aud=$app_only_aud azp=$app_only_azp"
        fi
      fi
    else
      log_warn "Skipping the selected-client app-only token proof because no matching selected-client secret was available from state, CLIENT_SECRET, or --client-secret."
      log_warn "To run the app-only proof, export CLIENT_SECRET=<CLIENT_SECRET> with the selected client app secret value, then rerun verify --client-id $CLIENT_APP_ID."
    fi
  else
    log INFO "Skipping selected-client app-only proof because --client-id was not provided."
  fi

  if [[ "$selected_client_verify" -eq 0 ]]; then
    log_step "Checking the Azure CLI delegated grant wiring for new resource (bd0c)"
    azure_cli_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"
    [[ -n "$azure_cli_customer_sp_id" ]] || die "Customer Microsoft Azure CLI service principal not found"
    azure_cli_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$azure_cli_customer_sp_id" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"
    if (( azure_cli_delegated_grant_count >= 1 )); then
      log_success "Verified Azure CLI delegated grant wiring for new resource (bd0c) scope '$NEW_RESOURCE_SCOPE_VALUE'"
    else
      log_warn "Azure CLI oauth2PermissionGrant row for new resource (bd0c) scope '$NEW_RESOURCE_SCOPE_VALUE' was not found; attempting delegated token proof in case the resource uses pre-authorized-client consent"
    fi

    log_step "Validating the Azure CLI delegated token diagnostic with a forced refresh to avoid stale Azure CLI cache hits"
    delegated_scope="$NEW_RESOURCE_IDENTIFIER_URI/$NEW_RESOURCE_SCOPE_VALUE"
    delegated_json="$(acquire_azure_cli_delegated_token_force_refresh "$delegated_scope" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID")"
    delegated_skip="$(jq -r '.skipped // false' <<<"$delegated_json")"
    delegated_warning="$(jq -r '.warning // empty' <<<"$delegated_json")"
    if [[ "$delegated_skip" == "true" ]]; then
      [[ -n "$delegated_warning" ]] || delegated_warning="Skipping delegated forced-refresh proof because python3 with msal is unavailable."
      log_warn "$delegated_warning"
      delegated_json="$(acquire_azure_cli_delegated_token "$delegated_scope" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID")"
      delegated_error="$(jq -r '.error // empty' <<<"$delegated_json")"
      delegated_error_description="$(jq -r '.error_description // empty' <<<"$delegated_json")"
      if [[ -n "$delegated_error" ]]; then
        [[ -n "$delegated_error_description" ]] || delegated_error_description="<no description>"
        if (( azure_cli_delegated_grant_count == 0 )); then
          log ERROR "FAIL: Azure CLI oauth2PermissionGrant row is missing and delegated token fallback failed: $delegated_error ($delegated_error_description)"
        else
          log ERROR "FAIL: Azure CLI delegated token fallback failed: $delegated_error ($delegated_error_description)"
        fi
        if [[ "$delegated_error_description" == *"AADSTS65001"* ]]; then
          log_warn "Run once: AZURE_CONFIG_DIR=\"$CUSTOMER_CONFIG_DIR\" az login --tenant \"$CUSTOMER_TENANT_ID\" --scope \"$delegated_scope\" --allow-no-subscriptions"
        fi
        verify_failures=$((verify_failures + 1))
      else
        log_warn "Using az account get-access-token fallback and validating token claims because forced refresh is unavailable"
        delegated_claims_json="$(decode_jwt_payload_json "$(jq -r '.access_token // empty' <<<"$delegated_json")")"
        delegated_aud="$(jq -r '.aud // empty' <<<"$delegated_claims_json")"
        delegated_scp="$(jq -r '.scp // empty' <<<"$delegated_claims_json")"
        delegated_azp="$(jq -r '.azp // empty' <<<"$delegated_claims_json")"
        if [[ "$delegated_aud" != "$NEW_RESOURCE_APP_ID" ]]; then
          log ERROR "FAIL: Delegated token aud '$delegated_aud' did not match new resource (bd0c) appId '$NEW_RESOURCE_APP_ID'"
          verify_failures=$((verify_failures + 1))
        elif [[ "$delegated_scp" != "$NEW_RESOURCE_SCOPE_VALUE" ]]; then
          log ERROR "FAIL: Delegated token scp '$delegated_scp' did not match '$NEW_RESOURCE_SCOPE_VALUE'"
          verify_failures=$((verify_failures + 1))
        elif [[ "$delegated_azp" != "$AZURE_CLI_APP_ID" ]]; then
          log ERROR "FAIL: Delegated token azp '$delegated_azp' did not match Microsoft Azure CLI appId '$AZURE_CLI_APP_ID'"
          verify_failures=$((verify_failures + 1))
        else
          delegated_proof_ran=1
          log_success "Verified Azure CLI delegated token aud=$delegated_aud azp=$delegated_azp scp=$delegated_scp"
          if (( azure_cli_delegated_grant_count == 0 )); then
            log_success "Verified Azure CLI delegated access by token proof without an oauth2PermissionGrant row; target resource likely uses pre-authorized-client consent"
          fi
        fi
      fi
    else
      delegated_error="$(jq -r '.error // empty' <<<"$delegated_json")"
      delegated_error_description="$(jq -r '.error_description // empty' <<<"$delegated_json")"
      if [[ -n "$delegated_error" ]]; then
        if jq -e '(.error_codes // []) | index(65001) != null' >/dev/null <<<"$delegated_json"; then
          delegated_json="$(acquire_azure_cli_delegated_token "$delegated_scope" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID")"
          delegated_error="$(jq -r '.error // empty' <<<"$delegated_json")"
          delegated_error_description="$(jq -r '.error_description // empty' <<<"$delegated_json")"
          if [[ -z "$delegated_error" ]]; then
            log_warn "Azure CLI MSAL force-refresh returned consent_required for scope $delegated_scope; using az account get-access-token fallback and validating token claims to reject stale cache hits"
          else
            log_warn "Azure CLI forced-refresh delegated token request still requires one-time interactive consent for scope $delegated_scope"
            log_warn "Run once: AZURE_CONFIG_DIR=\"$CUSTOMER_CONFIG_DIR\" az login --tenant \"$CUSTOMER_TENANT_ID\" --scope \"$delegated_scope\" --allow-no-subscriptions"
            [[ -n "$delegated_error_description" ]] || delegated_error_description="<no description>"
            log ERROR "FAIL: Azure CLI delegated diagnostic is blocked until the operator completes the one-time Azure CLI consent for $delegated_scope: $delegated_error ($delegated_error_description)"
            verify_failures=$((verify_failures + 1))
          fi
        else
          [[ -n "$delegated_error_description" ]] || delegated_error_description="<no description>"
          log ERROR "FAIL: Azure CLI delegated token diagnostic failed: $delegated_error ($delegated_error_description)"
          verify_failures=$((verify_failures + 1))
        fi
      fi

      if [[ -z "$delegated_error" ]]; then
        delegated_claims_json="$(decode_jwt_payload_json "$(jq -r '.access_token // empty' <<<"$delegated_json")")"
        delegated_aud="$(jq -r '.aud // empty' <<<"$delegated_claims_json")"
        delegated_scp="$(jq -r '.scp // empty' <<<"$delegated_claims_json")"
        delegated_azp="$(jq -r '.azp // empty' <<<"$delegated_claims_json")"
        if [[ "$delegated_aud" != "$NEW_RESOURCE_APP_ID" ]]; then
          log ERROR "FAIL: Delegated token aud '$delegated_aud' did not match new resource (bd0c) appId '$NEW_RESOURCE_APP_ID'"
          verify_failures=$((verify_failures + 1))
        elif [[ "$delegated_scp" != "$NEW_RESOURCE_SCOPE_VALUE" ]]; then
          log ERROR "FAIL: Delegated token scp '$delegated_scp' did not match '$NEW_RESOURCE_SCOPE_VALUE'"
          verify_failures=$((verify_failures + 1))
        elif [[ "$delegated_azp" != "$AZURE_CLI_APP_ID" ]]; then
          log ERROR "FAIL: Delegated token azp '$delegated_azp' did not match Microsoft Azure CLI appId '$AZURE_CLI_APP_ID'"
          verify_failures=$((verify_failures + 1))
        else
          delegated_proof_ran=1
          log_success "Verified Azure CLI delegated token aud=$delegated_aud azp=$delegated_azp scp=$delegated_scp"
          if (( azure_cli_delegated_grant_count == 0 )); then
            log_success "Verified Azure CLI delegated access by token proof without an oauth2PermissionGrant row; target resource likely uses pre-authorized-client consent"
          fi
        fi
      fi
    fi
  else
    log INFO "Skipping Azure CLI delegated-token diagnostic because --client-id verifies the selected customer app, not Microsoft Azure CLI."
  fi

  log INFO "Verify status"
  if old_resource_service_principal_is_refreshed "$dffa_customer_sp_json" && new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json"; then
    log INFO "  ✅ Audience migration — new resource (bd0c) owns $NEW_RESOURCE_IDENTIFIER_URI"
  else
    log ERROR "  ⚠️ Audience migration — old/new resource servicePrincipalNames are not in the expected migrated state"
  fi

  if [[ "$selected_client_verify" -eq 0 ]]; then
    if [[ "$delegated_proof_ran" -eq 1 ]]; then
      log INFO "  ✅ Azure CLI delegated token — diagnostic passed"
    else
      log WARN "  ⏳ Azure CLI delegated token — action needed; see the earlier FAIL/remedy lines"
    fi
    log INFO "  ℹ️ Selected-client app-only proof — skipped because --client-id was not provided"
    log INFO "  ℹ️ App-specific token proof — run verify --client-id <client-app-id-or-service-principal-id> for each customer app shown by inventory"
    log INFO "  ℹ️ ADME endpoint — not tested; run ./test.sh <adme-instance-host> \"$NEW_RESOURCE_IDENTIFIER_URI/.default\""
    if (( verify_failures > 0 )); then
      log ERROR "  ⚠️ Verification failed — $verify_failures failing check(s)"
      log ERROR "SUMMARY: verify found $verify_failures failing check(s)"
      die "verify detected broken migration state"
    fi
    log INFO "SUMMARY: verify complete — tenant audience migration is healthy and Azure CLI delegated diagnostic passed"
    return 0
  fi

  log INFO "  ℹ️ Selected client configuration — not checked by verify; run adme-entra-inventory.sh for API permissions and admin consent status"
  if [[ "$app_only_proof_ran" -eq 1 ]]; then
    log INFO "  ✅ App-only token proof — passed"
  elif [[ "$app_only_proof_attempted" -eq 1 ]]; then
    log WARN "  ⏳ App-only token proof — action needed; see the earlier FAIL/remedy lines"
  elif ! target_resource_requires_app_role_assignment; then
    log INFO "  ℹ️ App-only token proof — not applicable because the target resource has no enabled app roles"
  else
    log WARN "  ⏳ App-only token proof — skipped; export CLIENT_SECRET=<CLIENT_SECRET> to run it"
  fi
  log INFO "  ℹ️ Azure CLI delegated token — skipped because --client-id verifies the selected customer app; run verify without --client-id for Azure CLI delegated proof"
  log INFO "  ℹ️ ADME endpoint — not tested; run ./test.sh <adme-instance-host> \"$NEW_RESOURCE_IDENTIFIER_URI/.default\""

  if (( verify_failures > 0 )); then
    log ERROR "  ⚠️ Verification failed — $verify_failures failing check(s)"
    log ERROR "SUMMARY: verify found $verify_failures failing check(s)"
    die "verify detected broken migration state"
  fi

  if [[ "$app_only_proof_ran" -eq 1 ]]; then
    log INFO "SUMMARY: verify complete — selected-client app-only token proof passed"
  elif ! target_resource_requires_app_role_assignment; then
    log INFO "SUMMARY: verify complete — selected-client app-only token proof is not applicable for this delegated-only target resource"
  else
    log WARN "SUMMARY: verify completed without selected-client app-only token proof"
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

assert_old_resource_target_set_case() {
  local label="$1"
  local input_sp_names_json="$2"
  local expected_sp_names_json="$3"
  local expect_noop="${4:-0}"
  local actual_sp_names_json

  actual_sp_names_json="$(build_old_resource_target_service_principal_names_json "$input_sp_names_json")"
  service_principal_names_json_matches_target "$actual_sp_names_json" "$expected_sp_names_json" \
    || die "$label target set mismatch. Expected $expected_sp_names_json, got $actual_sp_names_json"
  service_principal_names_json_has_no_duplicates "$actual_sp_names_json" \
    || die "$label target set contains duplicates: $actual_sp_names_json"

  if [[ "$expect_noop" -eq 1 ]]; then
    service_principal_names_json_matches_target "$input_sp_names_json" "$actual_sp_names_json" \
      || die "$label should have been recognized as a no-op. Input $input_sp_names_json, target $actual_sp_names_json"
  fi

  log_success "$label target set validated: $actual_sp_names_json"
}

run_self_test_target_set() {
  local app_id api_uri custom_uri
  local partial_input zero_input already_correct_input extra_input
  local partial_expected zero_expected already_correct_expected extra_expected

  require_command jq
  app_id="$OLD_RESOURCE_APP_ID"
  api_uri="api://$NEW_RESOURCE_APP_ID"
  custom_uri="https://example.contoso.invalid/custom-resource"

  partial_input="$(jq -cn --arg appId "$app_id" --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '[$appId, $old, $shared]')"
  partial_expected="$(jq -cn --arg appId "$app_id" --arg old "$OLD_RESOURCE_IDENTIFIER_URI" '[$appId, $old]')"
  zero_input="$(jq -cn --arg appId "$app_id" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '[$appId, $shared]')"
  zero_expected="$partial_expected"
  already_correct_input="$partial_expected"
  already_correct_expected="$partial_expected"
  extra_input="$(jq -cn --arg appId "$app_id" --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg api "$api_uri" --arg custom "$custom_uri" --arg shared "$NEW_RESOURCE_IDENTIFIER_URI" '[$appId, $old, $api, $custom, $shared, $api, $old]')"
  extra_expected="$(jq -cn --arg appId "$app_id" --arg old "$OLD_RESOURCE_IDENTIFIER_URI" --arg api "$api_uri" --arg custom "$custom_uri" '[$appId, $old, $api, $custom]')"

  log_step "Running local direct servicePrincipalNames repair target-set self-test"
  assert_old_resource_target_set_case "partial-refresh" "$partial_input" "$partial_expected"
  assert_old_resource_target_set_case "zero-refresh" "$zero_input" "$zero_expected"
  assert_old_resource_target_set_case "already-correct" "$already_correct_input" "$already_correct_expected" 1
  assert_old_resource_target_set_case "extra-non-shared" "$extra_input" "$extra_expected"
  log INFO "SUMMARY: self-test-target-set complete"
}

run_migrate_tenant_admin() {
  local dffa_customer_sp_json original_tags probe_tag patched_tags
  local refresh_attempt refreshed_dffa_sp_json refreshed_dffa_sp_names refresh_succeeded
  local probe_start_dffa_sp_json probe_start_dffa_sp_names internal_force_tier2_fallback
  local bd0c_customer_sp_id bd0c_customer_sp_json bd0c_customer_sp_names azure_cli_customer_sp_id
  local recreated_dffa_sp_json recreated_dffa_sp_names
  local direct_repair_target_dffa_sp_names direct_repair_patch_error home_dffa_sp_names home_bd0c_sp_names

  log_step "Loading runtime state and validating adme-audience prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant_admin_role

  internal_force_tier2_fallback=0
  if internal_force_tier2_fallback_enabled; then
    assert_internal_tier2_fallback_fixture
    internal_force_tier2_fallback=1
    log_warn "INTERNAL SIMULATION MODE: forcing migrate adme-audience past the probe-tag refresh path to exercise direct servicePrincipalNames repair."
  fi

  dffa_customer_sp_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
  probe_start_dffa_sp_json="$dffa_customer_sp_json"
  probe_start_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$probe_start_dffa_sp_json")"
  if [[ "$internal_force_tier2_fallback" -eq 1 ]]; then
    old_resource_service_principal_is_refreshed "$probe_start_dffa_sp_json" \
      && die "Internal direct-repair fallback fixture expected stale old resource (dffa) servicePrincipalNames before the probe-tag refresh, but the customer service principal is already refreshed: $probe_start_dffa_sp_names"
  fi
  original_tags="$(jq -c '.tags // []' <<<"$dffa_customer_sp_json")"

  log INFO "Preflight:"
  log INFO "  customer tenant: $CUSTOMER_TENANT_ID"
  log INFO "  old resource (dffa) customer servicePrincipalId: $OLD_RESOURCE_SERVICE_PRINCIPAL_ID"
  log INFO "  expected refreshed old resource (dffa) identifierUri: $OLD_RESOURCE_IDENTIFIER_URI"
  log INFO "  new resource (bd0c) appId to provision in customer tenant: $NEW_RESOURCE_APP_ID"
  log INFO "  expected new resource (bd0c) identifierUri: $NEW_RESOURCE_IDENTIFIER_URI"
  if [[ "$ALLOW_RECREATE_DFFA" -eq 1 ]]; then
    log INFO "  fallback mode: --allow-recreate-dffa enabled"
  else
    log INFO "  fallback mode: default safe stop if refresh remains stale"
  fi
  confirm_if_needed "adme-audience migration"

  probe_tag="$(make_refresh_probe_tag)"
  patched_tags="$(jq -cn --argjson tags "$original_tags" --arg probeTag "$probe_tag" '$tags + [$probeTag] | unique')"

  log_step "Applying a temporary refresh probe tag to the stale old resource (dffa) customer service principal"
  patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$patched_tags"
  log_success "Applied refresh probe tag $probe_tag"
  trap 'patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$original_tags" >/dev/null 2>&1' EXIT

  log_step "Polling for the refreshed old resource (dffa) servicePrincipalNames"
  refresh_succeeded=0
  for refresh_attempt in 1 2 3; do
    refreshed_dffa_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
    refreshed_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$refreshed_dffa_sp_json")"
    if old_resource_service_principal_is_refreshed "$refreshed_dffa_sp_json"; then
      if [[ "$internal_force_tier2_fallback" -eq 1 ]]; then
        log_warn "INTERNAL SIMULATION MODE: probe-tag refresh reached target state on attempt $refresh_attempt; treating it as stale to exercise direct servicePrincipalNames repair."
        refreshed_dffa_sp_json="$probe_start_dffa_sp_json"
        refreshed_dffa_sp_names="$probe_start_dffa_sp_names"
        break
      fi
      log_success "old resource (dffa) customer servicePrincipalNames refreshed on attempt $refresh_attempt: $refreshed_dffa_sp_names"
      refresh_succeeded=1
      break
    fi

    log INFO "old resource (dffa) customer servicePrincipalNames not refreshed on attempt $refresh_attempt/3 yet: $refreshed_dffa_sp_names"
    sleep 5
  done

  log_step "Removing the temporary refresh probe tag"
  patch_service_principal_tags "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$original_tags"
  trap - EXIT
  log_success "Removed refresh probe tag $probe_tag"

  if [[ "$refresh_succeeded" -ne 1 ]]; then
    if [[ "$internal_force_tier2_fallback" -eq 1 ]]; then
      refreshed_dffa_sp_json="$probe_start_dffa_sp_json"
      refreshed_dffa_sp_names="$probe_start_dffa_sp_names"
      log_warn "INTERNAL SIMULATION MODE: old resource (dffa) customer servicePrincipalNames intentionally treated as stale after the probe-tag refresh path: $refreshed_dffa_sp_names"
    else
      log_warn "old resource (dffa) customer servicePrincipalNames remained stale after 3 refresh attempts: $refreshed_dffa_sp_names"
    fi
    direct_repair_target_dffa_sp_names="$(build_old_resource_target_service_principal_names_json "$refreshed_dffa_sp_names")"
    if home_dffa_sp_names="$(home_application_service_principal_names_json "old resource (dffa)" "$OLD_RESOURCE_APP_ID")"; then
      log INFO "Home old resource (dffa) application canonical servicePrincipalNames: $home_dffa_sp_names"
      if ! old_resource_service_principal_names_are_refreshed "$home_dffa_sp_names"; then
        die "Home old resource (dffa) application metadata does not advertise the expected migrated state. Expected it to include $OLD_RESOURCE_IDENTIFIER_URI and not include $NEW_RESOURCE_IDENTIFIER_URI. Direct repair and delete/recreate cannot fix the customer tenant until the home-tenant application metadata is updated."
      fi
      direct_repair_target_dffa_sp_names="$home_dffa_sp_names"
    fi
    log INFO "Direct repair current old resource (dffa) servicePrincipalNames: $refreshed_dffa_sp_names"
    log INFO "Direct repair target old resource (dffa) servicePrincipalNames: $direct_repair_target_dffa_sp_names"

    if service_principal_names_json_matches_target "$refreshed_dffa_sp_names" "$direct_repair_target_dffa_sp_names"; then
      refresh_succeeded=1
      log_success "Direct repair skipped PATCH because old resource (dffa) servicePrincipalNames already match the target set"
    else
      log_step "Trying direct servicePrincipalNames repair on the stale old resource (dffa) customer service principal"
      if ! direct_repair_patch_error="$(patch_service_principal_names "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$direct_repair_target_dffa_sp_names")"; then
        log_warn "Direct servicePrincipalNames repair failed: $(format_service_principal_names_patch_error "$direct_repair_patch_error")"
      else
        refreshed_dffa_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
        refreshed_dffa_sp_names="$(service_principal_names_json "$refreshed_dffa_sp_json")"
        if service_principal_names_json_matches_target "$refreshed_dffa_sp_names" "$direct_repair_target_dffa_sp_names"; then
          refresh_succeeded=1
          log_success "Direct repair updated old resource (dffa) servicePrincipalNames to target set: $refreshed_dffa_sp_names"
        else
          log_warn "Direct repair verification failed; old resource (dffa) servicePrincipalNames remain off-target: $refreshed_dffa_sp_names"
        fi
      fi
    fi

    if [[ "$refresh_succeeded" -ne 1 && "$ALLOW_RECREATE_DFFA" -ne 1 ]]; then
      die "old resource (dffa) customer servicePrincipalNames remained stale after the probe-tag refresh and direct servicePrincipalNames repair. Default mode stops before delete/recreate and before provisioning new resource (bd0c). Review output-logging/ and rerun with: ./adme-entra-migration.sh --yes migrate adme-audience --allow-recreate-dffa"
    fi

    if [[ "$refresh_succeeded" -ne 1 ]]; then
      old_resource_service_principal_is_refreshed "$refreshed_dffa_sp_json" \
        && die "Refusing delete/recreate because the old resource (dffa) servicePrincipalNames already match the target state."

      log_step "Preparing the bounded delete/recreate fallback for the stale old resource (dffa) service principal"
      log INFO "Before recreate old resource (dffa) servicePrincipalNames: $refreshed_dffa_sp_names"
      confirm_destructive_if_needed "deleting and recreating the stale old resource (dffa) customer service principal"

      delete_service_principal "customer old resource (dffa)" "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID"
      OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(ensure_service_principal "customer old resource (dffa)" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$OLD_RESOURCE_APP_ID")"
      OLD_RESOURCE_SERVICE_PRINCIPAL_ID="$(wait_for_service_principal "customer old resource (dffa)" "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_APP_ID")"
      recreated_dffa_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$OLD_RESOURCE_SERVICE_PRINCIPAL_ID")"
      recreated_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$recreated_dffa_sp_json")"
      log INFO "After recreate old resource (dffa) servicePrincipalNames: $recreated_dffa_sp_names"
      old_resource_service_principal_is_refreshed "$recreated_dffa_sp_json" \
        || die "Recreated old resource (dffa) servicePrincipalNames still include $NEW_RESOURCE_IDENTIFIER_URI; stop and review the home-tenant application metadata before retrying."
      log_success "Verified recreated old resource (dffa) servicePrincipalNames: $recreated_dffa_sp_names"
      refreshed_dffa_sp_json="$recreated_dffa_sp_json"
      refreshed_dffa_sp_names="$recreated_dffa_sp_names"
      refresh_succeeded=1
    fi
  fi

  log_step "Ensuring new resource (bd0c) exists in the customer tenant"
  bd0c_customer_sp_id="$(ensure_service_principal "customer new resource (bd0c)" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$NEW_RESOURCE_APP_ID")"
  bd0c_customer_sp_id="$(wait_for_service_principal "customer new resource (bd0c)" "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"

  bd0c_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$bd0c_customer_sp_id")"
  bd0c_customer_sp_names="$(service_principal_names_json "$bd0c_customer_sp_json")"
  if ! new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json"; then
    if home_bd0c_sp_names="$(home_application_service_principal_names_json "new resource (bd0c)" "$NEW_RESOURCE_APP_ID")"; then
      log INFO "Home new resource (bd0c) application canonical servicePrincipalNames: $home_bd0c_sp_names"
      service_principal_names_json_owns_shared_audience "$home_bd0c_sp_names" \
        || die "Home new resource (bd0c) application metadata does not advertise $NEW_RESOURCE_IDENTIFIER_URI. Update the home-tenant application metadata before retrying."

      log_step "Updating customer new resource (bd0c) servicePrincipalNames from home-tenant application metadata"
      if ! direct_repair_patch_error="$(patch_service_principal_names "$CUSTOMER_CONFIG_DIR" "$bd0c_customer_sp_id" "$home_bd0c_sp_names")"; then
        die "customer new resource (bd0c) servicePrincipalNames do not include $NEW_RESOURCE_IDENTIFIER_URI, and direct repair from home-tenant application metadata failed: $(format_service_principal_names_patch_error "$direct_repair_patch_error")"
      fi
      bd0c_customer_sp_json="$(service_principal_json_by_id "$CUSTOMER_CONFIG_DIR" "$bd0c_customer_sp_id")"
      bd0c_customer_sp_names="$(service_principal_names_json "$bd0c_customer_sp_json")"
    fi
  fi
  new_resource_service_principal_owns_shared_audience "$bd0c_customer_sp_json" || die "customer new resource (bd0c) servicePrincipalNames do not include $NEW_RESOURCE_IDENTIFIER_URI"
  log_success "Verified customer new resource (bd0c) servicePrincipalNames: $bd0c_customer_sp_names"

  log_step "Ensuring Azure CLI can request the new resource (bd0c) delegated scope non-interactively"
  azure_cli_customer_sp_id="$(ensure_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$AZURE_CLI_APP_ID")"
  azure_cli_customer_sp_id="$(wait_for_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"
  ensure_oauth2_permission_grant \
    "customer Microsoft Azure CLI delegated new resource (bd0c) grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$azure_cli_customer_sp_id" \
    "$bd0c_customer_sp_id" \
    "$NEW_RESOURCE_SCOPE_VALUE"

  log INFO "SUMMARY: migrate adme-audience complete"
  log INFO "  old resource (dffa) customer servicePrincipalId=$OLD_RESOURCE_SERVICE_PRINCIPAL_ID now advertises $OLD_RESOURCE_IDENTIFIER_URI"
  log INFO "  new resource (bd0c) customer servicePrincipalId=$bd0c_customer_sp_id now advertises $NEW_RESOURCE_IDENTIFIER_URI"
}

run_migrate_app_owner() {
  local bd0c_customer_sp_id bd0c_customer_sp_json matching_assignment_id assignment_count admin_consent_url
  local client_delegated_grant_count

  log_step "Loading runtime state and validating api-permissions prerequisites"
  require_command az
  load_runtime_state
  require_command jq
  require_command base64
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant_admin_role
  resolve_selected_client "$CLIENT_ID_ARG" "migrate api-permissions"

  bd0c_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"
  [[ -n "$bd0c_customer_sp_id" ]] || die "Customer new resource (bd0c) service principal not found. Run 'migrate adme-audience' first."
  bd0c_customer_sp_json="$(target_resource_service_principal_json "$bd0c_customer_sp_id")"
  validate_target_resource_permissions_contract "$bd0c_customer_sp_id"

  admin_consent_portal_url="$(customer_app_admin_consent_portal_url)"

  log INFO "Preflight:"
  log INFO "  customer tenant: $CUSTOMER_TENANT_ID"
  log INFO "  client app appId: $CLIENT_APP_ID"
  log INFO "  new resource (bd0c) appId: $NEW_RESOURCE_APP_ID"
  log INFO "  new resource (bd0c) servicePrincipalId: $bd0c_customer_sp_id"
  if target_resource_requires_app_role_assignment; then
    log INFO "  app role to grant: $NEW_RESOURCE_APP_ROLE_VALUE ($NEW_RESOURCE_APP_ROLE_ID)"
  else
    log INFO "  app role to grant: not applicable (target resource exposes no enabled app roles)"
  fi
  log INFO "  delegated scope to preserve in requiredResourceAccess: $NEW_RESOURCE_SCOPE_VALUE ($NEW_RESOURCE_SCOPE_ID)"
  log INFO "  requiredResourceAccess target shape: $(target_resource_permission_shape_label | tr -d '\n')"
  if [[ "$AUTO_GRANT" -eq 1 ]]; then
    log INFO "  customer-app consent mode: --auto-grant"
  else
    log INFO "  customer-app consent mode: default manual admin-consent action"
    log_customer_app_admin_consent_guidance INFO "$admin_consent_portal_url"
  fi
  confirm_if_needed "api-permissions migration"

  log_step "Validating the requiredResourceAccess PATCH contract against client app"
  patch_required_resource_access_to_new_resource

  log INFO "Old resource (dffa) grants are left in place intentionally if they exist; they are now stale informational artifacts."
  log INFO "SUMMARY: migrate api-permissions complete"
  log INFO "  client app requiredResourceAccess now references new resource (bd0c)"

  if [[ "$AUTO_GRANT" -eq 1 ]]; then
    if target_resource_requires_app_role_assignment; then
      log_step "Ensuring the new resource (bd0c) app role assignment exists for client app"
      ensure_app_role_assignment "$bd0c_customer_sp_id"
      matching_assignment_id="$(wait_for_app_role_assignment "$bd0c_customer_sp_id")"
      assignment_count="$(count_matching_app_role_assignments "$bd0c_customer_sp_id")"
      [[ "$assignment_count" == "1" ]] || die "Expected exactly one matching new resource (bd0c) app role assignment for client app, found $assignment_count"
    else
      matching_assignment_id=""
      assignment_count="0"
      log INFO "Skipping app-role grant creation because the target resource exposes no enabled app roles"
    fi

    log_step "Ensuring the new resource (bd0c) delegated grant exists for client app"
    ensure_oauth2_permission_grant \
      "client app delegated new resource (bd0c) grant" \
      "$CUSTOMER_CONFIG_DIR" \
      "$CLIENT_SERVICE_PRINCIPAL_ID" \
      "$bd0c_customer_sp_id" \
      "$NEW_RESOURCE_SCOPE_VALUE"
    client_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"
    (( client_delegated_grant_count >= 1 )) || die "Expected the client app delegated grant for new resource (bd0c) scope '$NEW_RESOURCE_SCOPE_VALUE' to exist after --auto-grant"

    log_success "Verified client app delegated grant wiring for new resource (bd0c) scope '$NEW_RESOURCE_SCOPE_VALUE'"
    log INFO "  customer app grants were created programmatically (--auto-grant)"
    if target_resource_requires_app_role_assignment; then
      log INFO "  new resource (bd0c) app role assignment id=$matching_assignment_id"
    else
      log INFO "  new resource (bd0c) app role assignment: not applicable"
    fi
  else
    if target_resource_requires_app_role_assignment; then
      matching_assignment_id="$(find_matching_app_role_assignment_id "$bd0c_customer_sp_id")"
      assignment_count="$(count_matching_app_role_assignments "$bd0c_customer_sp_id")"
    else
      matching_assignment_id=""
      assignment_count="0"
    fi
    client_delegated_grant_count="$(count_matching_oauth2_permission_grants "$CUSTOMER_CONFIG_DIR" "$CLIENT_SERVICE_PRINCIPAL_ID" "$bd0c_customer_sp_id" "$NEW_RESOURCE_SCOPE_VALUE")"

    log INFO "  customer app grants were not modified on the default path"
    if target_resource_requires_app_role_assignment; then
      log INFO "  existing customer-app grant state (informational): appRoleAssignments=$assignment_count delegatedGrants=$client_delegated_grant_count"
    else
      log INFO "  existing customer-app grant state (informational): appRoleAssignments=not-applicable delegatedGrants=$client_delegated_grant_count"
    fi
    if [[ -n "$matching_assignment_id" ]]; then
      log INFO "  existing new resource (bd0c) app role assignment id=$matching_assignment_id"
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
    self-test-target-set)
      COMMAND="self-test-target-set"
      SUBCOMMAND=""
      shift
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
          --client-id)
            CLIENT_ID_ARG="${2:?Missing value for --client-id}"
            shift 2
            ;;
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
      [[ -n "$CLIENT_ID_ARG" ]] || die "--client-id is required for 'migrate api-permissions'"
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
    self-test-target-set/)
      [[ $# -eq 0 ]] || die "Unexpected argument for '$COMMAND ${SUBCOMMAND:-}': $1"
      ;;
    verify/)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --client-id)
            CLIENT_ID_ARG="${2:?Missing value for --client-id}"
            shift 2
            ;;
          --client-secret)
            CLIENT_SECRET="${2:?Missing value for --client-secret}"
            CLIENT_SECRET_OVERRIDDEN=1
            shift 2
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
  self-test-target-set/)
    run_self_test_target_set
    ;;
  verify/)
    run_verify
    ;;
  *)
    usage
    die "Unsupported command: $COMMAND ${SUBCOMMAND:-}"
    ;;
esac
