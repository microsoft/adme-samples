#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$AppId = 'dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'AdmeEntraHelper.psm1') -Force

function Show-Usage {
    @'
Usage:
  Delete-1PServicePrincipal.ps1 [-AppId <appId>] [-Help]

Defaults:
  AppId defaults to dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e
'@ | Write-Host
}

if ($Help) {
    Show-Usage
    return
}

$tenantResponse = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id"
$tenantId = @($tenantResponse.value)[0].id

Write-Host '=== Delete 1P Service Principal ==='
Write-Host "AppId: $AppId"
Write-Host "Tenant: $tenantId"
Write-Host ''

$servicePrincipal = Resolve-ServicePrincipal -AppId $AppId
if ($null -eq $servicePrincipal) {
    throw "Service principal for appId $AppId was not found in the current tenant."
}

Write-Host '=== Resolve 1P Service Principal (by appId) ==='
Write-Host "servicePrincipalId: $($servicePrincipal.id)"
Write-Host "displayName: $($servicePrincipal.displayName)"
Write-Host ''

Invoke-GraphRequest -Method DELETE -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}" -f $servicePrincipal.id) | Out-Null

Write-Host "Deleted service principal: $($servicePrincipal.id)"
Write-Host '=== Delete Complete ==='