#!/usr/bin/env bash

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

usage() {
  cat <<EOF
Usage:
  source $SCRIPT_NAME --display-name name [inventory-json ...]
  eval "\$(./$SCRIPT_NAME --display-name name [inventory-json ...])"

Description:
  Select one customer-owned client from 3p-inventory JSON by exact displayName
  and set variables that identify the selected client app.

  Use CLIENT_APP_ID with:

    ./adme-entra-migration.sh migrate api-permissions --client-id "\$CLIENT_APP_ID"

  If sourced, the variables are exported into the current shell. If executed,
  shell export commands are printed to stdout for use with eval.

Options:
  -d, --display-name name  Exact displayName to select.
  -h, --help               Show this help text.

Arguments:
  inventory-json           Optional inventory files. Defaults to
                           inventory-output/3p-inventory-*.json.

Examples:
  source ./$SCRIPT_NAME --display-name "adme-dffa-client"
  ./adme-entra-migration.sh migrate api-permissions --client-id "\$CLIENT_APP_ID"

  eval "\$(./$SCRIPT_NAME --display-name 'adme-dffa-client')"
  ./adme-entra-migration.sh migrate api-permissions --client-id "\$CLIENT_APP_ID"
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    die "Required command not found: $1"
    return 1
  }
}

shell_export_line() {
  local name="$1"
  local value="$2"

  printf 'export %s=%q\n' "$name" "$value"
}

summary_path_for_inventory_file() {
  local inventory_file="$1"
  local inventory_dir inventory_name summary_name

  inventory_dir="$(dirname -- "$inventory_file")"
  inventory_name="$(basename -- "$inventory_file")"
  case "$inventory_name" in
    3p-inventory-*.json)
      summary_name="inventory-summary-${inventory_name#3p-inventory-}"
      printf '%s/%s\n' "$inventory_dir" "$summary_name"
      ;;
    *)
      return 1
      ;;
  esac
}

current_azure_cli_tenant_id() {
  command -v az >/dev/null 2>&1 || return 1
  az account show --query tenantId -o tsv 2>/dev/null
}

current_tenant_graph_object_json() {
  local url="$1"

  az rest --method GET --url "$url" -o json 2>/dev/null
}

print_login_status() {
  local prefix="$1"
  local inventory_tenant_id="$2"
  local current_tenant_id="$3"
  local app_display_name="$4"
  local sp_display_name="$5"

  if [[ -n "$inventory_tenant_id" ]]; then
    printf '%sInventory tenantId: %s\n' "$prefix" "$inventory_tenant_id"
  else
    printf '%sInventory tenantId: <unknown; matching inventory-summary file not found>\n' "$prefix"
  fi

  if [[ -n "$current_tenant_id" ]]; then
    printf '%sCurrent Azure CLI tenantId: %s\n' "$prefix" "$current_tenant_id"
  else
    printf '%sCurrent Azure CLI tenantId: <unavailable; az is missing or not logged in>\n' "$prefix"
  fi

  if [[ -n "$inventory_tenant_id" && -n "$current_tenant_id" ]]; then
    if [[ "$inventory_tenant_id" == "$current_tenant_id" ]]; then
      printf '%sAzure CLI tenant matches inventory: yes\n' "$prefix"
    else
      printf '%sAzure CLI tenant matches inventory: no\n' "$prefix"
    fi
  else
    printf '%sAzure CLI tenant matches inventory: unknown\n' "$prefix"
  fi

  printf '%sCurrent tenant App Registration check: found (%s)\n' "$prefix" "$app_display_name"
  printf '%sCurrent tenant Service Principal check: found (%s)\n' "$prefix" "$sp_display_name"
}

