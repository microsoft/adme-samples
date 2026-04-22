HOST=$1
ENDPOINT="https://$HOST"
ENTITLEMENTS_HOST="$ENDPOINT/api/entitlements/v2"
SCOPE="https://energy.azure.com/.default"

az login
USER_ACCESS_TOKEN=$(az account get-access-token --scope $SCOPE --query accessToken -o tsv)

az rest --method get --url "$ENTITLEMENTS_HOST/info" \
  --headers "Authorization=Bearer $USER_ACCESS_TOKEN" "Accept=application/json"