#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE=""
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/adme-entra-sim"

HOME_TENANT_ID_DEFAULT="8281dfeb-f25b-4764-846c-7c24ca956129"
CUSTOMER_TENANT_ID_DEFAULT="750f6c9b-c047-407d-979d-16a3776a7a8e"
ISV_TENANT_ID_DEFAULT="ff4b722d-81ae-4ee7-ba0a-833b95755f82"
HOME_CONFIG_DIR_DEFAULT="$HOME/.azure-tenant-KSAD"
CUSTOMER_CONFIG_DIR_DEFAULT="$HOME/.azure-tenant-KSAD2"
ISV_CONFIG_DIR_DEFAULT="$HOME/.azure-tenant-KSAAD"

SIM_DFFA_NAME_DEFAULT="sim-dffa"
SIM_BD0C_NAME_DEFAULT="sim-bd0c"
SIM_3P_CLIENT_NAME_DEFAULT="sim-3p-client"
SIM_3P_CLIENT_TWO_NAME_DEFAULT="sim-3p-client-2"
SIM_3P_CLIENT_THREE_NAME_DEFAULT="sim-3p-client-3"
SIM_EXTERNAL_MTA_NAME_DEFAULT="sim-external-mta"

SIM_SHARED_IDENTIFIER_URI="https://ksad.onmicrosoft.com/adme-energy-sim-merge-scripts"
SIM_OLD_IDENTIFIER_URI="https://ksad.onmicrosoft.com/adme-energy-old-sim-merge-scripts"
SIM_EXTERNAL_MTA_IDENTIFIER_URI="https://ksaad.onmicrosoft.com/adme-energy-external-mta-sim"

SIM_DFFA_IDENTIFIER_URI="$SIM_SHARED_IDENTIFIER_URI"
SIM_DFFA_SCOPE_VALUE="user_impersonation"
SIM_DFFA_SCOPE_ID="b51d4d2d-b434-4627-8f1d-6684a79793e7"
SIM_DFFA_ROLE_VALUE="ADME.ApplicationAccess"
SIM_DFFA_ROLE_ID="c0795231-e282-4abc-8822-576cbaea5bfb"

SIM_BD0C_SCOPE_VALUE="access_as_user"
SIM_BD0C_SCOPE_ID="66e904da-2872-4e72-bff6-a88a6c4375ea"
SIM_BD0C_ROLE_VALUE="ADME.ApplicationAccess"
SIM_BD0C_ROLE_ID="f1454897-e4e4-440e-9e04-bc379d7629f7"

AZURE_CLI_APP_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"
MICROSOFT_GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
MICROSOFT_GRAPH_USER_READ_SCOPE_ID="e1fe6dd8-ba31-4d61-89e7-88639da4683d"

HOME_TENANT_ID=""
CUSTOMER_TENANT_ID=""
ISV_TENANT_ID=""
HOME_CONFIG_DIR=""
CUSTOMER_CONFIG_DIR=""
ISV_CONFIG_DIR=""
SIM_DFFA_NAME=""
SIM_BD0C_NAME=""
SIM_3P_CLIENT_NAME=""
SIM_3P_CLIENT_TWO_NAME=""
SIM_3P_CLIENT_THREE_NAME=""
SIM_EXTERNAL_MTA_NAME=""

STATE_JSON_FILE=""
STATE_ENV_FILE=""

usage() {
  cat <<'EOF'
Usage:
  simulate-1p-apps.sh [--config path] [--state-dir dir] [--home-config-dir dir] [--customer-config-dir dir] [--isv-config-dir dir] <command>

Commands:
  setup            Build the baseline simulation state used by milestone M1.
  update-1p-apps   Move the shared identifierUri from sim-dffa to sim-bd0c without touching the customer tenant.
  grant            Re-create the post-migration grants in the customer tenant from the saved simulation state.
  external-mta     Create an ISV-owned multi-tenant app in KSAAD and install its customer SP with a sim-dffa app-role assignment.
  cleanup          Remove all simulated resources and delete any saved runtime state artifacts.

Options:
  --config path          Source a shell config file before applying defaults.
  --state-dir dir        Directory for generated state artifacts (default: $XDG_RUNTIME_DIR/adme-entra-sim or /tmp/adme-entra-sim).
  --home-config-dir dir  Azure CLI config dir for the home/1P tenant.
  --customer-config-dir dir
                          Azure CLI config dir for the customer tenant.
  --isv-config-dir dir   Azure CLI config dir for the ISV/external tenant.
  -h, --help             Show this help text.

The setup command emits:
  - sim-state.json  Machine-readable IDs and runtime metadata.
  - sim-state.env   Sourceable environment file with IDs plus the generated client secret.

The env file is created with owner-only permissions and must not be committed.
EOF
}

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