verify_current_tenant_objects() {
  local current_tenant_id="$1"
  local expected_app_id="$2"
  local app_object_id="$3"
  local service_principal_id="$4"
  local app_json sp_json app_lookup_app_id sp_lookup_app_id
  local app_display_name sp_display_name

  [[ -n "$current_tenant_id" ]] || {
    die "Azure CLI is unavailable or not logged in. Run az login --tenant <customer-tenant-id> before selecting migration variables."
    return 1
  }

  if ! app_json="$(current_tenant_graph_object_json "https://graph.microsoft.com/v1.0/applications/$app_object_id?\$select=id,appId,displayName")"; then
    die "Current Azure CLI tenant $current_tenant_id cannot find App Registration object $app_object_id from inventory. Sign in to the tenant that owns the selected client app."
    return 1
  fi

  app_lookup_app_id="$(jq -r '.appId // empty' <<<"$app_json")" || return 1
  app_display_name="$(jq -r '.displayName // "<unnamed>"' <<<"$app_json")" || return 1
  if [[ "$app_lookup_app_id" != "$expected_app_id" ]]; then
    die "Current tenant App Registration object $app_object_id has appId '$app_lookup_app_id', expected '$expected_app_id' from inventory."
    return 1
  fi

  if ! sp_json="$(current_tenant_graph_object_json "https://graph.microsoft.com/v1.0/servicePrincipals/$service_principal_id?\$select=id,appId,displayName")"; then
    die "Current Azure CLI tenant $current_tenant_id cannot find Service Principal object $service_principal_id from inventory. Sign in to the tenant that contains the selected enterprise app."
    return 1
  fi

  sp_lookup_app_id="$(jq -r '.appId // empty' <<<"$sp_json")" || return 1
  sp_display_name="$(jq -r '.displayName // "<unnamed>"' <<<"$sp_json")" || return 1
  if [[ "$sp_lookup_app_id" != "$expected_app_id" ]]; then
    die "Current tenant Service Principal object $service_principal_id has appId '$sp_lookup_app_id', expected '$expected_app_id' from inventory."
    return 1
  fi

  printf '%s\t%s\n' "$app_display_name" "$sp_display_name"
}

