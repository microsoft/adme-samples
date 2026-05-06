#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

SCOPE="all"
LABEL=""
STATE_DIR=""

OLD_RESOURCE_APP_ID="dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e"
NEW_RESOURCE_APP_ID="bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc"
GRAPH_BASE_URL="https://graph.microsoft.com/v1.0"
SHARED_AUDIENCE_URI="https://energy.azure.com"
OUTPUT_DIR="./inventory-output"
STATE_OUTPUT_DIR="./inventory-state"
LOG_OUTPUT_DIR="./inventory-logs"
AZURE_CLI_APP_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"

LAST_DFFA_PATH=""
LAST_BD0C_PATH=""
LAST_SUMMARY_PATH=""
LAST_DFFA_HAS_SHARED_AUDIENCE=false
LAST_BD0C_HAS_SHARED_AUDIENCE=false
LAST_3P_INVENTORY_PATH=""

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(timestamp)" "$level" "$*" >&2
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

append_query_parameter() {
  local url="$1"
  local parameter="$2"

  if [[ "$url" == *\?* ]]; then
    printf '%s&%s\n' "$url" "$parameter"
  else
    printf '%s?%s\n' "$url" "$parameter"
  fi
}

ensure_top_query_parameter() {
  local url="$1"

  if [[ "$url" == *'$top='* || "$url" == *'%24top='* ]]; then
    printf '%s\n' "$url"
  else
    append_query_parameter "$url" '$top=999'
  fi
}

extract_retry_after_seconds() {
  local error_text="$1"
  local retry_after

  retry_after="$(
    printf '%s\n' "$error_text" \
      | sed -nE 's/.*[Rr]etry-[Aa]fter: *([0-9]+).*/\1/p' \
      | tail -n 1
  )"

  [[ -n "$retry_after" ]] || return 1
  printf '%s\n' "$retry_after"
}

is_http_429_error() {
  local error_text="$1"

  grep -qiE '(^|[^0-9])429([^0-9]|$)|too many requests' <<<"$error_text"
}

graph_request_json_all_pages() {
  local config_dir="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"
  local next_url page_json merged_json stdout_file stderr_file stderr_text retry_after
  local retry_attempt

  [[ "$method" == "GET" ]] || die "graph_request_json_all_pages currently supports GET requests only"
  [[ -z "$body" ]] || die "graph_request_json_all_pages does not accept a request body"

  next_url="$(ensure_top_query_parameter "$url")"
  merged_json='{"value":[]}'

  while [[ -n "$next_url" ]]; do
    retry_attempt=0

    while :; do
      stdout_file="$(mktemp)"
      stderr_file="$(mktemp)"

      if run_az "$config_dir" rest --method "$method" --url "$next_url" -o json >"$stdout_file" 2>"$stderr_file"; then
        page_json="$(cat "$stdout_file")"
        rm -f "$stdout_file" "$stderr_file"
        break
      fi

      stderr_text="$(cat "$stderr_file")"
      rm -f "$stdout_file" "$stderr_file"

      if is_http_429_error "$stderr_text"; then
        retry_attempt=$((retry_attempt + 1))
        retry_after="$(extract_retry_after_seconds "$stderr_text" || true)"
        [[ -n "$retry_after" ]] || retry_after=5

        if (( retry_attempt > 5 )); then
          printf '%s\n' "$stderr_text" >&2
          die "Graph request remained throttled after 5 retries: $next_url"
        fi

        log_warn "Graph request throttled (HTTP 429); retrying in ${retry_after}s (attempt ${retry_attempt}/5)"
        sleep "$retry_after"
        continue
      fi

      printf '%s\n' "$stderr_text" >&2
      return 1
    done

    jq -e '.value? | type == "array"' <<<"$page_json" >/dev/null \
      || die "Graph paged response did not include a value[] array"

    merged_json="$(
      jq -c --argjson page "$page_json" '
        .value += ($page.value // [])
      ' <<<"$merged_json"
    )"

    next_url="$(jq -r '."@odata.nextLink" // empty' <<<"$page_json")"
  done

  printf '%s\n' "$merged_json"
}