internal_force_tier2_fallback_enabled() {
  case "${ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK:-false}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

internal_primary_client_only_enabled() {
  case "${ADME_SIM_INTERNAL_PRIMARY_CLIENT_ONLY:-false}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

internal_skip_client_setup_enabled() {
  case "${ADME_SIM_INTERNAL_SKIP_CLIENT_SETUP:-false}" in
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
  AZURE_CONFIG_DIR="$config_dir" az "$@"
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

graph_delete() {
  local config_dir="$1"
  local url="$2"
  run_az "$config_dir" rest --method DELETE --url "$url" >/dev/null
}

current_tenant_id() {
  local config_dir="$1"
  run_az "$config_dir" account show --query tenantId -o tsv
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

write_env_var() {
  local handle="$1"
  local key="$2"
  local value="$3"
  local escaped_value

  escaped_value="${value//\'/\'\\\'\'}"
  printf "export %s='%s'\n" "$key" "$escaped_value" >>"$handle"
}

source_shell_file() {
  local file="$1"

  if ! bash -n "$file"; then
    die "Shell config/state file has invalid syntax: $file"
  fi

  # shellcheck disable=SC1090
  source "$file"
}

find_application_json_by_display_name() {
  local config_dir="$1"
  local display_name="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/applications?\$filter=displayName eq '$display_name'"
}

find_application_object_id_by_display_name() {
  local config_dir="$1"
  local display_name="$2"

  find_application_json_by_display_name "$config_dir" "$display_name" | jq -r '.value[0].id // empty'
}

find_application_app_id_by_display_name() {
  local config_dir="$1"
  local display_name="$2"

  find_application_json_by_display_name "$config_dir" "$display_name" | jq -r '.value[0].appId // empty'
}

wait_for_application_by_app_id() {
  local label="$1"
  local config_dir="$2"
  local app_id="$3"
  local attempt applications_json

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    applications_json="$(graph_request_json \
      "$config_dir" \
      GET \
      "https://graph.microsoft.com/v1.0/applications?\$filter=appId eq '$app_id'&\$select=id,appId")"
    if jq -e '.value | length > 0' <<<"$applications_json" >/dev/null; then
      log_success "$label application is queryable on attempt $attempt"
      return 0
    fi
    log INFO "$label application not queryable on attempt $attempt/12 yet"
    sleep 5
  done

  die "$label application did not become queryable after creation"
}

wait_for_service_principal_name_clear() {
  local label="$1"
  local config_dir="$2"
  local service_principal_name="$3"
  local attempt active_json deleted_json active_count deleted_count

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    active_json="$(graph_request_json \
      "$config_dir" \
      GET \
      "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=servicePrincipalNames/any(s:s eq '$service_principal_name')&\$select=id")"
    deleted_json="$(graph_request_json \
      "$config_dir" \
      GET \
      "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.servicePrincipal?\$filter=servicePrincipalNames/any(s:s eq '$service_principal_name')&\$select=id")"
    active_count="$(jq -r '[.value[]?.id] | length' <<<"$active_json")"
    deleted_count="$(jq -r '[.value[]?.id] | length' <<<"$deleted_json")"

    if [[ "$active_count" == "0" && "$deleted_count" == "0" ]]; then
      log_success "$label servicePrincipalName is clear on attempt $attempt"
      return 0
    fi

    log INFO "$label servicePrincipalName still in use on attempt $attempt/12 (active=$active_count deleted=$deleted_count)"
    sleep 5
  done

  die "$label servicePrincipalName $service_principal_name did not clear after waiting for propagation"
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

find_service_principal_ids_by_display_name() {
  local config_dir="$1"
  local display_name="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=displayName eq '$display_name'" \
    | jq -r '.value[].id'
}

delete_service_principal_if_exists_by_app_id() {
  local label="$1"
  local config_dir="$2"
  local app_id="$3"
  local sp_id

  [[ -n "$app_id" ]] || return 0
  sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
  if [[ -z "$sp_id" ]]; then
    log INFO "$label service principal not present for appId $app_id"
    return 0
  fi

  log INFO "Deleting $label service principal: $sp_id"
  graph_delete "$config_dir" "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id"
  log_success "Deleted $label service principal"
}

delete_service_principals_if_exists_by_display_name() {
  local label="$1"
  local config_dir="$2"
  local display_name="$3"
  local sp_ids

  sp_ids="$(find_service_principal_ids_by_display_name "$config_dir" "$display_name" || true)"
  if [[ -z "$sp_ids" ]]; then
    log INFO "$label service principals not present by displayName $display_name"
    return 0
  fi

  while IFS= read -r sp_id; do
    [[ -n "$sp_id" ]] || continue
    log INFO "Deleting $label service principal by displayName: $sp_id"
    graph_delete "$config_dir" "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id"
  done <<<"$sp_ids"
  log_success "Deleted any lingering $label service principals by displayName"
}

delete_service_principals_if_exists_by_service_principal_name() {
  local label="$1"
  local config_dir="$2"
  local service_principal_name="$3"
  local sp_json sp_ids

  sp_json="$(graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=servicePrincipalNames/any(s:s eq '$service_principal_name')&\$select=id")"
  sp_ids="$(jq -r '.value[]?.id // empty' <<<"$sp_json")"
  if [[ -z "$sp_ids" ]]; then
    log INFO "$label service principals not present by servicePrincipalName $service_principal_name"
    return 0
  fi

  while IFS= read -r sp_id; do
    [[ -n "$sp_id" ]] || continue
    log INFO "Deleting $label service principal by servicePrincipalName: $sp_id"
    graph_delete "$config_dir" "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id"
  done <<<"$sp_ids"
  log_success "Deleted any lingering $label service principals by servicePrincipalName"
}

purge_deleted_service_principals_by_display_name() {
  local label="$1"
  local config_dir="$2"
  local display_name="$3"
  local deleted_json deleted_ids purged_any=0
  local deleted_count delete_failures=0 deleted_id pid
  local -a purge_pids=()
  local batch_size=8

  while true; do
    deleted_json="$(graph_request_json \
      "$config_dir" \
      GET \
      "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.servicePrincipal?\$filter=displayName eq '$display_name'&\$select=id")"
    deleted_ids="$(jq -r '.value[]?.id // empty' <<<"$deleted_json")"
    [[ -n "$deleted_ids" ]] || break

    deleted_count="$(printf '%s\n' "$deleted_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
    log INFO "Purging $deleted_count soft-deleted $label service principal(s) in parallel"

    while IFS= read -r deleted_id; do
      [[ -n "$deleted_id" ]] || continue
      (
        graph_delete "$config_dir" "https://graph.microsoft.com/v1.0/directory/deletedItems/$deleted_id"
      ) &
      purge_pids+=("$!")
      purged_any=1

      if [[ "${#purge_pids[@]}" -ge "$batch_size" ]]; then
        for pid in "${purge_pids[@]}"; do
          wait "$pid" || delete_failures=$((delete_failures + 1))
        done
        purge_pids=()
      fi
    done <<<"$deleted_ids"

    for pid in "${purge_pids[@]}"; do
      wait "$pid" || delete_failures=$((delete_failures + 1))
    done
    purge_pids=()

    if [[ "$delete_failures" -ne 0 ]]; then
      die "Failed to purge one or more soft-deleted $label service principals"
    fi
  done

  if [[ "$purged_any" -eq 1 ]]; then
    log_success "Purged soft-deleted $label service principals"
  else
    log INFO "No soft-deleted $label service principals found"
  fi
}

delete_application_if_exists() {
  local label="$1"
  local config_dir="$2"
  local display_name="$3"
  local object_id

  object_id="$(find_application_object_id_by_display_name "$config_dir" "$display_name")"
  if [[ -z "$object_id" ]]; then
    log INFO "$label application not present by displayName $display_name"
    return 0
  fi

  log INFO "Deleting $label application: $object_id"
  graph_delete "$config_dir" "https://graph.microsoft.com/v1.0/applications/$object_id"
  log_success "Deleted $label application"
}

cleanup_previous_simulation_resources() {
  local previous_dffa_app_id=""
  local previous_bd0c_app_id=""
  local previous_client_app_id=""
  local previous_client_two_app_id=""
  local previous_client_three_app_id=""
  local previous_external_mta_app_id=""

  log_step "Removing any existing simulation resources"

  previous_dffa_app_id="$(find_application_app_id_by_display_name "$HOME_CONFIG_DIR" "$SIM_DFFA_NAME")"
  previous_bd0c_app_id="$(find_application_app_id_by_display_name "$HOME_CONFIG_DIR" "$SIM_BD0C_NAME")"
  previous_client_app_id="$(find_application_app_id_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_NAME")"
  previous_client_two_app_id="$(find_application_app_id_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_TWO_NAME")"
  previous_client_three_app_id="$(find_application_app_id_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_THREE_NAME")"
  previous_external_mta_app_id="$(find_application_app_id_by_display_name "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME")"

  delete_service_principal_if_exists_by_app_id "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$previous_dffa_app_id"
  delete_service_principal_if_exists_by_app_id "customer sim-bd0c" "$CUSTOMER_CONFIG_DIR" "$previous_bd0c_app_id"
  delete_service_principal_if_exists_by_app_id "customer sim-3p-client" "$CUSTOMER_CONFIG_DIR" "$previous_client_app_id"
  delete_service_principal_if_exists_by_app_id "customer sim-3p-client-2" "$CUSTOMER_CONFIG_DIR" "$previous_client_two_app_id"
  delete_service_principal_if_exists_by_app_id "customer sim-3p-client-3" "$CUSTOMER_CONFIG_DIR" "$previous_client_three_app_id"
  delete_service_principal_if_exists_by_app_id "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$previous_external_mta_app_id"

  delete_service_principals_if_exists_by_service_principal_name "customer simulator shared-uri" "$CUSTOMER_CONFIG_DIR" "$SIM_SHARED_IDENTIFIER_URI"
  delete_service_principals_if_exists_by_service_principal_name "customer simulator old-uri" "$CUSTOMER_CONFIG_DIR" "$SIM_OLD_IDENTIFIER_URI"
  delete_service_principals_if_exists_by_display_name "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$SIM_DFFA_NAME"
  delete_service_principals_if_exists_by_display_name "customer sim-bd0c" "$CUSTOMER_CONFIG_DIR" "$SIM_BD0C_NAME"
  delete_service_principals_if_exists_by_display_name "customer sim-3p-client" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_NAME"
  delete_service_principals_if_exists_by_display_name "customer sim-3p-client-2" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_TWO_NAME"
  delete_service_principals_if_exists_by_display_name "customer sim-3p-client-3" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_THREE_NAME"
  delete_service_principals_if_exists_by_display_name "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$SIM_DFFA_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-bd0c" "$CUSTOMER_CONFIG_DIR" "$SIM_BD0C_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-3p-client" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-3p-client-2" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_TWO_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-3p-client-3" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_THREE_NAME"
  purge_deleted_service_principals_by_display_name "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"

  delete_service_principal_if_exists_by_app_id "home sim-dffa" "$HOME_CONFIG_DIR" "$previous_dffa_app_id"
  delete_service_principal_if_exists_by_app_id "home sim-bd0c" "$HOME_CONFIG_DIR" "$previous_bd0c_app_id"
  delete_service_principal_if_exists_by_app_id "isv sim-external-mta" "$ISV_CONFIG_DIR" "$previous_external_mta_app_id"
  delete_service_principals_if_exists_by_display_name "isv sim-external-mta" "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"
  purge_deleted_service_principals_by_display_name "home sim-dffa" "$HOME_CONFIG_DIR" "$SIM_DFFA_NAME"
  purge_deleted_service_principals_by_display_name "home sim-bd0c" "$HOME_CONFIG_DIR" "$SIM_BD0C_NAME"
  purge_deleted_service_principals_by_display_name "isv sim-external-mta" "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"

  delete_application_if_exists "customer sim-3p-client" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_NAME"
  delete_application_if_exists "customer sim-3p-client-2" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_TWO_NAME"
  delete_application_if_exists "customer sim-3p-client-3" "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_THREE_NAME"
  delete_application_if_exists "home sim-dffa" "$HOME_CONFIG_DIR" "$SIM_DFFA_NAME"
  delete_application_if_exists "home sim-bd0c" "$HOME_CONFIG_DIR" "$SIM_BD0C_NAME"
  delete_application_if_exists "isv sim-external-mta" "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"

  log_success "Previous simulation resources are cleared"
}

build_sim_dffa_application_body() {
  jq -cn \
    --arg displayName "$SIM_DFFA_NAME" \
    --arg identifierUri "$SIM_DFFA_IDENTIFIER_URI" \
    --arg scopeId "$SIM_DFFA_SCOPE_ID" \
    --arg scopeValue "$SIM_DFFA_SCOPE_VALUE" \
    --arg roleId "$SIM_DFFA_ROLE_ID" \
    --arg roleValue "$SIM_DFFA_ROLE_VALUE" \
    '{
      displayName: $displayName,
      signInAudience: "AzureADMultipleOrgs",
      identifierUris: [$identifierUri],
      api: {
        requestedAccessTokenVersion: 2,
        oauth2PermissionScopes: [
          {
            adminConsentDescription: "Allow the application to access the simulated ADME API on behalf of the signed-in user.",
            adminConsentDisplayName: "Access simulated ADME as the signed-in user",
            id: $scopeId,
            isEnabled: true,
            type: "User",
            userConsentDescription: "Allow the application to access the simulated ADME API on your behalf.",
            userConsentDisplayName: "Access simulated ADME",
            value: $scopeValue
          }
        ]
      },
      appRoles: [
        {
          allowedMemberTypes: ["Application"],
          description: "Allows the application to call the simulated ADME API as itself.",
          displayName: $roleValue,
          id: $roleId,
          isEnabled: true,
          value: $roleValue
        }
      ]
    }'
}

build_sim_bd0c_application_body() {
  jq -cn \
    --arg displayName "$SIM_BD0C_NAME" \
    --arg scopeId "$SIM_BD0C_SCOPE_ID" \
    --arg scopeValue "$SIM_BD0C_SCOPE_VALUE" \
    --arg roleId "$SIM_BD0C_ROLE_ID" \
    --arg roleValue "$SIM_BD0C_ROLE_VALUE" \
    --arg cliAppId "$AZURE_CLI_APP_ID" \
    '{
      displayName: $displayName,
      signInAudience: "AzureADMultipleOrgs",
      api: {
        requestedAccessTokenVersion: 2,
        oauth2PermissionScopes: [
          {
            adminConsentDescription: "Allow the application to access the simulated replacement ADME API on behalf of the signed-in user.",
            adminConsentDisplayName: "Access simulated replacement ADME as the signed-in user",
            id: $scopeId,
            isEnabled: true,
            type: "User",
            userConsentDescription: "Allow the application to access the simulated replacement ADME API on your behalf.",
            userConsentDisplayName: "Access simulated replacement ADME",
            value: $scopeValue
          }
        ],
        preAuthorizedApplications: [
          {
            appId: $cliAppId,
            delegatedPermissionIds: [$scopeId]
          }
        ]
      },
      appRoles: [
        {
          allowedMemberTypes: ["Application"],
          description: "Allows the application to call the simulated replacement ADME API as itself.",
          displayName: $roleValue,
          id: $roleId,
          isEnabled: true,
          value: $roleValue
        }
      ]
    }'
}

build_sim_3p_client_application_body() {
  local display_name="$1"
  local dffa_app_id="$2"

  jq -cn \
    --arg displayName "$display_name" \
    --arg dffaAppId "$dffa_app_id" \
    --arg dffaScopeId "$SIM_DFFA_SCOPE_ID" \
    --arg dffaRoleId "$SIM_DFFA_ROLE_ID" \
    --arg graphAppId "$MICROSOFT_GRAPH_APP_ID" \
    --arg graphUserReadScopeId "$MICROSOFT_GRAPH_USER_READ_SCOPE_ID" \
    '{
      displayName: $displayName,
      signInAudience: "AzureADMyOrg",
      requiredResourceAccess: [
        {
          resourceAppId: $dffaAppId,
          resourceAccess: [
            {id: $dffaRoleId, type: "Role"},
            {id: $dffaScopeId, type: "Scope"}
          ]
        },
        {
          resourceAppId: $graphAppId,
          resourceAccess: [
            {id: $graphUserReadScopeId, type: "Scope"}
          ]
        }
      ]
    }'
}

build_sim_external_mta_application_body() {
  local display_name="$1"
  local dffa_app_id="$2"

  jq -cn \
    --arg displayName "$display_name" \
    --arg identifierUri "$SIM_EXTERNAL_MTA_IDENTIFIER_URI" \
    --arg dffaAppId "$dffa_app_id" \
    --arg dffaRoleId "$SIM_DFFA_ROLE_ID" \
    '{
      displayName: $displayName,
      signInAudience: "AzureADMultipleOrgs",
      identifierUris: [$identifierUri],
      requiredResourceAccess: [
        {
          resourceAppId: $dffaAppId,
          resourceAccess: [
            {id: $dffaRoleId, type: "Role"}
          ]
        }
      ]
    }'
}

