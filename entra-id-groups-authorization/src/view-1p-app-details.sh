#!/usr/bin/env bash
set -euo pipefail

# ========= INPUTS =========
fpaAppId="${1:-dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e}" # 1P FPA/ADME application (AppId)
roleValueFilter="${2:-ADME.ApplicationAccess}"        # expected app role value
# =========================

echo "=== 1P FPA Application Details ==="
echo "Tenant: $(az account show --query tenantId -o tsv)"
echo

# Resolve OBJECT IDs
echo "=== Resolve 1P FPA Service Principal (by appId) ==="
fpaResSpId=$(az rest -m GET \
  -u "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '$fpaAppId'" \
  --query "value[0].id" -o tsv || true)
echo "fpaResSpId: ${fpaResSpId:-<not found>}"
echo

if [[ -z "${fpaResSpId:-}" ]]; then
  echo "ERROR: 1P FPA Service Principal not found. Cannot proceed."
  exit 1
fi

# 1) FPA Resource Service Principal – role definitions
echo "=== 1P FPA (ADME) Resource SP (appRoles & summary) ==="
az rest -m GET -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId" -o json | jq '{
  id, appId, displayName, servicePrincipalNames,
  appRoles: [.appRoles[] | {id,value,displayName,allowedMemberTypes,description,origin}],
  signInAudience, appRoleAssignmentRequired
}'
echo

echo "=== 1P FPA (ADME): OAuth2 Permission Scopes (Delegated Permissions) ==="
az rest -m GET -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId" -o json | jq '{
  oauth2PermissionScopes: [.oauth2PermissionScopes[] | {id,value,adminConsentDisplayName,adminConsentDescription,type,userConsentDisplayName,userConsentDescription,isEnabled}]
}'
echo

echo "=== 1P FPA (ADME): resolve appRoleId for '$roleValueFilter' ==="
roleId=$(az rest -m GET \
  -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId" \
  --query "appRoles[?value=='$roleValueFilter'].id | [0]" -o tsv || true)
echo "roleId for $roleValueFilter: ${roleId:-<not found>}"
echo

# 2) Who is granted to FPA? (resource-centric view)
echo "=== 1P FPA (ADME): clients with Application Permissions (appRoleAssignedTo) ==="
az rest -m GET \
  -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId/appRoleAssignedTo" \
  -o json | jq '.value[] | {assignmentId:.id, principalId, appRoleId, createdDateTime}'
echo

echo "=== 1P FPA (ADME): clients with Delegated Permissions (oauth2PermissionGrants to FPA resource) ==="
az rest -m GET \
  -u "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=resourceId eq '$fpaResSpId'" \
  -o json | jq '.value[] | {grantId:.id, clientId, scope, consentType, createdDateTime, expiryTime}'
echo

# 3) Enterprise App facets
echo "=== 1P FPA (ADME) Enterprise App (SP) – owners & assignment flags ==="
az rest -m GET -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId/owners" -o json | jq '.value[] | {id,displayName,userPrincipalName,appId}'
az rest -m GET -u "https://graph.microsoft.com/v1.0/servicePrincipals/$fpaResSpId" -o json | jq '{id,displayName,appRoleAssignmentRequired,accountEnabled,tags}'
echo

echo "=== 1P FPA Details Complete ==="
