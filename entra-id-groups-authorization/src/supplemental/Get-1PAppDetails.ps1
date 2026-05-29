#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$AppId = 'dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e',
    [string]$RoleValueFilter = 'ADME.ApplicationAccess',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'AdmeEntraHelper.psm1') -Force

function Show-Usage {
        @'
Usage:
    Get-1PAppDetails.ps1 [-AppId <appId>] [-RoleValueFilter <role-value>] [-Help]

Defaults:
    AppId defaults to dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
    RoleValueFilter defaults to ADME.ApplicationAccess
'@ | Write-Host
}

if ($Help) {
        Show-Usage
        return
}

function Write-JsonBlock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 20
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

Write-Host '=== 1P FPA Application Details ==='
Write-Host "Tenant: $tenantId"
Write-Host ''

Write-Host '=== Resolve 1P FPA Service Principal (by appId) ==='
$resourceSp = Resolve-ServicePrincipal -AppId $AppId
$resourceSpId = if ($null -ne $resourceSp) { $resourceSp.id } else { $null }
Write-Host ('fpaResSpId: {0}' -f $(if ($resourceSpId) { $resourceSpId } else { '<not found>' }))
Write-Host ''

if (-not $resourceSpId) {
    throw '1P FPA Service Principal not found. Cannot proceed.'
}

$fullSp = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}" -f $resourceSpId)

Write-Host '=== 1P FPA (ADME) Resource SP (appRoles & summary) ==='
Write-JsonBlock ([ordered]@{
    id = $fullSp.id
    appId = $fullSp.appId
    displayName = $fullSp.displayName
    servicePrincipalNames = @($fullSp.servicePrincipalNames)
    appRoles = @($fullSp.appRoles | ForEach-Object {
        [ordered]@{
            id = $_.id
            value = $_.value
            displayName = $_.displayName
            allowedMemberTypes = @($_.allowedMemberTypes)
            description = $_.description
            origin = $_.origin
        }
    })
    signInAudience = $fullSp.signInAudience
    appRoleAssignmentRequired = $fullSp.appRoleAssignmentRequired
})
Write-Host ''

Write-Host '=== 1P FPA (ADME): OAuth2 Permission Scopes (Delegated Permissions) ==='
Write-JsonBlock ([ordered]@{
    oauth2PermissionScopes = @($fullSp.oauth2PermissionScopes | ForEach-Object {
        [ordered]@{
            id = $_.id
            value = $_.value
            adminConsentDisplayName = $_.adminConsentDisplayName
            adminConsentDescription = $_.adminConsentDescription
            type = $_.type
            userConsentDisplayName = $_.userConsentDisplayName
            userConsentDescription = $_.userConsentDescription
            isEnabled = $_.isEnabled
        }
    })
})
Write-Host ''

$roleId = @($fullSp.appRoles | Where-Object { $_.value -eq $RoleValueFilter } | Select-Object -ExpandProperty id -First 1)[0]
Write-Host ("=== 1P FPA (ADME): resolve appRoleId for '{0}' ===" -f $RoleValueFilter)
Write-Host ('roleId for {0}: {1}' -f $RoleValueFilter, $(if ($roleId) { $roleId } else { '<not found>' }))
Write-Host ''

Write-Host '=== 1P FPA (ADME): clients with Application Permissions (appRoleAssignedTo) ==='
$assignmentResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignedTo" -f $resourceSpId)
Write-JsonBlock @($assignmentResponse.value | ForEach-Object {
    [ordered]@{
        assignmentId = $_.id
        principalId = $_.principalId
        appRoleId = $_.appRoleId
        createdDateTime = $_.createdDateTime
    }
})
Write-Host ''

Write-Host '=== 1P FPA (ADME): clients with Delegated Permissions (oauth2PermissionGrants to FPA resource) ==='
$grantResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=resourceId eq '{0}'" -f $resourceSpId)
Write-JsonBlock @($grantResponse.value | ForEach-Object {
    [ordered]@{
        grantId = $_.id
        clientId = $_.clientId
        scope = $_.scope
        consentType = $_.consentType
        createdDateTime = Get-OptionalPropertyValue -InputObject $_ -Name 'createdDateTime'
        expiryTime = Get-OptionalPropertyValue -InputObject $_ -Name 'expiryTime'
    }
})
Write-Host ''

Write-Host '=== 1P FPA (ADME) Enterprise App (SP) – owners & assignment flags ==='
$ownerResponse = Invoke-GraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}/owners" -f $resourceSpId)
Write-JsonBlock @($ownerResponse.value | ForEach-Object {
    [ordered]@{
        id = $_.id
        displayName = $_.displayName
        userPrincipalName = $_.userPrincipalName
        appId = $_.appId
    }
})
Write-JsonBlock ([ordered]@{
    id = $fullSp.id
    displayName = $fullSp.displayName
    appRoleAssignmentRequired = $fullSp.appRoleAssignmentRequired
    accountEnabled = $fullSp.accountEnabled
    tags = @($fullSp.tags)
})
Write-Host ''

Write-Host '=== 1P FPA Details Complete ==='