create_sim_3p_client() {
  local label="$1"
  local display_name="$2"
  local dffa_app_id="$3"
  local dffa_customer_sp_id="$4"
  local create_secret="${5:-0}"
  local client_body client_app_json client_app_object_id client_app_id client_sp_id client_secret=""

  log_step "Creating customer-tenant client application: $label"
  client_body="$(build_sim_3p_client_application_body "$display_name" "$dffa_app_id")"
  client_app_json="$(create_application "$label" "$CUSTOMER_CONFIG_DIR" "$client_body")"
  client_app_object_id="$(jq -r '.id' <<<"$client_app_json")"
  client_app_id="$(jq -r '.appId' <<<"$client_app_json")"
  log_success "Created $label appId=$client_app_id objectId=$client_app_object_id"
  wait_for_application_by_app_id "$label" "$CUSTOMER_CONFIG_DIR" "$client_app_id"

  log_step "Ensuring customer-tenant service principal exists for $label"
  client_sp_id="$(ensure_service_principal "customer $label" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$client_app_id")"
  client_sp_id="$(wait_for_service_principal "customer $label" "$CUSTOMER_CONFIG_DIR" "$client_app_id")"
  wait_for_service_principal_readable "customer $label" "$CUSTOMER_CONFIG_DIR" "$client_sp_id"

  log_step "Ensuring baseline old resource (dffa) grants exist for $label"
  wait_for_service_principal_app_role \
    "customer sim-dffa" \
    "$CUSTOMER_CONFIG_DIR" \
    "$dffa_customer_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "$SIM_DFFA_ROLE_VALUE"
  ensure_app_role_assignment \
    "$dffa_customer_sp_id" \
    "$client_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer $label -> sim-dffa app role assignment"
  wait_for_app_role_assignment \
    "$dffa_customer_sp_id" \
    "$client_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer $label -> sim-dffa app role assignment" \
    >/dev/null
  ensure_oauth2_permission_grant \
    "customer $label delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$client_sp_id" \
    "$dffa_customer_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  if [[ "$create_secret" == "1" ]]; then
    log_step "Generating a client secret for $label"
    client_secret="$(add_password_credential "$CUSTOMER_CONFIG_DIR" "$client_app_object_id" "$display_name-secret")"
    [[ -n "$client_secret" ]] || die "$label secret creation did not return a secretText value"
    log_success "Generated $label secret and stored it in the env state file only"
  fi

  printf '%s\t%s\t%s\t%s\n' "$client_app_object_id" "$client_app_id" "$client_sp_id" "$client_secret"
}

create_application() {
  local label="$1"
  local config_dir="$2"
  local body="$3"

  log INFO "Creating $label application"
  graph_request_json "$config_dir" POST "https://graph.microsoft.com/v1.0/applications" "$body"
}

add_password_credential() {
  local config_dir="$1"
  local app_object_id="$2"
  local display_name="$3"
  local body response

  body="$(jq -cn --arg displayName "$display_name" '{passwordCredential: {displayName: $displayName}}')"
  response="$(graph_request_json "$config_dir" POST "https://graph.microsoft.com/v1.0/applications/$app_object_id/addPassword" "$body")"
  jq -r '.secretText' <<<"$response"
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

refresh_service_principal_names() {
  local label="$1"
  local config_dir="$2"
  local sp_id="$3"
  local expected_present_uri="$4"
  local expected_absent_uri="${5:-}"
  local sp_json sp_names original_tags probe_tag patched_tags refresh_attempt refresh_succeeded

  sp_json="$(graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id")"
  original_tags="$(jq -c '.tags // []' <<<"$sp_json")"
  probe_tag="$(make_refresh_probe_tag)"
  patched_tags="$(jq -cn --argjson tags "$original_tags" --arg probeTag "$probe_tag" '$tags + [$probeTag] | unique')"

  log_step "Applying a temporary refresh probe tag to the $label service principal"
  patch_service_principal_tags "$config_dir" "$sp_id" "$patched_tags"
  trap 'patch_service_principal_tags "$config_dir" "$sp_id" "$original_tags" >/dev/null 2>&1' EXIT
  log_success "Applied refresh probe tag $probe_tag"

  log_step "Polling for the refreshed $label servicePrincipalNames"
  refresh_succeeded=0
  for refresh_attempt in 1 2 3; do
    sp_json="$(graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id")"
    sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$sp_json")"
    if [[ -n "$expected_absent_uri" ]]; then
      if jq -e --arg present "$expected_present_uri" --arg absent "$expected_absent_uri" '
        (.servicePrincipalNames // []) | index($present) != null and index($absent) == null
      ' <<<"$sp_json" >/dev/null; then
        log_success "$label servicePrincipalNames refreshed on attempt $refresh_attempt: $sp_names"
        refresh_succeeded=1
        break
      fi
    else
      if jq -e --arg expected "$expected_present_uri" '
        (.servicePrincipalNames // []) | index($expected) != null
      ' <<<"$sp_json" >/dev/null; then
        log_success "$label servicePrincipalNames refreshed on attempt $refresh_attempt: $sp_names"
        refresh_succeeded=1
        break
      fi
    fi
    log INFO "$label servicePrincipalNames not refreshed on attempt $refresh_attempt/3 yet: $sp_names"
    sleep 5
  done

  log_step "Removing the temporary refresh probe tag"
  patch_service_principal_tags "$config_dir" "$sp_id" "$original_tags"
  trap - EXIT
  log_success "Removed refresh probe tag $probe_tag"

  if [[ "$refresh_succeeded" -ne 1 ]]; then
    if [[ -n "$expected_absent_uri" ]]; then
      die "$label servicePrincipalNames did not refresh to include $expected_present_uri and exclude $expected_absent_uri after the probe-tag PATCH"
    fi
    die "$label servicePrincipalNames did not refresh to include $expected_present_uri after the probe-tag PATCH"
  fi

  printf '%s\n' "$sp_json"
}

recreate_customer_sim_dffa_service_principal() {
  local sim_dffa_app_id="$1"
  local azure_cli_customer_sp_id="$2"
  local sim_3p_client_sp_id="$3"
  local sim_3p_client_two_sp_id="$4"
  local sim_3p_client_three_sp_id="$5"
  local recreated_sp_id recreated_sp_json recreated_sp_names

  log_warn "customer sim-dffa refresh stayed stale after the probe-tag PATCH; falling back to delete/recreate in the simulator"

  delete_service_principal_if_exists_by_app_id "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$sim_dffa_app_id"
  recreated_sp_id="$(ensure_service_principal "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$sim_dffa_app_id")"
  recreated_sp_id="$(wait_for_service_principal "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$sim_dffa_app_id")"
  wait_for_service_principal_app_role \
    "customer sim-dffa" \
    "$CUSTOMER_CONFIG_DIR" \
    "$recreated_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "$SIM_DFFA_ROLE_VALUE"

  ensure_oauth2_permission_grant \
    "customer Microsoft Azure CLI delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$azure_cli_customer_sp_id" \
    "$recreated_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  ensure_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client -> sim-dffa app role assignment"
  wait_for_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client -> sim-dffa app role assignment" \
    >/dev/null
  ensure_oauth2_permission_grant \
    "customer sim-3p-client delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$sim_3p_client_sp_id" \
    "$recreated_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  ensure_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_two_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client-2 -> sim-dffa app role assignment"
  wait_for_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_two_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client-2 -> sim-dffa app role assignment" \
    >/dev/null
  ensure_oauth2_permission_grant \
    "customer sim-3p-client-2 delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$sim_3p_client_two_sp_id" \
    "$recreated_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  ensure_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_three_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client-3 -> sim-dffa app role assignment"
  wait_for_app_role_assignment \
    "$recreated_sp_id" \
    "$sim_3p_client_three_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-3p-client-3 -> sim-dffa app role assignment" \
    >/dev/null
  ensure_oauth2_permission_grant \
    "customer sim-3p-client-3 delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$sim_3p_client_three_sp_id" \
    "$recreated_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  recreated_sp_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$recreated_sp_id")"
  recreated_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$recreated_sp_json")"
  log INFO "Customer sim-dffa servicePrincipalNames after delete/recreate: $recreated_sp_names"
  jq -e --arg shared "$SIM_SHARED_IDENTIFIER_URI" --arg old "$SIM_OLD_IDENTIFIER_URI" '
    (.servicePrincipalNames // []) | index($old) != null and index($shared) == null
  ' <<<"$recreated_sp_json" >/dev/null || die "Customer sim-dffa service principal still did not refresh to $SIM_OLD_IDENTIFIER_URI after delete/recreate"
  log_success "Verified recreated customer sim-dffa now advertises $SIM_OLD_IDENTIFIER_URI and not $SIM_SHARED_IDENTIFIER_URI"

  recreated_sp_json="$(jq -c '.' <<<"$recreated_sp_json")"
  printf '%s\t%s\n' "$recreated_sp_id" "$recreated_sp_json"
}

ensure_service_principal() {
  local label="$1"
  local config_dir="$2"
  local tenant_id="$3"
  local app_id="$4"
  local existing_sp_id created_json stderr_file create_error retry_sp_id attempt

  existing_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
  if [[ -n "$existing_sp_id" ]]; then
    log INFO "$label service principal already exists: $existing_sp_id"
    printf '%s\n' "$existing_sp_id"
    return 0
  fi

  for attempt in 1 2 3 4 5 6 7 8; do
    stderr_file="$(mktemp)"
    if created_json="$(AZURE_CONFIG_DIR="$config_dir" az ad sp create --id "$app_id" -o json 2>"$stderr_file")"; then
      rm -f "$stderr_file"
      printf '%s\n' "$(jq -r '.id' <<<"$created_json")"
      return 0
    fi

    create_error="$(<"$stderr_file")"
    rm -f "$stderr_file"
    log_warn "$label service principal creation via az ad sp create failed on attempt $attempt/8: ${create_error:-<no stderr>}"

    retry_sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
    if [[ -n "$retry_sp_id" ]]; then
      log INFO "$label service principal became available after failed create attempt: $retry_sp_id"
      printf '%s\n' "$retry_sp_id"
      return 0
    fi

    sleep 5
  done

  die "$label service principal could not be created automatically in tenant $tenant_id after repeated az ad sp create attempts. Verify the app is multi-tenant and that cross-tenant propagation has completed."
}

wait_for_service_principal() {
  local label="$1"
  local config_dir="$2"
  local app_id="$3"
  local attempt sp_id

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sp_id="$(find_service_principal_id_by_app_id "$config_dir" "$app_id")"
    if [[ -n "$sp_id" ]]; then
      log_success "$label service principal is available on attempt $attempt"
      printf '%s\n' "$sp_id"
      return 0
    fi
    sleep 4
  done

  die "$label service principal did not appear after creation attempts"
}

wait_for_service_principal_readable() {
  local label="$1"
  local config_dir="$2"
  local sp_id="$3"
  local attempt sp_json stderr_file read_error

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    stderr_file="$(mktemp)"
    if sp_json="$(graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id?\$select=id,appId" 2>"$stderr_file")"; then
      rm -f "$stderr_file"
      if jq -e '.id != null and .appId != null' <<<"$sp_json" >/dev/null; then
        log_success "$label service principal is directly readable on attempt $attempt"
        return 0
      fi
    else
      read_error="$(<"$stderr_file")"
      rm -f "$stderr_file"
      if grep -Eq 'Request_ResourceNotFound|does not exist or one of its queried reference-property objects are not present|Specified resourceId was not found' <<<"$read_error"; then
        log INFO "$label service principal is not directly readable on attempt $attempt/12 yet"
        sleep 5
        continue
      fi

      die "Failed reading $label service principal: ${read_error:-<no stderr>}"
    fi

    log INFO "$label service principal read returned incomplete data on attempt $attempt/12"
    sleep 5
  done

  die "$label service principal was not directly readable after waiting for propagation"
}