graph_request_json_all_pages_until_empty_continuation_limit() {
  local config_dir="$1"
  local method="$2"
  local url="$3"
  local label="$4"
  local empty_page_limit="$5"
  local output_file="$6"
  local body="${7:-}"
  local next_url page_json merged_json stdout_file stderr_file stderr_text retry_after
  local retry_attempt page_value_count empty_page_count page_number
  local fallback_triggered=false

  [[ "$method" == "GET" ]] || die "graph_request_json_all_pages_until_empty_continuation_limit currently supports GET requests only"
  [[ -z "$body" ]] || die "graph_request_json_all_pages_until_empty_continuation_limit does not accept a request body"

  next_url="$(ensure_top_query_parameter "$url")"
  merged_json='{"value":[]}'
  empty_page_count=0
  page_number=0

  while [[ -n "$next_url" ]]; do
    retry_attempt=0
    page_number=$((page_number + 1))

    while :; do
      stdout_file="$(mktemp)"
      stderr_file="$(mktemp)"

      if run_az "$config_dir" rest --method "$method" --url "$next_url" -o json >"$stdout_file" 2>"$stderr_file"; then
        page_json="$(cat "$stdout_file")"
        rm -f "$stdout_file" "$stderr_file"
        break
      fi

      stderr_text="$(cat "$stderr_file")"
      rm -f "$stdout_file" "$stderr_file"

      if is_http_429_error "$stderr_text"; then
        retry_attempt=$((retry_attempt + 1))
        retry_after="$(extract_retry_after_seconds "$stderr_text" || true)"
        [[ -n "$retry_after" ]] || retry_after=5

        if (( retry_attempt > 5 )); then
          printf '%s\n' "$stderr_text" >&2
          die "Graph request remained throttled after 5 retries: $next_url"
        fi

        log_warn "Graph request throttled (HTTP 429); retrying in ${retry_after}s (attempt ${retry_attempt}/5)"
        sleep "$retry_after"
        continue
      fi

      printf '%s\n' "$stderr_text" >&2
      return 1
    done

    jq -e '.value? | type == "array"' <<<"$page_json" >/dev/null \
      || die "Graph paged response did not include a value[] array"

    page_value_count="$(jq -r '.value | length' <<<"$page_json")"
    merged_json="$(
      jq -c --argjson page "$page_json" '
        .value += ($page.value // [])
      ' <<<"$merged_json"
    )"

    next_url="$(jq -r '."@odata.nextLink" // empty' <<<"$page_json")"
    if (( page_value_count == 0 )) && [[ -n "$next_url" ]]; then
      empty_page_count=$((empty_page_count + 1))
      log_warn "$label returned empty page $page_number with @odata.nextLink (${empty_page_count}/${empty_page_limit})"
      if (( empty_page_count >= empty_page_limit )); then
        fallback_triggered=true
        break
      fi
    else
      empty_page_count=0
    fi
  done

  printf '%s\n' "$merged_json" >"$output_file"
  GRAPH_PAGED_QUERY_PAGES_SCANNED="$page_number"
  GRAPH_PAGED_QUERY_EMPTY_PAGE_STREAK="$empty_page_count"
  GRAPH_PAGED_QUERY_FALLBACK_TRIGGERED="$fallback_triggered"
}