set_client_env_from_inventory_main() {
  local display_name=""
  local selected_json match_count
  local client_app_id client_app_object_id client_service_principal_id selected_display_name
  local inventory_tenant_ids_json inventory_tenant_count inventory_tenant_id current_tenant_id
  local current_object_names app_display_name sp_display_name
  local nullglob_was_set=0
  local inventory_file summary_file file_tenant_id
  local -a inventory_files=()
  local -a inventory_tenant_ids=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--display-name)
        [[ $# -ge 2 ]] || {
          die "$1 requires a value"
          return 1
        }
        display_name="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        inventory_files+=("$@")
        break
        ;;
      -*)
        die "Unknown option: $1"
        return 1
        ;;
      *)
        inventory_files+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$display_name" ]] || {
    die "--display-name is required"
    return 1
  }
  require_command jq || return 1

  if [[ ${#inventory_files[@]} -eq 0 ]]; then
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    inventory_files=(inventory-output/3p-inventory-*.json)
    if [[ ${#inventory_files[@]} -eq 0 ]]; then
      inventory_files=("$SCRIPT_DIR"/inventory-output/3p-inventory-*.json)
    fi
    if [[ "$nullglob_was_set" -eq 1 ]]; then
      shopt -s nullglob
    else
      shopt -u nullglob
    fi
  fi

  [[ ${#inventory_files[@]} -gt 0 ]] || {
    die "No inventory files matched. Run adme-entra-inventory.sh first or pass a 3p-inventory JSON file."
    return 1
  }

  for inventory_file in "${inventory_files[@]}"; do
    [[ -f "$inventory_file" ]] || {
      die "Inventory file not found: $inventory_file"
      return 1
    }
  done

  if ! selected_json="$(
    jq -c -s --arg displayName "$display_name" '
      flatten
      | map(select(.ownership == "customer" and .displayName == $displayName))
      | unique_by(.appId, .applicationObjectId, .servicePrincipalId)
    ' "${inventory_files[@]}"
  )"; then
    die "Failed to read inventory JSON"
    return 1
  fi

  match_count="$(jq -r 'length' <<<"$selected_json")" || {
    die "Failed to count matching inventory entries"
    return 1
  }
  case "$match_count" in
    0)
      die "No customer-owned inventory entry found with displayName '$display_name'"
      return 1
      ;;
    1)
      ;;
    *)
      printf 'ERROR: Found %s unique customer-owned entries with displayName %s. Pass one inventory file or disambiguate the app manually.\n' "$match_count" "$display_name" >&2
      jq -r '.[] | "  displayName=\(.displayName) appId=\(.appId) applicationObjectId=\(.applicationObjectId) servicePrincipalId=\(.servicePrincipalId)"' <<<"$selected_json" >&2
      return 1
      ;;
  esac

  client_app_id="$(jq -r '.[0].appId // empty' <<<"$selected_json")" || return 1
  client_app_object_id="$(jq -r '.[0].applicationObjectId // empty' <<<"$selected_json")" || return 1
  client_service_principal_id="$(jq -r '.[0].servicePrincipalId // empty' <<<"$selected_json")" || return 1
  selected_display_name="$(jq -r '.[0].displayName // empty' <<<"$selected_json")" || return 1

  [[ -n "$client_app_id" ]] || {
    die "Selected entry is missing appId"
    return 1
  }
  [[ -n "$client_app_object_id" && "$client_app_object_id" != "null" ]] || {
    die "Selected entry is missing applicationObjectId; migrate api-permissions only supports customer-owned apps with a local app registration"
    return 1
  }
  [[ -n "$client_service_principal_id" ]] || {
    die "Selected entry is missing servicePrincipalId"
    return 1
  }

  for inventory_file in "${inventory_files[@]}"; do
    if jq -e \
      --arg appId "$client_app_id" \
      --arg applicationObjectId "$client_app_object_id" \
      --arg servicePrincipalId "$client_service_principal_id" '
        any(.[]?;
          .ownership == "customer"
          and .appId == $appId
          and .applicationObjectId == $applicationObjectId
          and .servicePrincipalId == $servicePrincipalId
        )
      ' "$inventory_file" >/dev/null; then
      summary_file="$(summary_path_for_inventory_file "$inventory_file" || true)"
      if [[ -n "$summary_file" && -f "$summary_file" ]]; then
        file_tenant_id="$(jq -r '.tenantId // empty' "$summary_file")"
        if [[ -n "$file_tenant_id" ]]; then
          inventory_tenant_ids+=("$file_tenant_id")
        fi
      fi
    fi
  done

  inventory_tenant_ids_json="$(printf '%s\n' "${inventory_tenant_ids[@]}" | jq -Rcs 'split("\n") | map(select(length > 0)) | unique')"
  inventory_tenant_count="$(jq -r 'length' <<<"$inventory_tenant_ids_json")"
  case "$inventory_tenant_count" in
    0)
      inventory_tenant_id=""
      ;;
    1)
      inventory_tenant_id="$(jq -r '.[0]' <<<"$inventory_tenant_ids_json")"
      ;;
    *)
      die "Selected entry appears in inventory snapshots from multiple tenants: $(jq -r 'join(", ")' <<<"$inventory_tenant_ids_json")"
      return 1
      ;;
  esac

  current_tenant_id="$(current_azure_cli_tenant_id || true)"
  current_object_names="$(verify_current_tenant_objects "$current_tenant_id" "$client_app_id" "$client_app_object_id" "$client_service_principal_id")" || return 1
  IFS=$'\t' read -r app_display_name sp_display_name <<<"$current_object_names"

  if is_sourced; then
    export CLIENT_APP_ID="$client_app_id"
    export CLIENT_APP_OBJECT_ID="$client_app_object_id"
    export CLIENT_SERVICE_PRINCIPAL_ID="$client_service_principal_id"
    printf 'Selected client app: %s\n' "$selected_display_name" >&2
    print_login_status "" "$inventory_tenant_id" "$current_tenant_id" "$app_display_name" "$sp_display_name" >&2
    printf 'Exported CLIENT_APP_ID=%s\n' "$CLIENT_APP_ID" >&2
    printf 'Exported CLIENT_APP_OBJECT_ID=%s\n' "$CLIENT_APP_OBJECT_ID" >&2
    printf 'Exported CLIENT_SERVICE_PRINCIPAL_ID=%s\n' "$CLIENT_SERVICE_PRINCIPAL_ID" >&2
    printf 'Run migration with: ./adme-entra-migration.sh migrate api-permissions --client-id "%s"\n' "$CLIENT_APP_ID" >&2
  else
    printf '# Selected client app: %s\n' "$selected_display_name"
    print_login_status "# " "$inventory_tenant_id" "$current_tenant_id" "$app_display_name" "$sp_display_name"
    shell_export_line CLIENT_APP_ID "$client_app_id"
    shell_export_line CLIENT_APP_OBJECT_ID "$client_app_object_id"
    shell_export_line CLIENT_SERVICE_PRINCIPAL_ID "$client_service_principal_id"
    printf '# Run migration with: ./adme-entra-migration.sh migrate api-permissions --client-id "$CLIENT_APP_ID"\n'
  fi
}

set_client_env_from_inventory_main "$@"
set_client_env_from_inventory_status="$?"

if is_sourced; then
  return "$set_client_env_from_inventory_status"
fi
exit "$set_client_env_from_inventory_status"