wait_for_service_principal_app_role() {
  local label="$1"
  local config_dir="$2"
  local sp_id="$3"
  local role_id="$4"
  local role_value="$5"
  local attempt sp_json stderr_file read_error

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    stderr_file="$(mktemp)"
    if ! sp_json="$(graph_request_json "$config_dir" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sp_id?\$select=appRoles" 2>"$stderr_file")"; then
      read_error="$(<"$stderr_file")"
      rm -f "$stderr_file"
      if grep -Eq 'Request_ResourceNotFound|does not exist or one of its queried reference-property objects are not present|Specified resourceId was not found' <<<"$read_error"; then
        log INFO "$label service principal not readable on attempt $attempt/12 yet"
        sleep 5
        continue
      fi

      die "Failed reading $label service principal app roles: ${read_error:-<no stderr>}"
    fi
    rm -f "$stderr_file"

    if jq -e --arg roleId "$role_id" '
      (.appRoles // []) | map(select(.id == $roleId and (.isEnabled // true))) | length > 0
    ' <<<"$sp_json" >/dev/null; then
      log_success "$label app role $role_value is available on attempt $attempt"
      return 0
    fi
    log INFO "$label app role $role_value not visible on attempt $attempt/12 yet"
    sleep 5
  done

  die "$label app role $role_value was not visible after waiting for propagation"
}

oauth2_permission_grant_error_is_retryable() {
  local error_text="${1:-}"

  grep -Eq 'Request_ResourceNotFound|does not exist or one of its queried reference-property objects are not present|Specified resourceId was not found|Permission being assigned was not found on application' <<<"$error_text"
}

app_role_assignment_error_is_retryable() {
  local error_text="${1:-}"

  grep -Eq 'Request_ResourceNotFound|does not exist or one of its queried reference-property objects are not present|Specified resourceId was not found|Permission being assigned was not found on application' <<<"$error_text"
}

ensure_oauth2_permission_grant() {
  local label="$1"
  local config_dir="$2"
  local client_sp_id="$3"
  local resource_sp_id="$4"
  local scope_value="$5"
  local existing_json existing_grant_id existing_scope merged_scope body
  local stderr_file grant_error attempt

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
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
      stderr_file="$(mktemp)"
      if graph_request_json "$config_dir" PATCH "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$existing_grant_id" "$body" >/dev/null 2>"$stderr_file"; then
        rm -f "$stderr_file"
        log_success "Updated $label to scope '$merged_scope'"
        return 0
      fi

      grant_error="$(<"$stderr_file")"
      rm -f "$stderr_file"
      if oauth2_permission_grant_error_is_retryable "$grant_error"; then
        log INFO "$label update not ready on attempt $attempt/12 yet; waiting for propagation"
        sleep 5
        continue
      fi

      die "Failed to update $label: ${grant_error:-<no stderr>}"
    done

    die "$label could not be updated after waiting for propagation"
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

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    stderr_file="$(mktemp)"
    if graph_request_json "$config_dir" POST "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" "$body" >/dev/null 2>"$stderr_file"; then
      rm -f "$stderr_file"
      log_success "Created $label with scope '$scope_value'"
      return 0
    fi

    grant_error="$(<"$stderr_file")"
    rm -f "$stderr_file"
    if oauth2_permission_grant_error_is_retryable "$grant_error"; then
      log INFO "$label creation not ready on attempt $attempt/12 yet; waiting for propagation"
      sleep 5
      continue
    fi

    die "Failed to create $label: ${grant_error:-<no stderr>}"
  done

  die "$label could not be created after waiting for propagation"
}

load_runtime_state() {
  local existing_state_env_file

  existing_state_env_file="$STATE_DIR/sim-state.env"
  [[ -f "$existing_state_env_file" ]] || die "Expected runtime state file not found: $existing_state_env_file"
  source_shell_file "$existing_state_env_file"
}

find_matching_app_role_assignment_id() {
  local resource_sp_id="$1"
  local principal_id="${2:-$CLIENT_SERVICE_PRINCIPAL_ID}"
  local app_role_id="${3:-$NEW_RESOURCE_APP_ROLE_ID}"
  local assignments_json

  assignments_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo")"
  jq -r \
    --arg principalId "$principal_id" \
    --arg appRoleId "$app_role_id" \
    '.value[] | select(.principalId == $principalId and .appRoleId == $appRoleId) | .id' \
    <<<"$assignments_json" \
    | head -n 1
}

count_matching_app_role_assignments() {
  local resource_sp_id="$1"
  local principal_id="${2:-$CLIENT_SERVICE_PRINCIPAL_ID}"
  local app_role_id="${3:-$NEW_RESOURCE_APP_ROLE_ID}"
  local assignments_json

  assignments_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo")"
  jq -r \
    --arg principalId "$principal_id" \
    --arg appRoleId "$app_role_id" \
    '[.value[] | select(.principalId == $principalId and .appRoleId == $appRoleId)] | length' \
    <<<"$assignments_json"
}

ensure_app_role_assignment() {
  local resource_sp_id="$1"
  local principal_id="${2:-$CLIENT_SERVICE_PRINCIPAL_ID}"
  local app_role_id="${3:-$NEW_RESOURCE_APP_ROLE_ID}"
  local label="${4:-sim-3p-client -> sim-bd0c app role assignment}"
  local existing_assignment_id body
  local stderr_file assignment_error attempt

  existing_assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id" "$principal_id" "$app_role_id")"
  if [[ -n "$existing_assignment_id" ]]; then
    log INFO "$label already exists: $existing_assignment_id"
    return 0
  fi

  body="$(jq -cn \
    --arg principalId "$principal_id" \
    --arg resourceId "$resource_sp_id" \
    --arg appRoleId "$app_role_id" \
    '{
      principalId: $principalId,
      resourceId: $resourceId,
      appRoleId: $appRoleId
    }')"

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    stderr_file="$(mktemp)"
    if graph_request_json "$CUSTOMER_CONFIG_DIR" POST "https://graph.microsoft.com/v1.0/servicePrincipals/$resource_sp_id/appRoleAssignedTo" "$body" >/dev/null 2>"$stderr_file"; then
      rm -f "$stderr_file"
      log_success "Created $label"
      return 0
    fi

    assignment_error="$(<"$stderr_file")"
    rm -f "$stderr_file"
    if app_role_assignment_error_is_retryable "$assignment_error"; then
      log INFO "$label creation not ready on attempt $attempt/12 yet; waiting for propagation"
      sleep 5
      continue
    fi

    die "Failed to create $label: ${assignment_error:-<no stderr>}"
  done

  die "$label could not be created after waiting for propagation"
}

wait_for_app_role_assignment() {
  local resource_sp_id="$1"
  local principal_id="${2:-$CLIENT_SERVICE_PRINCIPAL_ID}"
  local app_role_id="${3:-$NEW_RESOURCE_APP_ROLE_ID}"
  local label="${4:-sim-3p-client app role assignment}"
  local attempt assignment_id

  for attempt in 1 2 3; do
    assignment_id="$(find_matching_app_role_assignment_id "$resource_sp_id" "$principal_id" "$app_role_id")"
    if [[ -n "$assignment_id" ]]; then
      log_success "Verified $label on attempt $attempt: $assignment_id"
      printf '%s\n' "$assignment_id"
      return 0
    fi
    sleep 3
  done

  die "$label was not visible after creation"
}

find_service_principal_display_name_by_id() {
  local config_dir="$1"
  local service_principal_id="$2"

  graph_request_json \
    "$config_dir" \
    GET \
    "https://graph.microsoft.com/v1.0/servicePrincipals/$service_principal_id?\$select=displayName" \
    | jq -r '.displayName // empty'
}

ensure_replacement_app_role_assignments() {
  local old_resource_sp_id="$1"
  local new_resource_sp_id="$2"
  local assignments_json client_sp_id client_label

  assignments_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$old_resource_sp_id/appRoleAssignedTo")"
  mapfile -t client_sp_ids < <(
    jq -r '.value[] | select(.principalType == "ServicePrincipal") | .principalId' <<<"$assignments_json" | sort -u
  )

  for client_sp_id in "${client_sp_ids[@]}"; do
    client_label="$(find_service_principal_display_name_by_id "$CUSTOMER_CONFIG_DIR" "$client_sp_id")"
    [[ -n "$client_label" ]] || client_label="$client_sp_id"
    ensure_app_role_assignment \
      "$new_resource_sp_id" \
      "$client_sp_id" \
      "$NEW_RESOURCE_APP_ROLE_ID" \
      "customer $client_label -> sim-bd0c app role assignment"
    wait_for_app_role_assignment \
      "$new_resource_sp_id" \
      "$client_sp_id" \
      "$NEW_RESOURCE_APP_ROLE_ID" \
      "customer $client_label -> sim-bd0c app role assignment" \
      >/dev/null
  done
}

ensure_replacement_delegated_grants() {
  local old_resource_sp_id="$1"
  local new_resource_sp_id="$2"
  local grants_json client_sp_id client_label

  grants_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=resourceId eq '$old_resource_sp_id' and consentType eq 'AllPrincipals'")"
  mapfile -t client_sp_ids < <(
    jq -r '.value[]?.clientId // empty' <<<"$grants_json" | sort -u
  )

  for client_sp_id in "${client_sp_ids[@]}"; do
    client_label="$(find_service_principal_display_name_by_id "$CUSTOMER_CONFIG_DIR" "$client_sp_id")"
    [[ -n "$client_label" ]] || client_label="$client_sp_id"
    ensure_oauth2_permission_grant \
      "customer $client_label delegated sim-bd0c grant" \
      "$CUSTOMER_CONFIG_DIR" \
      "$client_sp_id" \
      "$new_resource_sp_id" \
      "$NEW_RESOURCE_SCOPE_VALUE"
  done
}