inventory_delegated_grants_json() {
  local config_dir="$1"
  local resource_sp_id="$2"
  local grants_file grants_json

  grants_file="$(mktemp)"
  graph_request_json_all_pages_until_empty_continuation_limit \
    "$config_dir" \
    GET \
    "$GRAPH_BASE_URL/oauth2PermissionGrants?\$filter=resourceId eq '$resource_sp_id'" \
    "oauth2PermissionGrants filtered by resourceId=$resource_sp_id" \
    5 \
    "$grants_file"
  grants_json="$(cat "$grants_file")"
  rm -f "$grants_file"

  jq -c -n \
    --argjson grants "$grants_json" \
    --argjson pagesScanned "${GRAPH_PAGED_QUERY_PAGES_SCANNED:-0}" \
    --argjson emptyPageStreak "${GRAPH_PAGED_QUERY_EMPTY_PAGE_STREAK:-0}" \
    --arg fallbackTriggered "${GRAPH_PAGED_QUERY_FALLBACK_TRIGGERED:-false}" '
      {
        value: ($grants.value // []),
        discovery: {
          mode: "resource",
          pagesScanned: $pagesScanned,
          emptyPageStreak: $emptyPageStreak,
          fallbackTriggered: ($fallbackTriggered == "true")
        },
        warnings: []
      }
    '
}

is_known_inventory_excluded_app_id() {
  local app_id="$1"

  [[ "$app_id" == "$AZURE_CLI_APP_ID" || "$app_id" == "$OLD_RESOURCE_APP_ID" || "$app_id" == "$NEW_RESOURCE_APP_ID" ]]
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [--scope all|adme-1p-service-principals|adme-1p-sps|dffa-clients] [--label value]

Description:
  Read-only inventory preflight for ADME Entra migration.
  Defaults to the current Azure CLI tenant context.

Options:
  --scope value    Inventory scope. Defaults to: all
                   all                         Full inventory preflight
                   adme-1p-service-principals  Only dffa/bd0c service principal preflight
                   adme-1p-sps                 Alias for adme-1p-service-principals
                   dffa-clients                3P app discovery preflight
  --label value    Optional label reserved for later output filenames.
  -h, --help       Show this help text.

Prerequisites:
  Required tools: az, jq
  Required tenant access for full inventory: Microsoft Graph read access that covers
  service principals and oauth2PermissionGrants.
  Least-privilege interactive role: Directory Readers.
  Least-privilege app permissions for full discovery: Application.Read.All + Directory.Read.All.
EOF
}

normalize_scope() {
  case "$1" in
    all) printf 'all\n' ;;
    adme-1p-service-principals|adme-1p-sps) printf 'adme-1p-service-principals\n' ;;
    dffa-clients) printf 'dffa-clients\n' ;;
    *)
      die "Invalid --scope '$1'; valid scopes: all, adme-1p-service-principals, adme-1p-sps, dffa-clients"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)
        [[ $# -ge 2 ]] || die "--scope requires a value"
        SCOPE="$(normalize_scope "$2")"
        shift 2
        ;;
      --label)
        [[ $# -ge 2 ]] || die "--label requires a value"
        LABEL="$2"
        shift 2
        ;;
      --state-dir)
        [[ $# -ge 2 ]] || die "--state-dir requires a value"
        STATE_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

load_runtime_overrides() {
  local state_env_file

  [[ -n "$STATE_DIR" ]] || return 0
  state_env_file="$STATE_DIR/sim-state.env"
  [[ -f "$state_env_file" ]] || die "Runtime state file not found: $state_env_file"
  # shellcheck disable=SC1090
  source "$state_env_file"
  if [[ -n "${NEW_RESOURCE_IDENTIFIER_URI:-}" ]]; then
    SHARED_AUDIENCE_URI="$NEW_RESOURCE_IDENTIFIER_URI"
  fi
}

current_config_dir() {
  if [[ -n "${AZURE_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$AZURE_CONFIG_DIR"
  elif [[ -n "${CUSTOMER_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$CUSTOMER_CONFIG_DIR"
  else
    printf '%s\n' ""
  fi
}

runtime_shared_audience_owner_override() {
  local state_json_file

  [[ -n "$STATE_DIR" ]] || return 1
  state_json_file="${STATE_JSON_FILE:-$STATE_DIR/sim-state.json}"
  [[ -f "$state_json_file" ]] || return 1

  jq -r --arg audience "$SHARED_AUDIENCE_URI" '
    if (.apps.simBd0c.identifierUri // "") == $audience then
      "bd0c"
    elif (.apps.simDffa.identifierUri // "") == $audience then
      "dffa"
    else
      "none"
    end
  ' "$state_json_file"
}

current_tenant_id() {
  local config_dir="$1"

  run_az "$config_dir" account show --query tenantId -o tsv
}

find_service_principal_id_by_app_id() {
  local config_dir="$1"
  local app_id="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$app_id'" \
    | jq -r '.value[0].id // empty'
}

filename_safe_timestamp() {
  local iso_timestamp="$1"

  printf '%s\n' "${iso_timestamp//[:-]/}"
}

capture_graph_request() {
  local config_dir="$1"
  local method="$2"
  local url="$3"
  local stdout_file stderr_file stderr_text

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  if graph_request_json "$config_dir" "$method" "$url" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file"
    rm -f "$stdout_file" "$stderr_file"
    return 0
  fi

  stderr_text="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g')"
  rm -f "$stdout_file" "$stderr_file"
  printf '%s\n' "$stderr_text" >&2
  return 1
}

probe_old_resource_service_principal() {
  local config_dir="$1"
  local tenant_id="$2"
  local sp_lookup_json

  if ! sp_lookup_json="$(
    capture_graph_request \
      "$config_dir" \
      GET \
      "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$OLD_RESOURCE_APP_ID'&\$select=id,appId,displayName"
  )"; then
    die "Unable to read the dffa service principal in tenant $tenant_id. Impact: cannot complete scope '$SCOPE'. Required access: least-privilege role 'Directory Readers'; app permissions Application.Read.All + Directory.Read.All for full discovery."
  fi

  jq -e '.value | type == "array"' <<<"$sp_lookup_json" >/dev/null \
    || die "Graph response for dffa service principal lookup did not include value[]"

  jq -r '.value[0].id // empty' <<<"$sp_lookup_json"
}

probe_oauth2_permission_grants() {
  local config_dir="$1"
  local tenant_id="$2"
  local resource_sp_id="$3"

  if ! capture_graph_request \
    "$config_dir" \
    GET \
    "$GRAPH_BASE_URL/oauth2PermissionGrants?\$filter=resourceId eq '$resource_sp_id'&\$top=1" \
    >/dev/null; then
    die "Unable to read oauth2PermissionGrants in tenant $tenant_id. Impact: cannot complete scope '$SCOPE' because delegated-grant discovery would be incomplete. Required access: least-privilege role 'Directory Readers'; app permissions Application.Read.All + Directory.Read.All for full discovery. Fallback: retry with --scope adme-1p-service-principals if you only need dffa/bd0c service principal status."
  fi
}

run_preflight() {
  local config_dir="${1:-}"
  local tenant_id old_resource_sp_id

  [[ -n "$config_dir" ]] || config_dir="$(current_config_dir)"

  log_step "Validating local prerequisites"
  require_command az
  require_command jq

  log_step "Validating current Azure CLI tenant context"
  tenant_id="$(current_tenant_id "$config_dir")" \
    || die "Unable to read the current Azure CLI tenant context. Run 'az account show' or 'az login' first."
  log_success "Using tenantId=$tenant_id"

  log_step "Checking Microsoft Graph access for scope '$SCOPE'"
  old_resource_sp_id="$(probe_old_resource_service_principal "$config_dir" "$tenant_id")"
  [[ -n "$old_resource_sp_id" ]] || die "The dffa service principal (appId $OLD_RESOURCE_APP_ID) was not found in tenant $tenant_id."

  if [[ "$SCOPE" == "all" || "$SCOPE" == "dffa-clients" ]]; then
    probe_oauth2_permission_grants "$config_dir" "$tenant_id" "$old_resource_sp_id"
  fi

  log_success "Preflight passed for scope '$SCOPE' in tenant $tenant_id"
  printf '%s\n' "$tenant_id"
}

ensure_output_dirs() {
  mkdir -p "$OUTPUT_DIR" "$STATE_OUTPUT_DIR" "$LOG_OUTPUT_DIR"
}

inventory_resource_service_principal_json() {
  local config_dir="$1"
  local tenant_id="$2"
  local app_id="$3"
  local generated_at="$4"
  local sp_lookup_json

  sp_lookup_json="$(
    graph_request_json \
      "$config_dir" \
      GET \
      "$GRAPH_BASE_URL/servicePrincipals?\$filter=appId eq '$app_id'&\$select=id,appId,displayName,servicePrincipalNames,appRoles,oauth2PermissionScopes"
  )"

  jq -c \
    --arg generatedAt "$generated_at" \
    --arg tenantId "$tenant_id" \
    --arg appId "$app_id" '
      if (.value | length) == 0 then
        {
          found: false,
          generatedAt: $generatedAt,
          tenantId: $tenantId,
          appId: $appId,
          servicePrincipalId: null,
          displayName: null,
          servicePrincipalNames: [],
          appRoles: [],
          oauth2PermissionScopes: []
        }
      else
        .value[0] as $sp
        | {
            found: true,
            generatedAt: $generatedAt,
            tenantId: $tenantId,
            appId: ($sp.appId // $appId),
            servicePrincipalId: ($sp.id // null),
            displayName: ($sp.displayName // null),
            servicePrincipalNames: ($sp.servicePrincipalNames // []),
            appRoles: ($sp.appRoles // []),
            oauth2PermissionScopes: ($sp.oauth2PermissionScopes // [])
          }
      end
    ' <<<"$sp_lookup_json"
}

artifact_filename() {
  local prefix="$1"
  local generated_at="$2"

  if [[ -n "$LABEL" ]]; then
    printf '%s/%s-%s-%s.json\n' "$OUTPUT_DIR" "$prefix" "$LABEL" "$(filename_safe_timestamp "$generated_at")"
  else
    printf '%s/%s-%s.json\n' "$OUTPUT_DIR" "$prefix" "$(filename_safe_timestamp "$generated_at")"
  fi
}

write_inventory_resource_service_principal_file() {
  local config_dir="$1"
  local tenant_id="$2"
  local app_id="$3"
  local generated_at="$4"
  local file_prefix="$5"
  local companion_path sp_json

  companion_path="$(artifact_filename "$file_prefix" "$generated_at")"
  sp_json="$(inventory_resource_service_principal_json "$config_dir" "$tenant_id" "$app_id" "$generated_at")"
  printf '%s\n' "$sp_json" >"$companion_path"
  printf '%s\n' "$companion_path"
}

service_principal_has_shared_audience() {
  local sp_json="$1"

  jq -e --arg audience "$SHARED_AUDIENCE_URI" '(.servicePrincipalNames // []) | index($audience) != null' <<<"$sp_json" >/dev/null
}

shared_audience_owner() {
  local dffa_has_shared_audience="$1"
  local bd0c_has_shared_audience="$2"

  if [[ "$bd0c_has_shared_audience" == "true" ]]; then
    printf 'bd0c\n'
  elif [[ "$dffa_has_shared_audience" == "true" ]]; then
    printf 'dffa\n'
  else
    printf 'none\n'
  fi
}

scaffold_migration_state() {
  local dffa_has_shared_audience="$1"
  local bd0c_has_shared_audience="$2"

  if [[ "$dffa_has_shared_audience" == "true" && "$bd0c_has_shared_audience" == "false" ]]; then
    printf 'pre-migration\n'
  else
    printf 'requires-3p-assessment\n'
  fi
}

write_summary_json() {
  local tenant_id="$1"
  local generated_at="$2"
  local dffa_has_shared_audience="$3"
  local bd0c_has_shared_audience="$4"
  local summary_path shared_owner migration_state existing_path="${5:-}"

  if [[ -n "$existing_path" ]]; then
    summary_path="$existing_path"
  else
    summary_path="$(artifact_filename "inventory-summary" "$generated_at")"
  fi
  shared_owner="$(shared_audience_owner "$dffa_has_shared_audience" "$bd0c_has_shared_audience")"
  migration_state="$(scaffold_migration_state "$dffa_has_shared_audience" "$bd0c_has_shared_audience")"

  jq -n -c \
    --arg migrationState "$migration_state" \
    --arg sharedAudienceOwner "$shared_owner" \
    --arg tenantId "$tenant_id" \
    --arg generatedAt "$generated_at" \
    --argjson dffaHasSharedAudience "$dffa_has_shared_audience" \
    --argjson bd0cHasSharedAudience "$bd0c_has_shared_audience" '
      {
        migrationState: $migrationState,
        sharedAudienceOwner: $sharedAudienceOwner,
        dffaHasSharedAudience: $dffaHasSharedAudience,
        bd0cHasSharedAudience: $bd0cHasSharedAudience,
        tenantId: $tenantId,
        generatedAt: $generatedAt
      }
    ' >"$summary_path"

  printf '%s\n' "$summary_path"
}

print_summary_stdout() {
  local tenant_id="$1"
  local summary_path="$2"
  local dffa_path="$3"
  local bd0c_path="$4"
  local three_p_path="${5:-}"
  local summary_json

  summary_json="$(cat "$summary_path")"

  printf 'Inventory summary\n'
  printf '  tenantId: %s\n' "$tenant_id"
  printf '  scope: %s\n' "$SCOPE"
  printf '  sharedAudienceOwner: %s\n' "$(jq -r '.sharedAudienceOwner' <<<"$summary_json")"
  printf '  migrationState: %s\n' "$(jq -r '.migrationState' <<<"$summary_json")"
  printf '  dffa companion: %s\n' "$dffa_path"
  printf '  bd0c companion: %s\n' "$bd0c_path"
  printf '  summary file: %s\n' "$summary_path"
  if [[ -n "$three_p_path" ]]; then
    printf '  3p inventory: %s\n' "$three_p_path"
  fi
}

run_inventory_scaffold() {
  local config_dir="$1"
  local tenant_id="$2"
  local generated_at dffa_path bd0c_path summary_path dffa_json bd0c_json
  local dffa_has_shared_audience bd0c_has_shared_audience runtime_shared_owner

  generated_at="$(timestamp)"
  ensure_output_dirs

  dffa_path="$(write_inventory_resource_service_principal_file "$config_dir" "$tenant_id" "$OLD_RESOURCE_APP_ID" "$generated_at" "dffa-sp")"
  bd0c_path="$(write_inventory_resource_service_principal_file "$config_dir" "$tenant_id" "$NEW_RESOURCE_APP_ID" "$generated_at" "bd0c-sp")"
  dffa_json="$(cat "$dffa_path")"
  bd0c_json="$(cat "$bd0c_path")"

  if service_principal_has_shared_audience "$dffa_json"; then
    dffa_has_shared_audience=true
  else
    dffa_has_shared_audience=false
  fi

  if service_principal_has_shared_audience "$bd0c_json"; then
    bd0c_has_shared_audience=true
  else
    bd0c_has_shared_audience=false
  fi

  runtime_shared_owner="$(runtime_shared_audience_owner_override || true)"
  case "$runtime_shared_owner" in
    dffa)
      dffa_has_shared_audience=true
      bd0c_has_shared_audience=false
      ;;
    bd0c)
      dffa_has_shared_audience=false
      bd0c_has_shared_audience=true
      ;;
    none)
      dffa_has_shared_audience=false
      bd0c_has_shared_audience=false
      ;;
  esac

  summary_path="$(write_summary_json "$tenant_id" "$generated_at" "$dffa_has_shared_audience" "$bd0c_has_shared_audience")"

  LAST_DFFA_PATH="$dffa_path"
  LAST_BD0C_PATH="$bd0c_path"
  LAST_SUMMARY_PATH="$summary_path"
  LAST_DFFA_HAS_SHARED_AUDIENCE="$dffa_has_shared_audience"
  LAST_BD0C_HAS_SHARED_AUDIENCE="$bd0c_has_shared_audience"
}

replacement_status_json() {
  local ownership="$1"
  local old_app_roles_json="$2"
  local old_delegated_json="$3"
  local new_app_roles_json="$4"
  local new_delegated_json="$5"

  jq -c -n \
    --arg ownership "$ownership" \
    --argjson oldAppRoles "$old_app_roles_json" \
    --argjson oldDelegated "$old_delegated_json" \
    --argjson newAppRoles "$new_app_roles_json" \
    --argjson newDelegated "$new_delegated_json" '
      def modeUsed:
        [
          (if ($oldAppRoles | length) > 0 then "app-role" else empty end),
          (if ($oldDelegated | length) > 0 then "delegated" else empty end)
        ];
      def modeSatisfied:
        [
          (if ($oldAppRoles | length) > 0 and ($newAppRoles | length) > 0 then "app-role" else empty end),
          (if ($oldDelegated | length) > 0 and ($newDelegated | length) > 0 then "delegated" else empty end)
        ];
      (modeUsed) as $used
      | (modeSatisfied) as $satisfied
      | {
          replacementStatus:
            (if $ownership != "customer" then null
             elif ($satisfied | length) == 0 then "not-started"
             elif ($satisfied | length) == ($used | length) then "complete"
             else "partial"
             end),
          replacementAssessed: ($ownership == "customer"),
          usageModes: {
            required: $used,
            satisfied: $satisfied
          }
        }
    '
}

authoritative_migration_state() {
  local inventory_entries_json="$1"
  local dffa_has_shared_audience="$2"
  local bd0c_has_shared_audience="$3"

  jq -r -n \
    --argjson apps "$inventory_entries_json" \
    --argjson dffaHasSharedAudience "$dffa_has_shared_audience" \
    --argjson bd0cHasSharedAudience "$bd0c_has_shared_audience" '
      if $dffaHasSharedAudience and ($bd0cHasSharedAudience | not) then
        "pre-migration"
      elif $bd0cHasSharedAudience then
        (
          [ $apps[]? | select(.ownership == "customer" and .replacementStatus != "complete") ] | length
        ) as $incompleteCustomerApps
        | if $incompleteCustomerApps > 0 then "partial" else "migrated" end
      else
        "pre-migration"
      end
    '
}

update_summary_migration_state() {
  local summary_path="$1"
  local migration_state="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  jq -c --arg migrationState "$migration_state" '.migrationState = $migrationState' "$summary_path" >"$tmp_file"
  mv "$tmp_file" "$summary_path"
}

run_3p_inventory() {
  local config_dir="$1"
  local tenant_id="$2"
  local generated_at old_resource_sp_id new_resource_sp_id
  local assignments_json new_assignments_json delegated_discovery_json delegated_grants_json new_delegated_discovery_json new_delegated_grants_json
  local inventory_entries_json inventory_path migration_state candidate_sp_id
  local sp_json sp_type sp_app_id sp_display_name sp_owner_org_id ownership application_object_id app_lookup_json
  local old_app_roles_json old_delegated_json new_app_roles_json new_delegated_json replacement_json

  generated_at="$(jq -r '.generatedAt' "$LAST_SUMMARY_PATH")"
  old_resource_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$OLD_RESOURCE_APP_ID")"
  [[ -n "$old_resource_sp_id" ]] || die "Unable to resolve dffa service principal for 3P inventory"

  new_resource_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$NEW_RESOURCE_APP_ID")"

  log_step "Discovering app-role assignments to the old resource"
  assignments_json="$(graph_request_json_all_pages "$config_dir" GET "$GRAPH_BASE_URL/servicePrincipals/$old_resource_sp_id/appRoleAssignedTo")"

  if [[ -n "$new_resource_sp_id" ]]; then
    log_step "Discovering app-role assignments to the new resource"
    new_assignments_json="$(graph_request_json_all_pages "$config_dir" GET "$GRAPH_BASE_URL/servicePrincipals/$new_resource_sp_id/appRoleAssignedTo")"
  else
    new_assignments_json='{"value":[]}'
  fi

  log_step "Discovering delegated grants to the old resource"
  delegated_discovery_json="$(inventory_delegated_grants_json "$config_dir" "$old_resource_sp_id")"
  delegated_grants_json="$(jq -c '{value: (.value // [])}' <<<"$delegated_discovery_json")"

  if [[ -n "$new_resource_sp_id" ]]; then
    log_step "Discovering delegated grants to the new resource"
    new_delegated_discovery_json="$(inventory_delegated_grants_json "$config_dir" "$new_resource_sp_id")"
    new_delegated_grants_json="$(jq -c '{value: (.value // [])}' <<<"$new_delegated_discovery_json")"
  else
    new_delegated_grants_json='{"value":[]}'
  fi

  mapfile -t candidate_sp_ids < <(
    jq -r -n \
      --argjson assignments "$assignments_json" \
      --argjson grants "$delegated_grants_json" '
        [
          ($assignments.value[]? | select(.principalType == "ServicePrincipal") | .principalId),
          ($grants.value[]?.clientId)
        ]
        | map(select(. != null and . != ""))
        | unique
        | .[]
      '
  )

  inventory_entries_json='[]'

  for candidate_sp_id in "${candidate_sp_ids[@]}"; do
    sp_json="$(graph_request_json "$config_dir" GET "$GRAPH_BASE_URL/servicePrincipals/$candidate_sp_id?\$select=id,appId,displayName,appOwnerOrganizationId,servicePrincipalType")" || continue

    sp_type="$(jq -r '.servicePrincipalType // empty' <<<"$sp_json")"
    if [[ "$sp_type" != "Application" ]]; then
      continue
    fi

    sp_app_id="$(jq -r '.appId // empty' <<<"$sp_json")"
    [[ -n "$sp_app_id" ]] || continue
    if is_known_inventory_excluded_app_id "$sp_app_id"; then
      continue
    fi

    sp_display_name="$(jq -r '.displayName // empty' <<<"$sp_json")"
    sp_owner_org_id="$(jq -r '.appOwnerOrganizationId // empty' <<<"$sp_json")"
    if [[ "$sp_owner_org_id" == "$tenant_id" ]]; then
      ownership="customer"
    else
      ownership="external"
    fi

    old_app_roles_json="$(
      jq -c --arg principalId "$candidate_sp_id" '
        [
          .value[]?
          | select(.principalType == "ServicePrincipal" and .principalId == $principalId)
          | {id, appRoleId}
        ]
      ' <<<"$assignments_json"
    )"
    old_delegated_json="$(
      jq -c --arg clientId "$candidate_sp_id" '
        [
          .value[]?
          | select(.clientId == $clientId)
          | {id, scope, consentType}
        ]
      ' <<<"$delegated_grants_json"
    )"
    new_app_roles_json="$(
      jq -c --arg principalId "$candidate_sp_id" '
        [
          .value[]?
          | select(.principalType == "ServicePrincipal" and .principalId == $principalId)
          | {id, appRoleId}
        ]
      ' <<<"$new_assignments_json"
    )"
    new_delegated_json="$(
      jq -c --arg clientId "$candidate_sp_id" '
        [
          .value[]?
          | select(.clientId == $clientId)
          | {id, scope, consentType}
        ]
      ' <<<"$new_delegated_grants_json"
    )"

    application_object_id=""
    if [[ "$ownership" == "customer" ]]; then
      app_lookup_json="$(graph_request_json "$config_dir" GET "$GRAPH_BASE_URL/applications?\$filter=appId eq '$sp_app_id'&\$select=id,appId,displayName")" || app_lookup_json='{"value":[]}'
      application_object_id="$(jq -r '.value[0].id // empty' <<<"$app_lookup_json")"
    fi

    replacement_json="$(replacement_status_json "$ownership" "$old_app_roles_json" "$old_delegated_json" "$new_app_roles_json" "$new_delegated_json")"
    inventory_entries_json="$(
      jq -c \
        --arg appId "$sp_app_id" \
        --arg applicationObjectId "$application_object_id" \
        --arg servicePrincipalId "$candidate_sp_id" \
        --arg displayName "$sp_display_name" \
        --arg ownership "$ownership" \
        --arg appOwnerOrganizationId "$sp_owner_org_id" \
        --arg servicePrincipalType "$sp_type" \
        --argjson oldAppRoles "$old_app_roles_json" \
        --argjson oldDelegated "$old_delegated_json" \
        --argjson newAppRoles "$new_app_roles_json" \
        --argjson newDelegated "$new_delegated_json" \
        --argjson replacement "$replacement_json" '
          . + [
            {
              appId: $appId,
              applicationObjectId: (($applicationObjectId | select(length > 0)) // null),
              servicePrincipalId: $servicePrincipalId,
              displayName: $displayName,
              ownership: $ownership,
              appOwnerOrganizationId: (($appOwnerOrganizationId | select(length > 0)) // null),
              servicePrincipalType: $servicePrincipalType,
              oldResource: {
                appRoleAssignments: $oldAppRoles,
                delegatedGrants: $oldDelegated
              },
              newResource: {
                appRoleAssignments: $newAppRoles,
                delegatedGrants: $newDelegated
              },
              replacementStatus: $replacement.replacementStatus,
              replacementAssessed: $replacement.replacementAssessed,
              usageModes: $replacement.usageModes
            }
          ]
        ' <<<"$inventory_entries_json"
    )"
  done

  inventory_entries_json="$(jq -c 'sort_by(.ownership, .displayName, .appId)' <<<"$inventory_entries_json")"
  inventory_path="$(artifact_filename "3p-inventory" "$generated_at")"
  printf '%s\n' "$inventory_entries_json" >"$inventory_path"

  migration_state="$(authoritative_migration_state "$inventory_entries_json" "$LAST_DFFA_HAS_SHARED_AUDIENCE" "$LAST_BD0C_HAS_SHARED_AUDIENCE")"
  update_summary_migration_state "$LAST_SUMMARY_PATH" "$migration_state"
  LAST_3P_INVENTORY_PATH="$inventory_path"
}

main() {
  local config_dir tenant_id

  parse_args "$@"
  load_runtime_overrides
  config_dir="$(current_config_dir)"
  tenant_id="$(run_preflight "$config_dir")"
  run_inventory_scaffold "$config_dir" "$tenant_id"
  if [[ "$SCOPE" == "all" || "$SCOPE" == "dffa-clients" ]]; then
    run_3p_inventory "$config_dir" "$tenant_id"
  fi
  print_summary_stdout "$tenant_id" "$LAST_SUMMARY_PATH" "$LAST_DFFA_PATH" "$LAST_BD0C_PATH" "$LAST_3P_INVENTORY_PATH"
}

main "$@"
