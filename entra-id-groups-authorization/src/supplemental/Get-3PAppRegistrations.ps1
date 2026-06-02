#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$ResourceAppId = 'dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e',
    [int]$PageSize = 100,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'AdmeEntraHelper.psm1') -Force

function Show-Usage {
        @'
Usage:
    Get-3PAppRegistrations.ps1 [-ResourceAppId <appId>] [-PageSize <count>] [-Help]

Defaults:
    ResourceAppId defaults to dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
    PageSize defaults to 100
'@ | Write-Host
}

if ($Help) {
        Show-Usage
        return
}

if ($PageSize -lt 1) {
        throw 'PageSize must be at least 1.'
}

function Write-JsonBlock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 20
}

function Get-NextLink {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    $property = $Response.PSObject.Properties['@odata.nextLink']
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$tenantResponse = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id"
$tenantId = @($tenantResponse.value)[0].id

Write-Host '=== 3P App Registrations with API Permissions to Resource ==='
Write-Host "Resource AppId: $ResourceAppId"
Write-Host "Tenant: $tenantId"
Write-Host ''

Write-Host '=== Resolve Resource Service Principal (by appId) ==='
$resourceSp = Resolve-ServicePrincipal -AppId $ResourceAppId
$resourceSpId = if ($null -ne $resourceSp) { $resourceSp.id } else { $null }
$resourceDisplayName = if ($null -ne $resourceSp) { $resourceSp.displayName } else { $null }

if ($resourceSpId) {
    Write-Host "Resource SP Id: $resourceSpId"
    Write-Host "Resource Display Name: $resourceDisplayName"
}
else {
    Write-Warning 'Resource service principal not found in this tenant.'
    Write-Warning 'Will still scan app registrations for requiredResourceAccess references.'
}
Write-Host ''

Write-Host "=== Scanning App Registrations for requiredResourceAccess referencing $ResourceAppId ==="
Write-Host ''

$nextLink = "https://graph.microsoft.com/v1.0/applications?`$filter=requiredResourceAccess/any(r:r/resourceAppId eq '$ResourceAppId')&`$select=id,appId,displayName,requiredResourceAccess&`$count=true&`$top=$PageSize"

while ($nextLink) {
    $pageResponse = Invoke-GraphRequest -Method GET -Uri $nextLink -Headers @{ ConsistencyLevel = 'eventual' }

    foreach ($entry in @($pageResponse.value)) {
        $permissions = @()
        foreach ($requiredAccess in @($entry.requiredResourceAccess)) {
            if ($requiredAccess.resourceAppId -ne $ResourceAppId) {
                continue
            }

            foreach ($resourceAccess in @($requiredAccess.resourceAccess)) {
                $permissions += [ordered]@{
                    id = $resourceAccess.id
                    type = $resourceAccess.type
                }
            }
        }

        Write-Host '--- Match ---'
        Write-JsonBlock ([ordered]@{
            appId = $entry.appId
            displayName = $entry.displayName
            objectId = $entry.id
            permissionsToResource = $permissions
        })
        Write-Host ''
    }

    $nextLink = Get-NextLink -Response $pageResponse
}

Write-Host '=== Scan Complete ==='
Write-Host ''

if ($resourceSpId) {
    Write-Host "=== Clients with Application Permissions (appRoleAssignedTo) to $resourceDisplayName ==="
    try {
        $assignmentsResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignedTo" -f $resourceSpId)
    }
    catch {
        $assignmentsResponse = [pscustomobject]@{ value = @() }
    }

    if (@($assignmentsResponse.value).Count -gt 0) {
        foreach ($assignment in @($assignmentsResponse.value)) {
            Write-JsonBlock ([ordered]@{
                assignmentId = $assignment.id
                principalId = $assignment.principalId
                principalDisplayName = $assignment.principalDisplayName
                appRoleId = $assignment.appRoleId
                principalType = $assignment.principalType
                createdDateTime = $assignment.createdDateTime
            })
        }
    }
    else {
        Write-Host '(none)'
    }
    Write-Host ''

    Write-Host "=== Clients with Delegated Permissions (oauth2PermissionGrants) to $resourceDisplayName ==="
    try {
        $delegatedResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=resourceId eq '{0}'" -f $resourceSpId)
    }
    catch {
        $delegatedResponse = [pscustomobject]@{ value = @() }
    }

    if (@($delegatedResponse.value).Count -gt 0) {
        foreach ($grant in @($delegatedResponse.value)) {
            Write-JsonBlock ([ordered]@{
                grantId = $grant.id
                clientId = $grant.clientId
                scope = $grant.scope
                consentType = $grant.consentType
                createdDateTime = Get-OptionalPropertyValue -InputObject $grant -Name 'createdDateTime'
            })
        }
    }
    else {
        Write-Host '(none)'
    }
    Write-Host ''

    Write-Host '=== Resolving App Registrations from Granted Service Principals ==='
    Write-Host ''

    $principalIds = @($assignmentsResponse.value | Where-Object { $_.principalType -eq 'ServicePrincipal' } | Select-Object -ExpandProperty principalId)
    $delegatedClientIds = @($delegatedResponse.value | Select-Object -ExpandProperty clientId)
    $uniqueSpIds = @($principalIds + $delegatedClientIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    foreach ($spId in $uniqueSpIds) {
        try {
            $spResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}?`$select=id,appId,displayName,appOwnerOrganizationId,servicePrincipalType" -f $spId)
        }
        catch {
            $spResponse = [pscustomobject]@{}
        }

        $spAppId = $spResponse.appId
        $spDisplayName = $spResponse.displayName
        $spOwnerOrg = $spResponse.appOwnerOrganizationId
        $spType = $spResponse.servicePrincipalType

        Write-Host ("--- Service Principal: {0} ---" -f $(if ($spDisplayName) { $spDisplayName } else { $spId }))
        Write-Host "  SP Object Id: $spId"
        Write-Host ("  App Id: {0}" -f $(if ($spAppId) { $spAppId } else { '<unknown>' }))
        Write-Host ("  Owner Org: {0}" -f $(if ($spOwnerOrg) { $spOwnerOrg } else { '<unknown>' }))
        Write-Host ("  SP Type: {0}" -f $(if ($spType) { $spType } else { '<unknown>' }))

        if ($spOwnerOrg -eq $tenantId -and $spAppId) {
            try {
                $appResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '{0}'&`$select=id,appId,displayName,requiredResourceAccess" -f $spAppId)
            }
            catch {
                $appResponse = [pscustomobject]@{ value = @() }
            }

            $app = @($appResponse.value)[0]
            if ($null -ne $app) {
                Write-Host "  App Object Id: $($app.id)"
                Write-Host '  requiredResourceAccess:'
                Write-JsonBlock @($app.requiredResourceAccess | Where-Object { $_.resourceAppId -eq $ResourceAppId })
            }
            else {
                Write-Host '  App Registration: <not found in this tenant — may be external>'
            }
        }
        else {
            Write-Host ("  App Registration: <external — owned by org {0}>" -f $spOwnerOrg)
        }
        Write-Host ''
    }
}

Write-Host '=== 3P App Registration Scan Complete ==='