write_state_files() {
  local sim_dffa_app_object_id="$1"
  local sim_dffa_app_id="$2"
  local sim_dffa_home_sp_id="$3"
  local sim_dffa_customer_sp_id="$4"
  local sim_bd0c_app_object_id="$5"
  local sim_bd0c_app_id="$6"
  local sim_bd0c_home_sp_id="$7"
  local sim_3p_client_app_object_id="$8"
  local sim_3p_client_app_id="$9"
  local sim_3p_client_sp_id="${10}"
  local sim_3p_client_secret="${11}"
  local sim_3p_client_two_app_object_id="${12}"
  local sim_3p_client_two_app_id="${13}"
  local sim_3p_client_two_sp_id="${14}"
  local sim_3p_client_two_secret="${15}"
  local sim_3p_client_three_app_object_id="${16}"
  local sim_3p_client_three_app_id="${17}"
  local sim_3p_client_three_sp_id="${18}"
  local sim_3p_client_three_secret="${19}"
  local sim_dffa_identifier_uri="${20}"
  local sim_bd0c_identifier_uri="${21}"
  local force_tier2_fallback_json="false"
  local sim_3p_client_secret_stored_json="false"
  local sim_3p_client_two_secret_stored_json="false"
  local sim_3p_client_three_secret_stored_json="false"

  if internal_force_tier2_fallback_enabled; then
    force_tier2_fallback_json="true"
  fi
  [[ -n "$sim_3p_client_secret" ]] && sim_3p_client_secret_stored_json="true"
  [[ -n "$sim_3p_client_two_secret" ]] && sim_3p_client_two_secret_stored_json="true"
  [[ -n "$sim_3p_client_three_secret" ]] && sim_3p_client_three_secret_stored_json="true"

  mkdir -p "$STATE_DIR"
  STATE_JSON_FILE="$STATE_DIR/sim-state.json"
  STATE_ENV_FILE="$STATE_DIR/sim-state.env"

  jq -n \
    --arg generatedAt "$(timestamp)" \
    --arg stateDir "$STATE_DIR" \
    --arg stateEnvFile "$STATE_ENV_FILE" \
    --arg homeTenantId "$HOME_TENANT_ID" \
    --arg customerTenantId "$CUSTOMER_TENANT_ID" \
    --arg isvTenantId "$ISV_TENANT_ID" \
    --arg homeConfigDir "$HOME_CONFIG_DIR" \
    --arg customerConfigDir "$CUSTOMER_CONFIG_DIR" \
    --arg isvConfigDir "$ISV_CONFIG_DIR" \
    --arg simDffaName "$SIM_DFFA_NAME" \
    --arg simDffaAppObjectId "$sim_dffa_app_object_id" \
    --arg simDffaAppId "$sim_dffa_app_id" \
    --arg simDffaHomeSpId "$sim_dffa_home_sp_id" \
    --arg simDffaCustomerSpId "$sim_dffa_customer_sp_id" \
    --arg simBd0cName "$SIM_BD0C_NAME" \
    --arg simBd0cAppObjectId "$sim_bd0c_app_object_id" \
    --arg simBd0cAppId "$sim_bd0c_app_id" \
    --arg simBd0cHomeSpId "$sim_bd0c_home_sp_id" \
    --arg sim3pClientName "$SIM_3P_CLIENT_NAME" \
    --arg sim3pClientAppObjectId "$sim_3p_client_app_object_id" \
    --arg sim3pClientAppId "$sim_3p_client_app_id" \
    --arg sim3pClientSpId "$sim_3p_client_sp_id" \
    --argjson sim3pClientSecretStored "$sim_3p_client_secret_stored_json" \
    --arg sim3pClientTwoName "$SIM_3P_CLIENT_TWO_NAME" \
    --arg sim3pClientTwoAppObjectId "$sim_3p_client_two_app_object_id" \
    --arg sim3pClientTwoAppId "$sim_3p_client_two_app_id" \
    --arg sim3pClientTwoSpId "$sim_3p_client_two_sp_id" \
    --argjson sim3pClientTwoSecretStored "$sim_3p_client_two_secret_stored_json" \
    --arg sim3pClientThreeName "$SIM_3P_CLIENT_THREE_NAME" \
    --arg sim3pClientThreeAppObjectId "$sim_3p_client_three_app_object_id" \
    --arg sim3pClientThreeAppId "$sim_3p_client_three_app_id" \
    --arg sim3pClientThreeSpId "$sim_3p_client_three_sp_id" \
    --argjson sim3pClientThreeSecretStored "$sim_3p_client_three_secret_stored_json" \
    --arg dffaScopeId "$SIM_DFFA_SCOPE_ID" \
    --arg dffaScopeValue "$SIM_DFFA_SCOPE_VALUE" \
    --arg dffaRoleId "$SIM_DFFA_ROLE_ID" \
    --arg dffaRoleValue "$SIM_DFFA_ROLE_VALUE" \
    --arg bd0cScopeId "$SIM_BD0C_SCOPE_ID" \
    --arg bd0cScopeValue "$SIM_BD0C_SCOPE_VALUE" \
    --arg bd0cRoleId "$SIM_BD0C_ROLE_ID" \
    --arg bd0cRoleValue "$SIM_BD0C_ROLE_VALUE" \
    --arg azureCliAppId "$AZURE_CLI_APP_ID" \
    --arg simSharedIdentifierUri "$SIM_SHARED_IDENTIFIER_URI" \
    --arg simOldIdentifierUri "$SIM_OLD_IDENTIFIER_URI" \
    --arg simDffaIdentifierUri "$sim_dffa_identifier_uri" \
    --arg simBd0cIdentifierUri "$sim_bd0c_identifier_uri" \
    --argjson forceTier2Fallback "$force_tier2_fallback_json" \
    '{
      generatedAt: $generatedAt,
      stateDir: $stateDir,
      stateEnvFile: $stateEnvFile,
      internal: {
        forceTier2Fallback: $forceTier2Fallback
      },
      identifierUris: {
        shared: $simSharedIdentifierUri,
        old: $simOldIdentifierUri
      },
      tenants: {
        home: {
          tenantId: $homeTenantId,
          azureConfigDir: $homeConfigDir
        },
        customer: {
          tenantId: $customerTenantId,
          azureConfigDir: $customerConfigDir
        },
        isv: {
          tenantId: $isvTenantId,
          azureConfigDir: $isvConfigDir
        }
      },
      apps: {
        simDffa: {
          displayName: $simDffaName,
          appObjectId: $simDffaAppObjectId,
          appId: $simDffaAppId,
          homeServicePrincipalId: $simDffaHomeSpId,
          customerServicePrincipalId: $simDffaCustomerSpId,
          identifierUri: $simDffaIdentifierUri,
          scope: {
            id: $dffaScopeId,
            value: $dffaScopeValue
          },
          appRole: {
            id: $dffaRoleId,
            value: $dffaRoleValue
          }
        },
        simBd0c: {
          displayName: $simBd0cName,
          appObjectId: $simBd0cAppObjectId,
          appId: $simBd0cAppId,
          homeServicePrincipalId: $simBd0cHomeSpId,
          identifierUri: $simBd0cIdentifierUri,
          scope: {
            id: $bd0cScopeId,
            value: $bd0cScopeValue
          },
          appRole: {
            id: $bd0cRoleId,
            value: $bd0cRoleValue
          },
          preAuthorizedAppId: $azureCliAppId
        },
        sim3pClient: {
          displayName: $sim3pClientName,
          appObjectId: $sim3pClientAppObjectId,
          appId: $sim3pClientAppId,
          servicePrincipalId: $sim3pClientSpId,
          secretStoredInEnvFile: $sim3pClientSecretStored
        },
        sim3pClient2: {
          displayName: $sim3pClientTwoName,
          appObjectId: $sim3pClientTwoAppObjectId,
          appId: $sim3pClientTwoAppId,
          servicePrincipalId: $sim3pClientTwoSpId,
          secretStoredInEnvFile: $sim3pClientTwoSecretStored
        },
        sim3pClient3: {
          displayName: $sim3pClientThreeName,
          appObjectId: $sim3pClientThreeAppObjectId,
          appId: $sim3pClientThreeAppId,
          servicePrincipalId: $sim3pClientThreeSpId,
          secretStoredInEnvFile: $sim3pClientThreeSecretStored
        }
      }
    }' >"$STATE_JSON_FILE"

  umask 077
  : >"$STATE_ENV_FILE"
  write_env_var "$STATE_ENV_FILE" "STATE_JSON_FILE" "$STATE_JSON_FILE"
  write_env_var "$STATE_ENV_FILE" "HOME_TENANT_ID" "$HOME_TENANT_ID"
  write_env_var "$STATE_ENV_FILE" "CUSTOMER_TENANT_ID" "$CUSTOMER_TENANT_ID"
  write_env_var "$STATE_ENV_FILE" "ISV_TENANT_ID" "$ISV_TENANT_ID"
  write_env_var "$STATE_ENV_FILE" "HOME_CONFIG_DIR" "$HOME_CONFIG_DIR"
  write_env_var "$STATE_ENV_FILE" "CUSTOMER_CONFIG_DIR" "$CUSTOMER_CONFIG_DIR"
  write_env_var "$STATE_ENV_FILE" "ISV_CONFIG_DIR" "$ISV_CONFIG_DIR"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_IDENTIFIER_URI" "$SIM_SHARED_IDENTIFIER_URI"
  write_env_var "$STATE_ENV_FILE" "OLD_RESOURCE_IDENTIFIER_URI" "$SIM_OLD_IDENTIFIER_URI"
  write_env_var "$STATE_ENV_FILE" "OLD_RESOURCE_APP_ID" "$sim_dffa_app_id"
  write_env_var "$STATE_ENV_FILE" "OLD_RESOURCE_SERVICE_PRINCIPAL_ID" "$sim_dffa_customer_sp_id"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_APP_ID" "$sim_bd0c_app_id"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_SCOPE_ID" "$SIM_BD0C_SCOPE_ID"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_SCOPE_VALUE" "$SIM_BD0C_SCOPE_VALUE"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_APP_ROLE_ID" "$SIM_BD0C_ROLE_ID"
  write_env_var "$STATE_ENV_FILE" "NEW_RESOURCE_APP_ROLE_VALUE" "$SIM_BD0C_ROLE_VALUE"
  write_env_var "$STATE_ENV_FILE" "CLIENT_APP_OBJECT_ID" "$sim_3p_client_app_object_id"
  write_env_var "$STATE_ENV_FILE" "CLIENT_APP_ID" "$sim_3p_client_app_id"
  write_env_var "$STATE_ENV_FILE" "CLIENT_SERVICE_PRINCIPAL_ID" "$sim_3p_client_sp_id"
  write_env_var "$STATE_ENV_FILE" "CLIENT_SECRET" "$sim_3p_client_secret"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_APP_OBJECT_ID" "$sim_3p_client_app_object_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_APP_ID" "$sim_3p_client_app_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_SERVICE_PRINCIPAL_ID" "$sim_3p_client_sp_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_SECRET" "$sim_3p_client_secret"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_2_APP_OBJECT_ID" "$sim_3p_client_two_app_object_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_2_APP_ID" "$sim_3p_client_two_app_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_2_SERVICE_PRINCIPAL_ID" "$sim_3p_client_two_sp_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_2_SECRET" "$sim_3p_client_two_secret"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_3_APP_OBJECT_ID" "$sim_3p_client_three_app_object_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_3_APP_ID" "$sim_3p_client_three_app_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_3_SERVICE_PRINCIPAL_ID" "$sim_3p_client_three_sp_id"
  write_env_var "$STATE_ENV_FILE" "SIM_3P_CLIENT_3_SECRET" "$sim_3p_client_three_secret"
  if internal_force_tier2_fallback_enabled; then
    write_env_var "$STATE_ENV_FILE" "ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK" "true"
  fi
  chmod 600 "$STATE_ENV_FILE"
  source_shell_file "$STATE_ENV_FILE"

  log_success "Wrote runtime state files:"
  log INFO "  JSON: $STATE_JSON_FILE"
  log INFO "  ENV : $STATE_ENV_FILE (contains the client secret; keep private)"
}

required_application_json_by_display_name() {
  local config_dir="$1"
  local display_name="$2"
  local applications_json application_json

  applications_json="$(find_application_json_by_display_name "$config_dir" "$display_name")"
  application_json="$(jq -c '.value[0] // empty' <<<"$applications_json")"
  [[ -n "$application_json" ]] || die "Application not found by displayName '$display_name'"
  printf '%s\n' "$application_json"
}

