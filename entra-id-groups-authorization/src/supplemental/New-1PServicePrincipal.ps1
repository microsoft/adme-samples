#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$AppId = 'bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc',
    [int]$MaxWaitAttempts = 8,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'AdmeEntraHelper.psm1') -Force

function Show-Usage {
    @'
Usage:
    New-1PServicePrincipal.ps1 [-AppId <appId>] [-MaxWaitAttempts <count>] [-Help]

Defaults:
  AppId defaults to bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc
    MaxWaitAttempts defaults to 8
'@ | Write-Host
}

if ($Help) {
    Show-Usage
    return
}

if ($MaxWaitAttempts -lt 1) {
        throw 'MaxWaitAttempts must be at least 1.'
}

$tenantResponse = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization?`$select=id"
$tenantId = @($tenantResponse.value)[0].id

Write-Host '=== Create 1P Service Principal ==='
Write-Host "AppId: $AppId"
Write-Host "Tenant: $tenantId"
Write-Host ''

$existing = Resolve-ServicePrincipal -AppId $AppId
if ($null -ne $existing) {
    Write-Host '=== Resolve 1P Service Principal (by appId) ==='
    Write-Host "servicePrincipalId: $($existing.id)"
    Write-Host "displayName: $($existing.displayName)"
    Write-Host ''
    Write-Host 'Service principal already exists. No create needed.'
    Write-Host '=== Create Complete ==='
    return
}

$created = Invoke-AzCliCommand -Arguments @('ad', 'sp', 'create', '--id', $AppId, '-o', 'json')

$resolved = $null
for ($attempt = 1; $attempt -le $MaxWaitAttempts; $attempt++) {
    $resolved = Resolve-ServicePrincipal -AppId $AppId
    if ($null -ne $resolved) {
        break
    }

    Start-Sleep -Seconds 5
}

if ($null -eq $resolved) {
    throw "Service principal create returned success, but the service principal for appId $AppId was not visible in Graph after $MaxWaitAttempts attempts."
}

Write-Host '=== Created 1P Service Principal ==='
([ordered]@{
    id = $resolved.id
    appId = $resolved.appId
    displayName = $resolved.displayName
    servicePrincipalType = $resolved.servicePrincipalType
    appOwnerOrganizationId = $resolved.appOwnerOrganizationId
    createResponseId = $created.id
} | ConvertTo-Json -Depth 10)
Write-Host ''
Write-Host '=== Create Complete ==='