patch_application_identifier_uris() {
  local config_dir="$1"
  local application_object_id="$2"
  local identifier_uris_json="$3"
  local body

  body="$(jq -cn --argjson identifierUris "$identifier_uris_json" '{identifierUris: $identifierUris}')"
  graph_request_json "$config_dir" PATCH "https://graph.microsoft.com/v1.0/applications/$application_object_id" "$body" >/dev/null
}

run_setup() {
  local sim_dffa_body sim_bd0c_body
  local sim_dffa_app_json sim_bd0c_app_json
  local sim_dffa_app_object_id sim_dffa_app_id sim_dffa_home_sp_id sim_dffa_customer_sp_id
  local sim_bd0c_app_object_id sim_bd0c_app_id sim_bd0c_home_sp_id
  local sim_3p_client_app_object_id="" sim_3p_client_app_id="" sim_3p_client_sp_id="" sim_3p_client_secret=""
  local sim_3p_client_two_app_object_id="" sim_3p_client_two_app_id="" sim_3p_client_two_sp_id="" sim_3p_client_two_secret=""
  local sim_3p_client_three_app_object_id="" sim_3p_client_three_app_id="" sim_3p_client_three_sp_id="" sim_3p_client_three_secret=""
  local verified_customer_dffa_sp_id azure_cli_customer_sp_id

  log_step "Validating toolchain and Azure CLI tenant contexts"
  require_command az
  require_command jq
  assert_tenant "Home" "$HOME_CONFIG_DIR" "$HOME_TENANT_ID"
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant "ISV" "$ISV_CONFIG_DIR" "$ISV_TENANT_ID"

  cleanup_previous_simulation_resources

  log_step "Creating home-tenant simulated retiring app: $SIM_DFFA_NAME"
  sim_dffa_body="$(build_sim_dffa_application_body)"
  sim_dffa_app_json="$(create_application "sim-dffa" "$HOME_CONFIG_DIR" "$sim_dffa_body")"
  sim_dffa_app_object_id="$(jq -r '.id' <<<"$sim_dffa_app_json")"
  sim_dffa_app_id="$(jq -r '.appId' <<<"$sim_dffa_app_json")"
  log_success "Created sim-dffa appId=$sim_dffa_app_id objectId=$sim_dffa_app_object_id"
  wait_for_application_by_app_id "sim-dffa" "$HOME_CONFIG_DIR" "$sim_dffa_app_id"

  log_step "Ensuring home-tenant service principal exists for sim-dffa"
  sim_dffa_home_sp_id="$(ensure_service_principal "home sim-dffa" "$HOME_CONFIG_DIR" "$HOME_TENANT_ID" "$sim_dffa_app_id")"
  sim_dffa_home_sp_id="$(wait_for_service_principal "home sim-dffa" "$HOME_CONFIG_DIR" "$sim_dffa_app_id")"

  log_step "Creating home-tenant simulated replacement app: $SIM_BD0C_NAME"
  sim_bd0c_body="$(build_sim_bd0c_application_body)"
  sim_bd0c_app_json="$(create_application "sim-bd0c" "$HOME_CONFIG_DIR" "$sim_bd0c_body")"
  sim_bd0c_app_object_id="$(jq -r '.id' <<<"$sim_bd0c_app_json")"
  sim_bd0c_app_id="$(jq -r '.appId' <<<"$sim_bd0c_app_json")"
  log_success "Created sim-bd0c appId=$sim_bd0c_app_id objectId=$sim_bd0c_app_object_id"
  wait_for_application_by_app_id "sim-bd0c" "$HOME_CONFIG_DIR" "$sim_bd0c_app_id"

  log_step "Ensuring home-tenant service principal exists for sim-bd0c"
  sim_bd0c_home_sp_id="$(ensure_service_principal "home sim-bd0c" "$HOME_CONFIG_DIR" "$HOME_TENANT_ID" "$sim_bd0c_app_id")"
  sim_bd0c_home_sp_id="$(wait_for_service_principal "home sim-bd0c" "$HOME_CONFIG_DIR" "$sim_bd0c_app_id")"

  log_step "Creating customer-tenant external service principal for sim-dffa"
  wait_for_service_principal_name_clear "customer sim-dffa shared uri" "$CUSTOMER_CONFIG_DIR" "$SIM_SHARED_IDENTIFIER_URI"
  sim_dffa_customer_sp_id="$(ensure_service_principal "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$sim_dffa_app_id")"
  verified_customer_dffa_sp_id="$(wait_for_service_principal "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$sim_dffa_app_id")"
  [[ "$sim_dffa_customer_sp_id" == "$verified_customer_dffa_sp_id" ]] || sim_dffa_customer_sp_id="$verified_customer_dffa_sp_id"
  wait_for_service_principal_readable "customer sim-dffa" "$CUSTOMER_CONFIG_DIR" "$sim_dffa_customer_sp_id"
  log_success "Created customer sim-dffa servicePrincipalId=$sim_dffa_customer_sp_id"

  log_step "Ensuring customer-tenant service principal exists for Microsoft Azure CLI"
  azure_cli_customer_sp_id="$(ensure_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$AZURE_CLI_APP_ID")"
  azure_cli_customer_sp_id="$(wait_for_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"

  log_step "Ensuring delegated grant exists so Azure CLI can request sim-dffa user_impersonation"
  ensure_oauth2_permission_grant \
    "customer Microsoft Azure CLI delegated sim-dffa grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$azure_cli_customer_sp_id" \
    "$sim_dffa_customer_sp_id" \
    "$SIM_DFFA_SCOPE_VALUE"

  if internal_skip_client_setup_enabled; then
    log INFO 'Internal skip-client-setup mode enabled; skipping sim-3p-client baseline application and service principal provisioning'
  else
    IFS=$'\t' read -r sim_3p_client_app_object_id sim_3p_client_app_id sim_3p_client_sp_id sim_3p_client_secret \
      < <(create_sim_3p_client "sim-3p-client" "$SIM_3P_CLIENT_NAME" "$sim_dffa_app_id" "$sim_dffa_customer_sp_id" 1)
    if internal_primary_client_only_enabled; then
      log INFO "Internal primary-client-only mode enabled; skipping sim-3p-client-2 and sim-3p-client-3 setup"
    else
      IFS=$'\t' read -r sim_3p_client_two_app_object_id sim_3p_client_two_app_id sim_3p_client_two_sp_id sim_3p_client_two_secret \
        < <(create_sim_3p_client "sim-3p-client-2" "$SIM_3P_CLIENT_TWO_NAME" "$sim_dffa_app_id" "$sim_dffa_customer_sp_id" 1)
      IFS=$'\t' read -r sim_3p_client_three_app_object_id sim_3p_client_three_app_id sim_3p_client_three_sp_id sim_3p_client_three_secret \
        < <(create_sim_3p_client "sim-3p-client-3" "$SIM_3P_CLIENT_THREE_NAME" "$sim_dffa_app_id" "$sim_dffa_customer_sp_id" 1)
    fi
  fi

  log_step "Persisting runtime state files"
  write_state_files \
    "$sim_dffa_app_object_id" \
    "$sim_dffa_app_id" \
    "$sim_dffa_home_sp_id" \
    "$sim_dffa_customer_sp_id" \
    "$sim_bd0c_app_object_id" \
    "$sim_bd0c_app_id" \
    "$sim_bd0c_home_sp_id" \
    "$sim_3p_client_app_object_id" \
    "$sim_3p_client_app_id" \
    "$sim_3p_client_sp_id" \
    "$sim_3p_client_secret" \
    "$sim_3p_client_two_app_object_id" \
    "$sim_3p_client_two_app_id" \
    "$sim_3p_client_two_sp_id" \
    "$sim_3p_client_two_secret" \
    "$sim_3p_client_three_app_object_id" \
    "$sim_3p_client_three_app_id" \
    "$sim_3p_client_three_sp_id" \
    "$sim_3p_client_three_secret" \
    "$SIM_DFFA_IDENTIFIER_URI" \
    ""

  log_step "Verifying baseline M1 expectations"
  local customer_sp_summary
  customer_sp_summary="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sim_dffa_customer_sp_id")"
  jq -e --arg expected "$SIM_SHARED_IDENTIFIER_URI" '.servicePrincipalNames // [] | index($expected) != null' <<<"$customer_sp_summary" >/dev/null \
    || die "Customer sim-dffa service principal is missing $SIM_SHARED_IDENTIFIER_URI in servicePrincipalNames"
  jq -e '.value? // empty' "$STATE_JSON_FILE" >/dev/null 2>&1 || true
  log_success "Verified customer sim-dffa servicePrincipalNames contains $SIM_SHARED_IDENTIFIER_URI"
  log_success "Verified runtime state files exist and are ready for later milestones"

  log INFO "SUMMARY: setup complete"
  log INFO "  sim-dffa appId=$sim_dffa_app_id"
  log INFO "  sim-bd0c appId=$sim_bd0c_app_id"
  if internal_skip_client_setup_enabled; then
    log INFO "  sim-3p-client setup skipped by ADME_SIM_INTERNAL_SKIP_CLIENT_SETUP"
  else
    log INFO "  sim-3p-client appId=$sim_3p_client_app_id"
    log INFO "  sim-3p-client-2 appId=$sim_3p_client_two_app_id"
    log INFO "  sim-3p-client-3 appId=$sim_3p_client_three_app_id"
  fi
  log INFO "  customer sim-dffa servicePrincipalId=$sim_dffa_customer_sp_id"
  log INFO "  state files written to $STATE_DIR"
}

run_update_1p_apps() {
  local existing_state_env_file
  local sim_dffa_app_json sim_bd0c_app_json sim_3p_client_app_json sim_3p_client_two_app_json sim_3p_client_three_app_json
  local sim_dffa_app_object_id sim_dffa_app_id sim_dffa_home_sp_id sim_dffa_customer_sp_id
  local sim_bd0c_app_object_id sim_bd0c_app_id sim_bd0c_home_sp_id
  local sim_3p_client_app_object_id sim_3p_client_app_id sim_3p_client_sp_id sim_3p_client_secret
  local sim_3p_client_two_app_object_id sim_3p_client_two_app_id sim_3p_client_two_sp_id sim_3p_client_two_secret
  local sim_3p_client_three_app_object_id sim_3p_client_three_app_id sim_3p_client_three_sp_id sim_3p_client_three_secret
  local azure_cli_customer_sp_id
  local before_dffa_identifier_uris before_bd0c_identifier_uris
  local after_dffa_app_json after_bd0c_app_json
  local after_dffa_identifier_uris after_bd0c_identifier_uris
  local customer_dffa_sp_json customer_dffa_sp_names

  log_step "Validating toolchain, tenant contexts, and runtime state before update"
  require_command az
  require_command jq
  assert_tenant "Home" "$HOME_CONFIG_DIR" "$HOME_TENANT_ID"
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"

  existing_state_env_file="$STATE_DIR/sim-state.env"
  [[ -f "$existing_state_env_file" ]] || die "Expected runtime state file not found: $existing_state_env_file"
  source_shell_file "$existing_state_env_file"
  sim_3p_client_secret="${SIM_3P_CLIENT_SECRET:-${CLIENT_SECRET:-}}"
  sim_3p_client_two_secret="${SIM_3P_CLIENT_2_SECRET:-}"
  sim_3p_client_three_secret="${SIM_3P_CLIENT_3_SECRET:-}"
  if ! internal_skip_client_setup_enabled; then
    [[ -n "$sim_3p_client_secret" ]] || die "CLIENT_SECRET missing from $existing_state_env_file"
  fi

  sim_dffa_app_json="$(required_application_json_by_display_name "$HOME_CONFIG_DIR" "$SIM_DFFA_NAME")"
  sim_bd0c_app_json="$(required_application_json_by_display_name "$HOME_CONFIG_DIR" "$SIM_BD0C_NAME")"

  sim_dffa_app_object_id="$(jq -r '.id' <<<"$sim_dffa_app_json")"
  sim_dffa_app_id="$(jq -r '.appId' <<<"$sim_dffa_app_json")"
  sim_bd0c_app_object_id="$(jq -r '.id' <<<"$sim_bd0c_app_json")"
  sim_bd0c_app_id="$(jq -r '.appId' <<<"$sim_bd0c_app_json")"

  sim_dffa_home_sp_id="$(find_service_principal_id_by_app_id "$HOME_CONFIG_DIR" "$sim_dffa_app_id")"
  sim_bd0c_home_sp_id="$(find_service_principal_id_by_app_id "$HOME_CONFIG_DIR" "$sim_bd0c_app_id")"
  sim_dffa_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$sim_dffa_app_id")"
  azure_cli_customer_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"

  [[ -n "$sim_dffa_home_sp_id" ]] || die "Home sim-dffa service principal not found"
  [[ -n "$sim_bd0c_home_sp_id" ]] || die "Home sim-bd0c service principal not found"
  [[ -n "$sim_dffa_customer_sp_id" ]] || die "Customer sim-dffa service principal not found"
  [[ -n "$azure_cli_customer_sp_id" ]] || die "Customer Microsoft Azure CLI service principal not found"

  if internal_skip_client_setup_enabled; then
    sim_3p_client_app_object_id="${SIM_3P_CLIENT_APP_OBJECT_ID:-}"
    sim_3p_client_app_id="${SIM_3P_CLIENT_APP_ID:-}"
    sim_3p_client_sp_id="${SIM_3P_CLIENT_SERVICE_PRINCIPAL_ID:-}"
    sim_3p_client_two_app_object_id="${SIM_3P_CLIENT_2_APP_OBJECT_ID:-}"
    sim_3p_client_two_app_id="${SIM_3P_CLIENT_2_APP_ID:-}"
    sim_3p_client_two_sp_id="${SIM_3P_CLIENT_2_SERVICE_PRINCIPAL_ID:-}"
    sim_3p_client_three_app_object_id="${SIM_3P_CLIENT_3_APP_OBJECT_ID:-}"
    sim_3p_client_three_app_id="${SIM_3P_CLIENT_3_APP_ID:-}"
    sim_3p_client_three_sp_id="${SIM_3P_CLIENT_3_SERVICE_PRINCIPAL_ID:-}"
  else
    sim_3p_client_app_json="$(required_application_json_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_NAME")"
    sim_3p_client_two_app_json="$(required_application_json_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_TWO_NAME")"
    sim_3p_client_three_app_json="$(required_application_json_by_display_name "$CUSTOMER_CONFIG_DIR" "$SIM_3P_CLIENT_THREE_NAME")"
    sim_3p_client_app_object_id="$(jq -r '.id' <<<"$sim_3p_client_app_json")"
    sim_3p_client_app_id="$(jq -r '.appId' <<<"$sim_3p_client_app_json")"
    sim_3p_client_two_app_object_id="$(jq -r '.id' <<<"$sim_3p_client_two_app_json")"
    sim_3p_client_two_app_id="$(jq -r '.appId' <<<"$sim_3p_client_two_app_json")"
    sim_3p_client_three_app_object_id="$(jq -r '.id' <<<"$sim_3p_client_three_app_json")"
    sim_3p_client_three_app_id="$(jq -r '.appId' <<<"$sim_3p_client_three_app_json")"
    sim_3p_client_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$sim_3p_client_app_id")"
    sim_3p_client_two_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$sim_3p_client_two_app_id")"
    sim_3p_client_three_sp_id="$(find_service_principal_id_by_app_id "$CUSTOMER_CONFIG_DIR" "$sim_3p_client_three_app_id")"
    [[ -n "$sim_3p_client_sp_id" ]] || die "Customer sim-3p-client service principal not found"
    [[ -n "$sim_3p_client_two_sp_id" ]] || die "Customer sim-3p-client-2 service principal not found"
    [[ -n "$sim_3p_client_three_sp_id" ]] || die "Customer sim-3p-client-3 service principal not found"
  fi

  before_dffa_identifier_uris="$(jq -c '.identifierUris // []' <<<"$sim_dffa_app_json")"
  before_bd0c_identifier_uris="$(jq -c '.identifierUris // []' <<<"$sim_bd0c_app_json")"
  log INFO "Before update: sim-dffa identifierUris=$before_dffa_identifier_uris"
  log INFO "Before update: sim-bd0c identifierUris=$before_bd0c_identifier_uris"

  log_step "Moving the shared identifierUri off sim-dffa"
  patch_application_identifier_uris "$HOME_CONFIG_DIR" "$sim_dffa_app_object_id" "$(jq -cn --arg uri "$SIM_OLD_IDENTIFIER_URI" '[$uri]')"
  after_dffa_app_json="$(required_application_json_by_display_name "$HOME_CONFIG_DIR" "$SIM_DFFA_NAME")"
  after_dffa_identifier_uris="$(jq -c '.identifierUris // []' <<<"$after_dffa_app_json")"
  log INFO "After sim-dffa patch: identifierUris=$after_dffa_identifier_uris"
  jq -e --arg old "$SIM_OLD_IDENTIFIER_URI" --arg shared "$SIM_SHARED_IDENTIFIER_URI" '
    (.identifierUris // []) | index($old) != null and index($shared) == null
  ' <<<"$after_dffa_app_json" >/dev/null || die "sim-dffa identifierUris were not updated to only $SIM_OLD_IDENTIFIER_URI"
  log_success "Verified sim-dffa now owns $SIM_OLD_IDENTIFIER_URI and no longer owns $SIM_SHARED_IDENTIFIER_URI"

  log_step "Assigning the shared identifierUri to sim-bd0c"
  patch_application_identifier_uris "$HOME_CONFIG_DIR" "$sim_bd0c_app_object_id" "$(jq -cn --arg uri "$SIM_SHARED_IDENTIFIER_URI" '[$uri]')"
  after_bd0c_app_json="$(required_application_json_by_display_name "$HOME_CONFIG_DIR" "$SIM_BD0C_NAME")"
  after_bd0c_identifier_uris="$(jq -c '.identifierUris // []' <<<"$after_bd0c_app_json")"
  log INFO "After sim-bd0c patch: identifierUris=$after_bd0c_identifier_uris"
  jq -e --arg shared "$SIM_SHARED_IDENTIFIER_URI" '
    (.identifierUris // []) | index($shared) != null
  ' <<<"$after_bd0c_app_json" >/dev/null || die "sim-bd0c identifierUris do not include $SIM_SHARED_IDENTIFIER_URI"
  log_success "Verified sim-bd0c now owns $SIM_SHARED_IDENTIFIER_URI"

  if internal_force_tier2_fallback_enabled; then
    log_warn "INTERNAL SIMULATION MODE: leaving customer sim-dffa servicePrincipalNames stale so migrate adme-audience can exercise direct servicePrincipalNames repair."
    customer_dffa_sp_json="$(graph_request_json "$CUSTOMER_CONFIG_DIR" GET "https://graph.microsoft.com/v1.0/servicePrincipals/$sim_dffa_customer_sp_id")"
  else
    if ! customer_dffa_sp_json="$(
      refresh_service_principal_names \
        "customer sim-dffa" \
        "$CUSTOMER_CONFIG_DIR" \
        "$sim_dffa_customer_sp_id" \
        "$SIM_OLD_IDENTIFIER_URI" \
        "$SIM_SHARED_IDENTIFIER_URI"
    )"; then
      IFS=$'\t' read -r sim_dffa_customer_sp_id customer_dffa_sp_json < <(
        recreate_customer_sim_dffa_service_principal \
          "$sim_dffa_app_id" \
          "$azure_cli_customer_sp_id" \
          "$sim_3p_client_sp_id" \
          "$sim_3p_client_two_sp_id" \
          "$sim_3p_client_three_sp_id"
      )
    fi
  fi
  customer_dffa_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$customer_dffa_sp_json")"
  if internal_force_tier2_fallback_enabled; then
    log_step "Verifying the internal direct-repair fixture keeps customer sim-dffa stale"
    log INFO "Customer sim-dffa servicePrincipalNames intentionally left stale after home-tenant update: $customer_dffa_sp_names"
    jq -e --arg shared "$SIM_SHARED_IDENTIFIER_URI" --arg old "$SIM_OLD_IDENTIFIER_URI" '
      (.servicePrincipalNames // []) | index($shared) != null and index($old) == null
    ' <<<"$customer_dffa_sp_json" >/dev/null || die "Internal direct-repair fixture expected customer sim-dffa to still advertise $SIM_SHARED_IDENTIFIER_URI and not $SIM_OLD_IDENTIFIER_URI"
    log_success "Verified customer sim-dffa remains stale for internal direct-repair fallback testing"
  else
    log_step "Verifying the refreshed customer sim-dffa service principal now advertises the old identifier only"
    log INFO "Customer sim-dffa servicePrincipalNames after home-tenant update: $customer_dffa_sp_names"
    jq -e --arg shared "$SIM_SHARED_IDENTIFIER_URI" --arg old "$SIM_OLD_IDENTIFIER_URI" '
      (.servicePrincipalNames // []) | index($old) != null and index($shared) == null
    ' <<<"$customer_dffa_sp_json" >/dev/null || die "Customer sim-dffa service principal did not refresh to $SIM_OLD_IDENTIFIER_URI after home-tenant update"
    log_success "Verified customer sim-dffa now advertises $SIM_OLD_IDENTIFIER_URI and not $SIM_SHARED_IDENTIFIER_URI"
  fi

  log_step "Refreshing runtime state files after the identifierUri move"
  write_state_files \
    "$sim_dffa_app_object_id" \
    "$sim_dffa_app_id" \
    "$sim_dffa_home_sp_id" \
    "$sim_dffa_customer_sp_id" \
    "$sim_bd0c_app_object_id" \
    "$sim_bd0c_app_id" \
    "$sim_bd0c_home_sp_id" \
    "$sim_3p_client_app_object_id" \
    "$sim_3p_client_app_id" \
    "$sim_3p_client_sp_id" \
    "$sim_3p_client_secret" \
    "$sim_3p_client_two_app_object_id" \
    "$sim_3p_client_two_app_id" \
    "$sim_3p_client_two_sp_id" \
    "$sim_3p_client_two_secret" \
    "$sim_3p_client_three_app_object_id" \
    "$sim_3p_client_three_app_id" \
    "$sim_3p_client_three_sp_id" \
    "$sim_3p_client_three_secret" \
    "$SIM_OLD_IDENTIFIER_URI" \
    "$SIM_SHARED_IDENTIFIER_URI"

  log INFO "SUMMARY: update-1p-apps complete"
  log INFO "  sim-dffa appId=$sim_dffa_app_id identifierUri=$SIM_OLD_IDENTIFIER_URI"
  log INFO "  sim-bd0c appId=$sim_bd0c_app_id identifierUri=$SIM_SHARED_IDENTIFIER_URI"
  if internal_force_tier2_fallback_enabled; then
    log INFO "  customer sim-dffa servicePrincipalId=$sim_dffa_customer_sp_id intentionally left stale for internal direct-repair fallback testing"
  else
    log INFO "  customer sim-dffa servicePrincipalId=$sim_dffa_customer_sp_id refreshed to $SIM_OLD_IDENTIFIER_URI"
  fi
  log INFO "  state files updated in $STATE_DIR"
}

run_grant() {
  local sim_bd0c_customer_sp_id azure_cli_customer_sp_id old_resource_sp_id

  log_step "Validating toolchain, tenant contexts, and runtime state before re-granting customer permissions"
  require_command az
  require_command jq
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  load_runtime_state

  [[ -n "${NEW_RESOURCE_APP_ID:-}" ]] || die "NEW_RESOURCE_APP_ID missing from $STATE_DIR/sim-state.env"
  [[ -n "${CLIENT_SERVICE_PRINCIPAL_ID:-}" ]] || die "CLIENT_SERVICE_PRINCIPAL_ID missing from $STATE_DIR/sim-state.env"

  old_resource_sp_id="${OLD_RESOURCE_SERVICE_PRINCIPAL_ID:-}"
  [[ -n "$old_resource_sp_id" ]] || die "OLD_RESOURCE_SERVICE_PRINCIPAL_ID missing from $STATE_DIR/sim-state.env"

  sim_bd0c_customer_sp_id="$(ensure_service_principal "customer sim-bd0c" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$NEW_RESOURCE_APP_ID")"
  sim_bd0c_customer_sp_id="$(wait_for_service_principal "customer sim-bd0c" "$CUSTOMER_CONFIG_DIR" "$NEW_RESOURCE_APP_ID")"

  log_step "Ensuring the sim-bd0c app-role assignments exist for all old resource (dffa) clients"
  ensure_replacement_app_role_assignments "$old_resource_sp_id" "$sim_bd0c_customer_sp_id"

  log_step "Ensuring delegated access exists for all old resource (dffa) clients"
  ensure_replacement_delegated_grants "$old_resource_sp_id" "$sim_bd0c_customer_sp_id"

  log_step "Ensuring delegated Azure CLI access exists for sim-bd0c"
  azure_cli_customer_sp_id="$(ensure_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$AZURE_CLI_APP_ID")"
  azure_cli_customer_sp_id="$(wait_for_service_principal "customer Microsoft Azure CLI" "$CUSTOMER_CONFIG_DIR" "$AZURE_CLI_APP_ID")"
  ensure_oauth2_permission_grant \
    "customer Microsoft Azure CLI delegated sim-bd0c grant" \
    "$CUSTOMER_CONFIG_DIR" \
    "$azure_cli_customer_sp_id" \
    "$sim_bd0c_customer_sp_id" \
    "$NEW_RESOURCE_SCOPE_VALUE"

  log INFO "SUMMARY: grant complete"
  log INFO "  sim-bd0c customer servicePrincipalId=$sim_bd0c_customer_sp_id"
  log INFO "  delegated scope=$NEW_RESOURCE_SCOPE_VALUE"
}

run_external_mta() {
  local external_body external_app_json external_app_object_id external_app_id
  local external_isv_sp_id external_customer_sp_id external_customer_sp_json external_customer_sp_names
  local previous_external_mta_app_id old_resource_sp_id

  log_step "Validating toolchain, tenant contexts, and runtime state before provisioning external MTA"
  require_command az
  require_command jq
  assert_tenant "ISV" "$ISV_CONFIG_DIR" "$ISV_TENANT_ID"
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  load_runtime_state

  old_resource_sp_id="${OLD_RESOURCE_SERVICE_PRINCIPAL_ID:-}"
  [[ -n "${OLD_RESOURCE_APP_ID:-}" ]] || die "OLD_RESOURCE_APP_ID missing from $STATE_DIR/sim-state.env"
  [[ -n "$old_resource_sp_id" ]] || die "OLD_RESOURCE_SERVICE_PRINCIPAL_ID missing from $STATE_DIR/sim-state.env"

  log_step "Removing any existing external MTA simulation resources"
  previous_external_mta_app_id="$(find_application_app_id_by_display_name "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME")"
  delete_service_principal_if_exists_by_app_id "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$previous_external_mta_app_id"
  delete_service_principal_if_exists_by_app_id "isv sim-external-mta" "$ISV_CONFIG_DIR" "$previous_external_mta_app_id"
  delete_service_principals_if_exists_by_display_name "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"
  delete_service_principals_if_exists_by_display_name "isv sim-external-mta" "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"
  delete_application_if_exists "isv sim-external-mta" "$ISV_CONFIG_DIR" "$SIM_EXTERNAL_MTA_NAME"

  log_step "Creating ISV external MTA application: $SIM_EXTERNAL_MTA_NAME"
  external_body="$(build_sim_external_mta_application_body "$SIM_EXTERNAL_MTA_NAME" "$OLD_RESOURCE_APP_ID")"
  external_app_json="$(create_application "isv sim-external-mta" "$ISV_CONFIG_DIR" "$external_body")"
  external_app_object_id="$(jq -r '.id' <<<"$external_app_json")"
  external_app_id="$(jq -r '.appId' <<<"$external_app_json")"
  log_success "Created sim-external-mta appId=$external_app_id objectId=$external_app_object_id"

  log_step "Ensuring ISV service principal exists for sim-external-mta"
  external_isv_sp_id="$(ensure_service_principal "isv sim-external-mta" "$ISV_CONFIG_DIR" "$ISV_TENANT_ID" "$external_app_id")"
  external_isv_sp_id="$(wait_for_service_principal "isv sim-external-mta" "$ISV_CONFIG_DIR" "$external_app_id")"

  log_step "Ensuring customer service principal exists for sim-external-mta"
  external_customer_sp_id="$(ensure_service_principal "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID" "$external_app_id")"
  external_customer_sp_id="$(wait_for_service_principal "customer sim-external-mta" "$CUSTOMER_CONFIG_DIR" "$external_app_id")"
  external_customer_sp_json="$(
    refresh_service_principal_names \
      "customer sim-external-mta" \
      "$CUSTOMER_CONFIG_DIR" \
      "$external_customer_sp_id" \
      "$SIM_EXTERNAL_MTA_IDENTIFIER_URI"
  )"
  external_customer_sp_names="$(jq -c '.servicePrincipalNames // []' <<<"$external_customer_sp_json")"
  log_success "Verified customer sim-external-mta servicePrincipalNames: $external_customer_sp_names"

  log_step "Ensuring the external MTA keeps the old resource (dffa) app-role assignment in the customer tenant"
  ensure_app_role_assignment \
    "$old_resource_sp_id" \
    "$external_customer_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-external-mta -> sim-dffa app role assignment"
  wait_for_app_role_assignment \
    "$old_resource_sp_id" \
    "$external_customer_sp_id" \
    "$SIM_DFFA_ROLE_ID" \
    "customer sim-external-mta -> sim-dffa app role assignment" \
    >/dev/null

  log INFO "SUMMARY: external-mta complete"
  log INFO "  external appId=$external_app_id"
  log INFO "  isv servicePrincipalId=$external_isv_sp_id"
  log INFO "  customer servicePrincipalId=$external_customer_sp_id"
}

run_cleanup() {
  log_step "Validating toolchain and tenant contexts before deleting simulation resources"
  require_command az
  require_command jq
  assert_tenant "Home" "$HOME_CONFIG_DIR" "$HOME_TENANT_ID"
  assert_tenant "Customer" "$CUSTOMER_CONFIG_DIR" "$CUSTOMER_TENANT_ID"
  assert_tenant "ISV" "$ISV_CONFIG_DIR" "$ISV_TENANT_ID"

  cleanup_previous_simulation_resources

  log_step "Removing saved runtime state artifacts"
  rm -f "$STATE_DIR/sim-state.env" "$STATE_DIR/sim-state.json"
  rmdir "$STATE_DIR" 2>/dev/null || true
  log_success "Removed saved runtime state artifacts from $STATE_DIR"

  log INFO "SUMMARY: cleanup complete"
  log INFO "  simulation resources removed from home, customer, and ISV tenants"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?Missing value for --config}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:?Missing value for --state-dir}"
      shift 2
      ;;
    --home-config-dir)
      HOME_CONFIG_DIR="${2:?Missing value for --home-config-dir}"
      shift 2
      ;;
    --customer-config-dir)
      CUSTOMER_CONFIG_DIR="${2:?Missing value for --customer-config-dir}"
      shift 2
      ;;
    --isv-config-dir)
      ISV_CONFIG_DIR="${2:?Missing value for --isv-config-dir}"
      shift 2
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

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || {
  usage
  exit 1
}
shift || true

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
  source_shell_file "$CONFIG_FILE"
fi

HOME_TENANT_ID="${HOME_TENANT_ID:-$HOME_TENANT_ID_DEFAULT}"
CUSTOMER_TENANT_ID="${CUSTOMER_TENANT_ID:-$CUSTOMER_TENANT_ID_DEFAULT}"
ISV_TENANT_ID="${ISV_TENANT_ID:-$ISV_TENANT_ID_DEFAULT}"
HOME_CONFIG_DIR="${HOME_CONFIG_DIR:-$HOME_CONFIG_DIR_DEFAULT}"
CUSTOMER_CONFIG_DIR="${CUSTOMER_CONFIG_DIR:-$CUSTOMER_CONFIG_DIR_DEFAULT}"
ISV_CONFIG_DIR="${ISV_CONFIG_DIR:-$ISV_CONFIG_DIR_DEFAULT}"
SIM_DFFA_NAME="${SIM_DFFA_NAME:-$SIM_DFFA_NAME_DEFAULT}"
SIM_BD0C_NAME="${SIM_BD0C_NAME:-$SIM_BD0C_NAME_DEFAULT}"
SIM_3P_CLIENT_NAME="${SIM_3P_CLIENT_NAME:-$SIM_3P_CLIENT_NAME_DEFAULT}"
SIM_3P_CLIENT_TWO_NAME="${SIM_3P_CLIENT_TWO_NAME:-$SIM_3P_CLIENT_TWO_NAME_DEFAULT}"
SIM_3P_CLIENT_THREE_NAME="${SIM_3P_CLIENT_THREE_NAME:-$SIM_3P_CLIENT_THREE_NAME_DEFAULT}"
SIM_EXTERNAL_MTA_NAME="${SIM_EXTERNAL_MTA_NAME:-$SIM_EXTERNAL_MTA_NAME_DEFAULT}"

case "$COMMAND" in
  setup)
    run_setup
    ;;
  update-1p-apps)
    run_update_1p_apps
    ;;
  grant)
    run_grant
    ;;
  external-mta)
    run_external_mta
    ;;
  cleanup)
    run_cleanup
    ;;
  *)
    usage
    die "Unknown command: $COMMAND"
    ;;
esac
