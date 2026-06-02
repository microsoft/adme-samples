#!/usr/bin/env pwsh
#
# Invoke-AdmeMigration.ps1
# ========================
# Customer-facing helper for the ADME Entra ID app migration (PowerShell port of
# adme-entra-migration.sh).
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
# verify the resulting token paths. This script provides the same workflow as
# adme-entra-migration.sh for operators who prefer PowerShell.
#
# What this script does today
# ---------------------------
#   * migrate adme-audience
#       - refreshes the old resource (dffa) service principal in the customer tenant
#       - ensures the new resource (bd0c) service principal exists
#       - ensures Microsoft Azure CLI has the delegated grant needed for the
#         new ADME scope
#       - by default stops before any destructive change; --allow-recreate-dffa
#         opts in to a guarded dffa delete/recreate fallback if the refresh stays
#         stale after bounded retries
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
#       - optionally proves a selected client app's app-only token when given
#         --client-id and a secret (--client-secret or the CLIENT_SECRET env var)
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
# Command-line and PowerShell invocation
# --------------------------------------
# Commands and options use the same bash-style flags as adme-entra-migration.sh
# (for example: migrate adme-audience [--allow-recreate-dffa]). Equivalent
# PowerShell named parameters are also accepted:
#   -StateDir, -OutputLogging, -Yes, -AllowRecreateDffa, -ClientId,
#   -ClientSecret, -AutoGrant, -Help
# Run with -h, --help, or -Help for full usage.
#
# Prerequisites
# -------------
#   * PowerShell 7+ (pwsh); Azure Cloud Shell is the recommended environment
#   * Required tools on PATH: az (JSON is parsed with built-in ConvertFrom-Json,
#     so jq is not required)
#   * Optional for the enhanced delegated verify proof and selected-client
#     app-only proof: python3 with the msal package
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
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$script:RemainingArguments = @()
if ($null -ne $CommandArgs) {
    $script:RemainingArguments = @($CommandArgs)
}

$script:LogFile = $null
$script:LogInitialized = $false
$script:SensitiveValues = New-Object System.Collections.ArrayList
$script:ConfigValues = [ordered]@{}
$script:ConfigSources = @{}
$script:Options = [ordered]@{
    AssumeYes = $false
    AllowRecreateDffa = $false
    AutoGrant = $false
    SelectedClientId = $null
    SelectedClientSecret = $null
    ShowHelp = $false
}
$script:StateDirExplicit = $false
$script:CommandContext = $null
$script:HelperModuleLoaded = $false
$script:RequiredRoleNames = @(
    'Application Administrator',
    'Cloud Application Administrator',
    'Global Administrator'
)

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath
        $usage = @"
Usage:
  $scriptName [--state-dir dir] [--output-logging dir] [--yes] migrate adme-audience [--allow-recreate-dffa]
  $scriptName [--state-dir dir] [--output-logging dir] [--yes] migrate api-permissions --client-id id [--auto-grant]
  $scriptName [--state-dir dir] [--output-logging dir] verify [--client-id id] [--client-secret secret]

Commands:
  migrate adme-audience    Refresh the stale old resource (dffa) service principal, provision the new resource (bd0c) service principal, and wire the Azure CLI delegated grant.
                             --allow-recreate-dffa: if refresh stays stale after bounded retries, allow a delete/recreate fallback with explicit confirmation.
  migrate api-permissions  Update the selected client app to the new resource (bd0c) permissions.
                             Default: update requiredResourceAccess only and print one tenant-wide admin-consent action for the customer-app permissions required by the target resource.
                             --client-id: client appId or client servicePrincipalId to migrate.
                             --auto-grant: create the delegated grant and, when applicable, the new app-role assignment programmatically.
                             Requires Application Administrator, Cloud Application Administrator, or Global Administrator.
  verify                   Without --client-id, validate tenant audience migration and Azure CLI delegated token issuance.
                             --client-id: optional client appId or client servicePrincipalId for selected-client app-only token proof.
                             --client-secret: optional selected-client secret for the app-only token proof. Prefer CLIENT_SECRET env to avoid shell history.
                             App configuration/admin-consent status belongs to adme-entra-inventory.sh; ADME endpoint smoke belongs to test.sh.
                             Uses az + PowerShell for Graph checks; python3 + msal enables forced-refresh delegated proof and selected-client app-only proof.

Options:
  --state-dir dir          Load simulator/runtime state from dir/sim-state.env.
  --output-logging dir     Directory for structured log files. Defaults to ./migration-logs.
  --yes                    Skip the interactive confirmation prompt in TTY mode.
  --allow-recreate-dffa    Only for migrate adme-audience. After refresh failure, allow the destructive dffa delete/recreate fallback.
  --client-id id           For migrate api-permissions and verify. Client appId or client servicePrincipalId to migrate/verify.
  --client-secret secret   Only for verify. Secret value for the selected client app-only token proof; never logged.
  --auto-grant             Only for migrate api-permissions. Create both the customer-app app-role assignment and delegated grant programmatically.
  -h, --help, -Help        Show this help text.

PowerShell named-parameter equivalents:
  -StateDir, -OutputLogging, -Yes, -AllowRecreateDffa, -ClientId, -ClientSecret, -AutoGrant, -Help
"@
    [Console]::Out.WriteLine($usage)
}

function Ensure-HelperModuleLoaded {
    [CmdletBinding()]
    param()

    if ($script:HelperModuleLoaded) {
        return
    }

    $candidatePaths = New-Object System.Collections.ArrayList
    $invocationName = $MyInvocation.InvocationName
    if (-not [string]::IsNullOrWhiteSpace($invocationName)) {
        $invocationParent = Split-Path -Parent $invocationName
        if ([string]::IsNullOrWhiteSpace($invocationParent)) {
            [void]$candidatePaths.Add('./AdmeEntraHelper.psm1')
        }
        else {
            [void]$candidatePaths.Add((Join-Path $invocationParent 'AdmeEntraHelper.psm1'))
        }
    }

    [void]$candidatePaths.Add('./AdmeEntraHelper.psm1')
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        [void]$candidatePaths.Add((Join-Path $PSScriptRoot 'AdmeEntraHelper.psm1'))
    }

    $seen = @{}
    $lastError = $null
    foreach ($candidate in $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $seen.ContainsKey($candidate)) {
            continue
        }

        $seen[$candidate] = $true
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Import-Module $candidate -Force -DisableNameChecking
                $script:HelperModuleLoaded = $true
                return
            }
        }
        catch {
            $lastError = $_
        }
    }

    if ($null -ne $lastError) {
        throw ("Failed to import AdmeEntraHelper.psm1: {0}" -f $lastError.Exception.Message)
    }

    throw 'AdmeEntraHelper.psm1 was not found relative to the script invocation path.'
}

function Get-DefaultStateDirectory {
    [CmdletBinding()]
    param()

    $runtimeRoot = $env:XDG_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        $runtimeRoot = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    }

    return Join-Path $runtimeRoot 'adme-entra-migration'
}

function Register-SensitiveValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return
    }

    if ($script:SensitiveValues -contains $Value) {
        return
    }

    [void]$script:SensitiveValues.Add($Value)
}

function Set-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $script:ConfigValues[$Name] = $Value
    $script:ConfigSources[$Name] = $Source

    if ($Name -eq 'ClientSecret') {
        Register-SensitiveValue -Value ([string]$Value)
    }
}

function Get-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $script:ConfigValues[$Name]
}

function Get-ConfigSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $script:ConfigSources[$Name]
}

function Set-OptionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $currentValue = $script:Options[$Name]
    if ($null -ne $currentValue -and $currentValue -isnot [bool] -and $currentValue -ne $Value) {
        throw ("Conflicting values supplied for {0}: '{1}' vs '{2}'." -f $Name, $currentValue, $Value)
    }

    if ($currentValue -is [bool] -and [bool]$currentValue -and [bool]$Value) {
        return
    }

    $script:Options[$Name] = $Value
    if ($Name -eq 'SelectedClientSecret') {
        Register-SensitiveValue -Value ([string]$Value)
    }
}

function Set-PathLikeConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw ("{0} cannot be empty." -f $Name)
    }

    $existing = Get-ConfigValue -Name $Name
    if (-not [string]::IsNullOrWhiteSpace([string]$existing) -and $existing -ne $Value -and (Get-ConfigSource -Name $Name) -eq 'parameter') {
        throw ("Conflicting values supplied for {0}: '{1}' vs '{2}'." -f $Name, $existing, $Value)
    }

    Set-ConfigValue -Name $Name -Value $Value -Source $Source
}

function Initialize-Defaults {
    [CmdletBinding()]
    param()

    $defaults = [ordered]@{
        StateDir = Get-DefaultStateDirectory
        OutputLogging = './migration-logs'
        AppRegistrationsPortalUrl = 'https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade'
        CustomerTenantId = $null
        CustomerConfigDir = $null
        HomeTenantId = $null
        HomeConfigDir = $null
        IsvTenantId = $null
        IsvConfigDir = $null
        StateJsonFile = $null
        OldResourceAppId = 'dffa82c7-cb2f-4a0a-9e8f-7e86fd7b245e'
        NewResourceAppId = 'bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc'
        OldResourceIdentifierUri = 'https://energy-old.azure.com'
        NewResourceIdentifierUri = 'https://energy.azure.com'
        OldResourceServicePrincipalId = $null
        NewResourceAppRoleId = 'f1454897-e4e4-440e-9e04-bc379d7629f7'
        NewResourceAppRoleValue = 'ADME.ApplicationAccess'
        NewResourceScopeId = '66e904da-2872-4e72-bff6-a88a6c4375ea'
        NewResourceScopeValue = 'access_as_user'
        ClientAppId = $null
        ClientAppObjectId = $null
        ClientServicePrincipalId = $null
        ClientSecret = $null
        Sim3PClientAppId = $null
        Sim3PClientAppObjectId = $null
        Sim3PClientServicePrincipalId = $null
        Sim3PClientSecret = $null
        Sim3PClient2AppId = $null
        Sim3PClient2AppObjectId = $null
        Sim3PClient2ServicePrincipalId = $null
        Sim3PClient2Secret = $null
        Sim3PClient3AppId = $null
        Sim3PClient3AppObjectId = $null
        Sim3PClient3ServicePrincipalId = $null
        Sim3PClient3Secret = $null
        AzureCliAppId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        AdmeSimInternalForceTier2Fallback = $null
    }

    foreach ($entry in $defaults.GetEnumerator()) {
        Set-ConfigValue -Name $entry.Key -Value $entry.Value -Source 'default'
    }
}

function Apply-EnvironmentOverrides {
    [CmdletBinding()]
    param()

    $envMap = [ordered]@{
        HOME_TENANT_ID = 'HomeTenantId'
        HOME_CONFIG_DIR = 'HomeConfigDir'
        CUSTOMER_TENANT_ID = 'CustomerTenantId'
        CUSTOMER_CONFIG_DIR = 'CustomerConfigDir'
        ISV_TENANT_ID = 'IsvTenantId'
        ISV_CONFIG_DIR = 'IsvConfigDir'
        STATE_JSON_FILE = 'StateJsonFile'
        OLD_RESOURCE_APP_ID = 'OldResourceAppId'
        NEW_RESOURCE_APP_ID = 'NewResourceAppId'
        OLD_RESOURCE_IDENTIFIER_URI = 'OldResourceIdentifierUri'
        NEW_RESOURCE_IDENTIFIER_URI = 'NewResourceIdentifierUri'
        OLD_RESOURCE_SERVICE_PRINCIPAL_ID = 'OldResourceServicePrincipalId'
        NEW_RESOURCE_APP_ROLE_ID = 'NewResourceAppRoleId'
        NEW_RESOURCE_APP_ROLE_VALUE = 'NewResourceAppRoleValue'
        NEW_RESOURCE_SCOPE_ID = 'NewResourceScopeId'
        NEW_RESOURCE_SCOPE_VALUE = 'NewResourceScopeValue'
        CLIENT_APP_ID = 'ClientAppId'
        CLIENT_APP_OBJECT_ID = 'ClientAppObjectId'
        CLIENT_SERVICE_PRINCIPAL_ID = 'ClientServicePrincipalId'
        CLIENT_SECRET = 'ClientSecret'
        SIM_3P_CLIENT_APP_ID = 'Sim3PClientAppId'
        SIM_3P_CLIENT_APP_OBJECT_ID = 'Sim3PClientAppObjectId'
        SIM_3P_CLIENT_SERVICE_PRINCIPAL_ID = 'Sim3PClientServicePrincipalId'
        SIM_3P_CLIENT_SECRET = 'Sim3PClientSecret'
        SIM_3P_CLIENT_2_APP_ID = 'Sim3PClient2AppId'
        SIM_3P_CLIENT_2_APP_OBJECT_ID = 'Sim3PClient2AppObjectId'
        SIM_3P_CLIENT_2_SERVICE_PRINCIPAL_ID = 'Sim3PClient2ServicePrincipalId'
        SIM_3P_CLIENT_2_SECRET = 'Sim3PClient2Secret'
        SIM_3P_CLIENT_3_APP_ID = 'Sim3PClient3AppId'
        SIM_3P_CLIENT_3_APP_OBJECT_ID = 'Sim3PClient3AppObjectId'
        SIM_3P_CLIENT_3_SERVICE_PRINCIPAL_ID = 'Sim3PClient3ServicePrincipalId'
        SIM_3P_CLIENT_3_SECRET = 'Sim3PClient3Secret'
        ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK = 'AdmeSimInternalForceTier2Fallback'
    }

    foreach ($entry in $envMap.GetEnumerator()) {
        $value = [Environment]::GetEnvironmentVariable($entry.Key)
        if ($null -ne $value -and $value -ne '') {
            Set-ConfigValue -Name $entry.Value -Value $value -Source 'environment'
        }
    }
}

function Initialize-ParameterOverrides {
    [CmdletBinding()]
    param()
}

function ConvertTo-UtcTimestamp {
    [CmdletBinding()]
    param()

    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertTo-LogFileTimestamp {
    [CmdletBinding()]
    param()

    return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
}

function Protect-LogMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($null -eq $Message) {
        return ''
    }

    $sanitized = $Message
    $values = @($script:SensitiveValues | Sort-Object Length -Descending)
    foreach ($value in $values) {
        if ([string]::IsNullOrEmpty($value)) {
            continue
        }

        $sanitized = [regex]::Replace($sanitized, [regex]::Escape($value), '<redacted>')
    }

    $sanitized = [regex]::Replace($sanitized, 'Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*', 'Bearer <redacted>', 'IgnoreCase')
    $sanitized = [regex]::Replace($sanitized, 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '<jwt-redacted>')
    return $sanitized
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    $line = '{0} [{1}] {2}' -f (ConvertTo-UtcTimestamp), $Level, (Protect-LogMessage -Message $Message)
    [Console]::Error.WriteLine($line)

    if ($script:LogInitialized -and -not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function Write-LogStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Level INFO -Message ('STEP: {0}' -f $Message)
}

function Write-LogSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Level INFO -Message ('OK: {0}' -f $Message)
}

function Write-LogWarn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Level WARN -Message $Message
}

function Initialize-Logging {
    [CmdletBinding()]
    param()

    $directory = Get-ConfigValue -Name 'OutputLogging'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $script:LogFile = Join-Path $directory ('adme-entra-migration-{0}.log' -f (ConvertTo-LogFileTimestamp))
    Set-Content -LiteralPath $script:LogFile -Value $null
    $script:LogInitialized = $true
}

function Test-IsInteractiveSession {
    [CmdletBinding()]
    param()

    try {
        return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    }
    catch {
        return $Host.Name -eq 'ConsoleHost'
    }
}

function Confirm-IfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionLabel
    )

    if ($script:Options.AssumeYes) {
        Write-Log -Level INFO -Message 'Skipping confirmation because --yes was provided'
        return
    }

    if (Test-IsInteractiveSession) {
        $response = Read-Host -Prompt ("Proceed with {0}? [y/N]" -f $ActionLabel)
        switch -Regex ($response) {
            '^(y|yes)$' { return }
            default { throw 'Aborted by operator' }
        }
    }

    Write-Log -Level INFO -Message 'Non-interactive session detected; proceeding without confirmation prompt'
}

function Confirm-DestructiveIfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionLabel
    )

    if ($script:Options.AssumeYes) {
        Write-Log -Level INFO -Message 'Skipping destructive confirmation because --yes was provided'
        return
    }

    if (Test-IsInteractiveSession) {
        $response = Read-Host -Prompt ("Proceed with {0}? [y/N]" -f $ActionLabel)
        switch -Regex ($response) {
            '^(y|yes)$' { return }
            default { throw 'Aborted by operator' }
        }
    }

    throw ('Refusing to proceed with {0} in non-interactive mode without --yes' -f $ActionLabel)
}

function Get-RequiredOptionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Items,

        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        [string]$OptionName
    )

    if (($Index + 1) -ge $Items.Count) {
        throw ("Missing value for {0}" -f $OptionName)
    }

    return $Items[$Index + 1]
}

function Consume-SupportedOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Items,

        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    $token = $Items[$Index]
    switch ($token) {
        '--state-dir' {
            $script:StateDirExplicit = $true
            Set-PathLikeConfigValue -Name 'StateDir' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '--state-dir') -Source 'cli'
            return 2
        }
        '-StateDir' {
            $script:StateDirExplicit = $true
            Set-PathLikeConfigValue -Name 'StateDir' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '-StateDir') -Source 'parameter'
            return 2
        }
        '--output-logging' {
            Set-PathLikeConfigValue -Name 'OutputLogging' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '--output-logging') -Source 'cli'
            return 2
        }
        '-OutputLogging' {
            Set-PathLikeConfigValue -Name 'OutputLogging' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '-OutputLogging') -Source 'parameter'
            return 2
        }
        '--yes' {
            Set-OptionValue -Name 'AssumeYes' -Value $true -Source 'cli'
            return 1
        }
        '-Yes' {
            Set-OptionValue -Name 'AssumeYes' -Value $true -Source 'parameter'
            return 1
        }
        '--allow-recreate-dffa' {
            Set-OptionValue -Name 'AllowRecreateDffa' -Value $true -Source 'cli'
            return 1
        }
        '-AllowRecreateDffa' {
            Set-OptionValue -Name 'AllowRecreateDffa' -Value $true -Source 'parameter'
            return 1
        }
        '--client-id' {
            Set-OptionValue -Name 'SelectedClientId' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '--client-id') -Source 'cli'
            return 2
        }
        '-ClientId' {
            Set-OptionValue -Name 'SelectedClientId' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '-ClientId') -Source 'parameter'
            return 2
        }
        '--client-secret' {
            Set-OptionValue -Name 'SelectedClientSecret' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '--client-secret') -Source 'cli'
            return 2
        }
        '-ClientSecret' {
            Set-OptionValue -Name 'SelectedClientSecret' -Value (Get-RequiredOptionValue -Items $Items -Index $Index -OptionName '-ClientSecret') -Source 'parameter'
            return 2
        }
        '--auto-grant' {
            Set-OptionValue -Name 'AutoGrant' -Value $true -Source 'cli'
            return 1
        }
        '-AutoGrant' {
            Set-OptionValue -Name 'AutoGrant' -Value $true -Source 'parameter'
            return 1
        }
        '-h' {
            Set-OptionValue -Name 'ShowHelp' -Value $true -Source 'cli'
            return 1
        }
        '--help' {
            Set-OptionValue -Name 'ShowHelp' -Value $true -Source 'cli'
            return 1
        }
        '-Help' {
            Set-OptionValue -Name 'ShowHelp' -Value $true -Source 'parameter'
            return 1
        }
        default {
            return 0
        }
    }
}

function Resolve-CommandContext {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$Arguments
    )

    $items = @($Arguments)
    $index = 0
    $command = $null
    $subcommand = $null

    while ($index -lt $items.Count) {
        $consumed = Consume-SupportedOption -Items $items -Index $index
        if ($consumed -gt 0) {
            $index += $consumed
            continue
        }

        if ($null -eq $command) {
            $command = $items[$index]
            $index++

            switch ($command) {
                'migrate' {
                    if ($index -ge $items.Count) {
                        throw "Missing subcommand after 'migrate'"
                    }

                    $subcommand = $items[$index]
                    $index++
                    switch ($subcommand) {
                        'adme-audience' { }
                        'api-permissions' { }
                        default { throw ("Unknown migrate subcommand: {0}" -f $subcommand) }
                    }
                }
                'verify' { }
                default {
                    if ($command.StartsWith('-')) {
                        throw ("Unknown option: {0}" -f $command)
                    }

                    throw ("Unknown command: {0}" -f $command)
                }
            }

            continue
        }

        if ($items[$index].StartsWith('-')) {
            switch ("$command/$subcommand") {
                'migrate/adme-audience' {
                    throw ("Unknown option for 'migrate adme-audience': {0}" -f $items[$index])
                }
                'migrate/api-permissions' {
                    throw ("Unknown option for 'migrate api-permissions': {0}" -f $items[$index])
                }
                'verify/' {
                    throw ("Unknown option for 'verify': {0}" -f $items[$index])
                }
                default {
                    throw ("Unsupported command context: {0}/{1}" -f $command, $subcommand)
                }
            }
        }

        switch ("$command/$subcommand") {
            'migrate/adme-audience' {
                throw ("Unexpected argument for 'migrate adme-audience': {0}" -f $items[$index])
            }
            'migrate/api-permissions' {
                throw ("Unexpected argument for 'migrate api-permissions': {0}" -f $items[$index])
            }
            'verify/' {
                throw ("Unexpected argument for 'verify': {0}" -f $items[$index])
            }
            default {
                throw ("Unsupported command context: {0}/{1}" -f $command, $subcommand)
            }
        }
    }

    if ($null -eq $command) {
        if ($script:Options.ShowHelp) {
            return [pscustomobject]@{
                Command = $null
                Subcommand = $null
            }
        }

        throw 'A command is required. Use -Help for usage.'
    }

    if ($command -eq 'migrate' -and $subcommand -eq 'api-permissions' -and -not $script:Options.ShowHelp -and [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientId)) {
        throw "--client-id is required for 'migrate api-permissions'"
    }

    if ($command -eq 'migrate' -and $subcommand -eq 'adme-audience') {
        if ($script:Options.AutoGrant) {
            throw '-AutoGrant/--auto-grant is only valid for migrate api-permissions.'
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientId)) {
            throw '-ClientId/--client-id is not valid for migrate adme-audience.'
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientSecret)) {
            throw '-ClientSecret/--client-secret is only valid for verify.'
        }
    }

    if ($command -eq 'migrate' -and $subcommand -eq 'api-permissions') {
        if ($script:Options.AllowRecreateDffa) {
            throw '-AllowRecreateDffa/--allow-recreate-dffa is only valid for migrate adme-audience.'
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientSecret)) {
            throw '-ClientSecret/--client-secret is only valid for verify.'
        }
    }

    if ($command -eq 'verify') {
        if ($script:Options.AutoGrant) {
            throw '-AutoGrant/--auto-grant is only valid for migrate api-permissions.'
        }

        if ($script:Options.AllowRecreateDffa) {
            throw '-AllowRecreateDffa/--allow-recreate-dffa is only valid for migrate adme-audience.'
        }
    }

    return [pscustomobject]@{
        Command = $command
        Subcommand = $subcommand
    }
}

function Test-UnsupportedShellSyntax {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    return $Text -match '(^|[^\\])\$\(' -or
        $Text -match '(^|[^\\])`' -or
        $Text -match '(^|[^\\])\$\{' -or
        $Text -match '(^|[^\\])\$[A-Za-z_]'
}

function ConvertFrom-SingleQuotedEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $placeholder = [string][char]7
    $normalized = $Token -replace "'\\''", $placeholder
    if ($normalized -notmatch "^'([^']*)'(?:\s*#.*)?$") {
        throw ("Unsupported single-quoted env value syntax: {0}" -f $Token)
    }

    return $Matches[1].Replace($placeholder, "'")
}

function ConvertFrom-DoubleQuotedEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    if ($Token -notmatch '^"((?:[^"\\]|\\.)*)"(?:\s*#.*)?$') {
        throw ("Unsupported double-quoted env value syntax: {0}" -f $Token)
    }

    if (Test-UnsupportedShellSyntax -Text $Matches[1]) {
        throw ("Unsupported shell expansion syntax in env value: {0}" -f $Token)
    }

    $value = $Matches[1]
    $value = $value.Replace('\"', '"')
    $value = $value.Replace('\n', [Environment]::NewLine)
    $value = $value.Replace('\r', "`r")
    $value = $value.Replace('\t', "`t")
    $value = $value.Replace('\\', '\')
    return $value
}

function ConvertFrom-UnquotedEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $value = $Token
    if ($value -match '^(.*?)(?:\s+#.*)?$') {
        $value = $Matches[1].Trim()
    }

    if (Test-UnsupportedShellSyntax -Text $value) {
        throw ("Unsupported shell expansion syntax in env value: {0}" -f $Token)
    }

    return $value
}

function Read-SimStateEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("Runtime state file not found: {0}" -f $Path)
    }

    $values = [ordered]@{}
    $lineNumber = 0
    foreach ($rawLine in [IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw ("Unsupported sim-state.env syntax at {0}:{1}: {2}" -f $Path, $lineNumber, $rawLine)
        }

        $name = $Matches[1]
        $valueToken = $Matches[2].Trim()
        $value = ''
        if ([string]::IsNullOrEmpty($valueToken)) {
            $value = ''
        }
        elseif ($valueToken.StartsWith("'")) {
            $value = ConvertFrom-SingleQuotedEnvValue -Token $valueToken
        }
        elseif ($valueToken.StartsWith('"')) {
            $value = ConvertFrom-DoubleQuotedEnvValue -Token $valueToken
        }
        else {
            $value = ConvertFrom-UnquotedEnvValue -Token $valueToken
        }

        $values[$name] = $value
    }

    return $values
}

function Load-RuntimeState {
    [CmdletBinding()]
    param()

    $statePath = Join-Path (Get-ConfigValue -Name 'StateDir') 'sim-state.env'
    $clientSecretEnvironment = [Environment]::GetEnvironmentVariable('CLIENT_SECRET')
    $commandKey = '{0}/{1}' -f $script:CommandContext.Command, $script:CommandContext.Subcommand

    if ($script:StateDirExplicit) {
        $stateValues = Read-SimStateEnv -Path $statePath
        foreach ($entry in $stateValues.GetEnumerator()) {
            switch ($entry.Key) {
                'STATE_JSON_FILE' { Set-ConfigValue -Name 'StateJsonFile' -Value $entry.Value -Source $statePath }
                'HOME_TENANT_ID' { Set-ConfigValue -Name 'HomeTenantId' -Value $entry.Value -Source $statePath }
                'HOME_CONFIG_DIR' { Set-ConfigValue -Name 'HomeConfigDir' -Value $entry.Value -Source $statePath }
                'CUSTOMER_TENANT_ID' { Set-ConfigValue -Name 'CustomerTenantId' -Value $entry.Value -Source $statePath }
                'CUSTOMER_CONFIG_DIR' { Set-ConfigValue -Name 'CustomerConfigDir' -Value $entry.Value -Source $statePath }
                'ISV_TENANT_ID' { Set-ConfigValue -Name 'IsvTenantId' -Value $entry.Value -Source $statePath }
                'ISV_CONFIG_DIR' { Set-ConfigValue -Name 'IsvConfigDir' -Value $entry.Value -Source $statePath }
                'OLD_RESOURCE_APP_ID' { Set-ConfigValue -Name 'OldResourceAppId' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_APP_ID' { Set-ConfigValue -Name 'NewResourceAppId' -Value $entry.Value -Source $statePath }
                'OLD_RESOURCE_IDENTIFIER_URI' { Set-ConfigValue -Name 'OldResourceIdentifierUri' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_IDENTIFIER_URI' { Set-ConfigValue -Name 'NewResourceIdentifierUri' -Value $entry.Value -Source $statePath }
                'OLD_RESOURCE_SERVICE_PRINCIPAL_ID' { Set-ConfigValue -Name 'OldResourceServicePrincipalId' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_APP_ROLE_ID' { Set-ConfigValue -Name 'NewResourceAppRoleId' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_APP_ROLE_VALUE' { Set-ConfigValue -Name 'NewResourceAppRoleValue' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_SCOPE_ID' { Set-ConfigValue -Name 'NewResourceScopeId' -Value $entry.Value -Source $statePath }
                'NEW_RESOURCE_SCOPE_VALUE' { Set-ConfigValue -Name 'NewResourceScopeValue' -Value $entry.Value -Source $statePath }
                'CLIENT_APP_ID' { Set-ConfigValue -Name 'ClientAppId' -Value $entry.Value -Source $statePath }
                'CLIENT_APP_OBJECT_ID' { Set-ConfigValue -Name 'ClientAppObjectId' -Value $entry.Value -Source $statePath }
                'CLIENT_SERVICE_PRINCIPAL_ID' { Set-ConfigValue -Name 'ClientServicePrincipalId' -Value $entry.Value -Source $statePath }
                'CLIENT_SECRET' { Set-ConfigValue -Name 'ClientSecret' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_APP_ID' { Set-ConfigValue -Name 'Sim3PClientAppId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_APP_OBJECT_ID' { Set-ConfigValue -Name 'Sim3PClientAppObjectId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_SERVICE_PRINCIPAL_ID' { Set-ConfigValue -Name 'Sim3PClientServicePrincipalId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_SECRET' { Set-ConfigValue -Name 'Sim3PClientSecret' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_2_APP_ID' { Set-ConfigValue -Name 'Sim3PClient2AppId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_2_APP_OBJECT_ID' { Set-ConfigValue -Name 'Sim3PClient2AppObjectId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_2_SERVICE_PRINCIPAL_ID' { Set-ConfigValue -Name 'Sim3PClient2ServicePrincipalId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_2_SECRET' { Set-ConfigValue -Name 'Sim3PClient2Secret' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_3_APP_ID' { Set-ConfigValue -Name 'Sim3PClient3AppId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_3_APP_OBJECT_ID' { Set-ConfigValue -Name 'Sim3PClient3AppObjectId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_3_SERVICE_PRINCIPAL_ID' { Set-ConfigValue -Name 'Sim3PClient3ServicePrincipalId' -Value $entry.Value -Source $statePath }
                'SIM_3P_CLIENT_3_SECRET' { Set-ConfigValue -Name 'Sim3PClient3Secret' -Value $entry.Value -Source $statePath }
                'ADME_SIM_INTERNAL_FORCE_TIER2_FALLBACK' { Set-ConfigValue -Name 'AdmeSimInternalForceTier2Fallback' -Value $entry.Value -Source $statePath }
                default { }
            }
        }

        Write-LogStep ("Loaded runtime state from {0}" -f $statePath)
    }
    else {
        Write-Log -Level INFO -Message 'No explicit --state-dir/-StateDir provided; using defaults and environment only'
    }

    if ($null -ne $clientSecretEnvironment -and $clientSecretEnvironment -ne '') {
        Set-ConfigValue -Name 'ClientSecret' -Value $clientSecretEnvironment -Source 'environment'
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'CustomerConfigDir'))) {
        $currentConfigDir = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR')
        if ($null -ne $currentConfigDir -and $currentConfigDir -ne '') {
            Set-ConfigValue -Name 'CustomerConfigDir' -Value $currentConfigDir -Source 'AZURE_CONFIG_DIR'
        }
    }

    $placeholderVariables = New-Object System.Collections.ArrayList
    foreach ($name in @('OldResourceAppId', 'OldResourceIdentifierUri', 'NewResourceAppId', 'NewResourceIdentifierUri')) {
        [void]$placeholderVariables.Add($name)
    }

    switch ($commandKey) {
        'migrate/adme-audience' {
            [void]$placeholderVariables.Add('OldResourceServicePrincipalId')
            [void]$placeholderVariables.Add('NewResourceScopeValue')
        }
        'migrate/api-permissions' {
            [void]$placeholderVariables.Add('NewResourceScopeId')
            [void]$placeholderVariables.Add('NewResourceScopeValue')
        }
        'verify/' {
            [void]$placeholderVariables.Add('OldResourceServicePrincipalId')
            [void]$placeholderVariables.Add('NewResourceScopeValue')
        }
        default {
            throw ("Unsupported command for runtime-state validation: {0}" -f $commandKey)
        }
    }

    foreach ($placeholderName in @($placeholderVariables)) {
        $placeholderValue = [string](Get-ConfigValue -Name $placeholderName)
        if (-not [string]::IsNullOrWhiteSpace($placeholderValue)) {
            Ensure-NotPlaceholder -Name $placeholderName -Value $placeholderValue
        }
    }

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'CustomerTenantId'))) {
        $resolvedTenantId = Get-CurrentTenantId -ConfigDir $customerConfigDir
        if (-not [string]::IsNullOrWhiteSpace($resolvedTenantId)) {
            Set-ConfigValue -Name 'CustomerTenantId' -Value $resolvedTenantId -Source 'resolved from Azure CLI context'
        }
    }

    $configuredOldResourceServicePrincipalId = [string](Get-ConfigValue -Name 'OldResourceServicePrincipalId')
    if (-not [string]::IsNullOrWhiteSpace($configuredOldResourceServicePrincipalId)) {
        $existingOldResourceServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $configuredOldResourceServicePrincipalId -AllowMissing
        if ($null -eq $existingOldResourceServicePrincipal) {
            Write-LogWarn ("Configured OldResourceServicePrincipalId {0} (source: {1}) was not found in tenant {2}; resolving it again from OldResourceAppId {3}" -f $configuredOldResourceServicePrincipalId, (Get-ConfigSource -Name 'OldResourceServicePrincipalId'), (Get-ConfigValue -Name 'CustomerTenantId'), (Get-ConfigValue -Name 'OldResourceAppId'))
            Set-ConfigValue -Name 'OldResourceServicePrincipalId' -Value $null -Source 'unresolved'
        }
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'OldResourceServicePrincipalId'))) {
        $resolvedOldResourceServicePrincipalId = Get-ServicePrincipalIdByAppId -ConfigDir $customerConfigDir -AppId (Get-ConfigValue -Name 'OldResourceAppId')
        if (-not [string]::IsNullOrWhiteSpace($resolvedOldResourceServicePrincipalId)) {
            Set-ConfigValue -Name 'OldResourceServicePrincipalId' -Value $resolvedOldResourceServicePrincipalId -Source 'resolved from OldResourceAppId'
        }
    }

    switch ($commandKey) {
        'migrate/adme-audience' {
            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'CustomerTenantId'))) {
                throw 'CustomerTenantId is required from sim-state.env, environment, or the current Azure CLI context.'
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'OldResourceServicePrincipalId'))) {
                throw ("OldResourceServicePrincipalId could not be resolved for appId {0}" -f (Get-ConfigValue -Name 'OldResourceAppId'))
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'NewResourceScopeValue'))) {
                throw 'NewResourceScopeValue is required from sim-state.env or the environment.'
            }
        }
        'migrate/api-permissions' {
            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'CustomerTenantId'))) {
                throw 'CustomerTenantId is required from sim-state.env, environment, or the current Azure CLI context.'
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'NewResourceScopeId'))) {
                throw 'NewResourceScopeId is required from sim-state.env or the environment.'
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'NewResourceScopeValue'))) {
                throw 'NewResourceScopeValue is required from sim-state.env or the environment.'
            }
        }
        'verify/' {
            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'CustomerTenantId'))) {
                throw 'CustomerTenantId is required from sim-state.env, environment, or the current Azure CLI context.'
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'OldResourceServicePrincipalId'))) {
                throw ("OldResourceServicePrincipalId could not be resolved for appId {0}" -f (Get-ConfigValue -Name 'OldResourceAppId'))
            }

            if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'NewResourceScopeValue'))) {
                throw 'NewResourceScopeValue is required from sim-state.env or the environment.'
            }
        }
    }
}

function Write-ConfigSummary {
    [CmdletBinding()]
    param()

    $summary = @(
        'Config sources:',
        ('  StateDir: {0}' -f (Get-ConfigSource -Name 'StateDir')),
        ('  OutputLogging: {0}' -f (Get-ConfigSource -Name 'OutputLogging')),
        ('  CustomerConfigDir: {0}' -f (Get-ConfigSource -Name 'CustomerConfigDir')),
        ('  HomeConfigDir: {0}' -f (Get-ConfigSource -Name 'HomeConfigDir')),
        ('  CustomerTenantId: {0}' -f (Get-ConfigSource -Name 'CustomerTenantId')),
        ('  OldResourceAppId: {0}' -f (Get-ConfigSource -Name 'OldResourceAppId')),
        ('  OldResourceServicePrincipalId: {0}' -f (Get-ConfigSource -Name 'OldResourceServicePrincipalId')),
        ('  NewResourceAppId: {0}' -f (Get-ConfigSource -Name 'NewResourceAppId')),
        ('  ClientSecret: {0}' -f (Get-ConfigSource -Name 'ClientSecret'))
    )

    Write-Log -Level INFO -Message ($summary -join '; ')
}

function Assert-AzCliAvailable {
    [CmdletBinding()]
    param()

    Ensure-HelperModuleLoaded
    if (-not (Test-AzCliAvailable)) {
        throw "Azure CLI ('az') is required but was not found on PATH. Install Azure CLI or run inside the repo devshell."
    }
}

function Get-OptionalPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Ensure-NotPlaceholder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -like '*<*' -and $Value -like '*>*') {
        throw ("{0} still contains a placeholder value; update it in your config file." -f $Name)
    }
}

function ConvertTo-CompactJson {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-StringArrayValues {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $values = New-Object System.Collections.ArrayList
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text) -or $values -contains $text) {
            continue
        }

        [void]$values.Add($text)
    }

    return @($values)
}

function Test-StringArrayContains {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Values,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedValue
    )

    foreach ($value in @(Get-StringArrayValues -InputObject $Values)) {
        if ($value -eq $ExpectedValue) {
            return $true
        }
    }

    return $false
}

function Test-StringArrayMatchesTarget {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$CurrentValues,

        [AllowNull()]
        [object]$TargetValues
    )

    $current = @(Get-StringArrayValues -InputObject $CurrentValues | Sort-Object)
    $target = @(Get-StringArrayValues -InputObject $TargetValues | Sort-Object)
    if ($current.Count -ne $target.Count) {
        return $false
    }

    for ($index = 0; $index -lt $current.Count; $index++) {
        if ($current[$index] -ne $target[$index]) {
            return $false
        }
    }

    return $true
}

function Get-ServicePrincipalNames {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServicePrincipal
    )

    return Get-StringArrayValues -InputObject (Get-OptionalPropertyValue -InputObject $ServicePrincipal -Name 'servicePrincipalNames')
}

function Test-OldResourceServicePrincipalNamesAreRefreshed {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Names
    )

    $oldIdentifierUri = [string](Get-ConfigValue -Name 'OldResourceIdentifierUri')
    $sharedIdentifierUri = [string](Get-ConfigValue -Name 'NewResourceIdentifierUri')
    return (Test-StringArrayContains -Values $Names -ExpectedValue $oldIdentifierUri) -and -not (Test-StringArrayContains -Values $Names -ExpectedValue $sharedIdentifierUri)
}

function Test-OldResourceServicePrincipalIsRefreshed {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServicePrincipal
    )

    return Test-OldResourceServicePrincipalNamesAreRefreshed -Names (Get-ServicePrincipalNames -ServicePrincipal $ServicePrincipal)
}

function Build-OldResourceTargetServicePrincipalNames {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$CurrentNames
    )

    $targetNames = New-Object System.Collections.ArrayList
    $sharedIdentifierUri = [string](Get-ConfigValue -Name 'NewResourceIdentifierUri')
    $oldIdentifierUri = [string](Get-ConfigValue -Name 'OldResourceIdentifierUri')

    foreach ($name in @(Get-StringArrayValues -InputObject $CurrentNames)) {
        if ($name -eq $sharedIdentifierUri -or $targetNames -contains $name) {
            continue
        }

        [void]$targetNames.Add($name)
    }

    if (-not ($targetNames -contains $oldIdentifierUri)) {
        [void]$targetNames.Add($oldIdentifierUri)
    }

    return @($targetNames)
}

function Test-NewResourceServicePrincipalOwnsSharedAudience {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServicePrincipal
    )

    return Test-StringArrayContains -Values (Get-ServicePrincipalNames -ServicePrincipal $ServicePrincipal) -ExpectedValue ([string](Get-ConfigValue -Name 'NewResourceIdentifierUri'))
}

function New-RefreshProbeTag {
    [CmdletBinding()]
    param()

    return 'ADME.RefreshProbe.{0}.{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $PID
}

function Format-ServicePrincipalNamesPatchError {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return '<no error details>'
    }

    if ($ErrorMessage -like '*Property servicePrincipalNames on the service principal does not match the application object*') {
        return 'Graph rejected the direct repair because servicePrincipalNames are controlled by the home application object. Direct PATCH cannot fix this tenant state; use the default safe stop or the approved delete/recreate fallback.'
    }

    return $ErrorMessage
}

function Test-TruthyString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    switch ($Value) {
        '1' { return $true }
        'true' { return $true }
        'TRUE' { return $true }
        'yes' { return $true }
        'YES' { return $true }
        default { return $false }
    }
}

function Test-GuidString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsedGuid = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsedGuid)
}

function Test-GraphPermissionEnabled {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Permission
    )

    $isEnabled = Get-OptionalPropertyValue -InputObject $Permission -Name 'isEnabled'
    if ($null -eq $isEnabled) {
        return $true
    }

    return [bool]$isEnabled
}

function Get-RequiredResourceAccessCollection {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Application
    )

    $requiredResourceAccess = Get-OptionalPropertyValue -InputObject $Application -Name 'requiredResourceAccess'
    if ($null -eq $requiredResourceAccess) {
        return @()
    }

    return @($requiredResourceAccess)
}

function Get-ResourceAccessCollection {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$RequiredResourceAccess
    )

    $resourceAccess = Get-OptionalPropertyValue -InputObject $RequiredResourceAccess -Name 'resourceAccess'
    if ($null -eq $resourceAccess) {
        return @()
    }

    return @($resourceAccess)
}

function Resolve-SelectedClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $clientIdInput = [string]$script:Options.SelectedClientId
    if ([string]::IsNullOrWhiteSpace($clientIdInput)) {
        throw ("--client-id is required for '{0}'" -f $Purpose)
    }

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $servicePrincipal = $null
    if (Test-GuidString -Value $clientIdInput) {
        $servicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $clientIdInput -AllowMissing
    }

    if ($null -ne $servicePrincipal) {
        Set-ConfigValue -Name 'ClientServicePrincipalId' -Value ([string](Get-OptionalPropertyValue -InputObject $servicePrincipal -Name 'id')) -Source 'resolved from --client-id servicePrincipalId'
        Set-ConfigValue -Name 'ClientAppId' -Value ([string](Get-OptionalPropertyValue -InputObject $servicePrincipal -Name 'appId')) -Source 'resolved from --client-id servicePrincipalId'
    }
    else {
        Set-ConfigValue -Name 'ClientAppId' -Value $clientIdInput -Source '--client-id'
        $resolvedClientServicePrincipalId = Get-ServicePrincipalIdByAppId -ConfigDir $customerConfigDir -AppId $clientIdInput
        if ([string]::IsNullOrWhiteSpace($resolvedClientServicePrincipalId)) {
            throw ("No client service principal found for --client-id '{0}'. Pass a client appId or client servicePrincipalId from the customer tenant." -f $clientIdInput)
        }

        Set-ConfigValue -Name 'ClientServicePrincipalId' -Value $resolvedClientServicePrincipalId -Source 'resolved from --client-id appId'
        $servicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $resolvedClientServicePrincipalId
    }

    $clientAppId = [string](Get-ConfigValue -Name 'ClientAppId')
    $clientServicePrincipalId = [string](Get-ConfigValue -Name 'ClientServicePrincipalId')
    if ([string]::IsNullOrWhiteSpace($clientAppId)) {
        throw ("Resolved client service principal '{0}' is missing appId" -f $clientIdInput)
    }

    if ([string]::IsNullOrWhiteSpace($clientServicePrincipalId)) {
        throw ("Unable to resolve client servicePrincipalId from --client-id '{0}'" -f $clientIdInput)
    }

    $application = Get-ApplicationByAppId -ConfigDir $customerConfigDir -AppId $clientAppId
    if ($null -eq $application) {
        throw ("No customer-owned application registration found for client appId '{0}'. {1} requires a local app registration." -f $clientAppId, $Purpose)
    }

    $clientAppObjectId = [string](Get-OptionalPropertyValue -InputObject $application -Name 'id')
    if ([string]::IsNullOrWhiteSpace($clientAppObjectId)) {
        throw ("Resolved client app '{0}' is missing application object id" -f $clientAppId)
    }

    Set-ConfigValue -Name 'ClientAppObjectId' -Value $clientAppObjectId -Source 'resolved from client appId'
    $selectedDisplayName = [string](Get-OptionalPropertyValue -InputObject $application -Name 'displayName')
    if ([string]::IsNullOrWhiteSpace($selectedDisplayName)) {
        $selectedDisplayName = '<unnamed>'
    }

    Write-Log -Level INFO -Message ("Resolved --client-id '{0}' to client app '{1}'" -f $clientIdInput, $selectedDisplayName)
    Write-Log -Level INFO -Message ("  client appId: {0}" -f $clientAppId)
    Write-Log -Level INFO -Message ("  client applicationObjectId: {0}" -f $clientAppObjectId)
    Write-Log -Level INFO -Message ("  client servicePrincipalId: {0}" -f $clientServicePrincipalId)
}

function Resolve-TargetResourcePermissionContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId
    )

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $targetResourceServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $ResourceServicePrincipalId
    $scopeId = [string](Get-ConfigValue -Name 'NewResourceScopeId')
    $scopeValue = [string](Get-ConfigValue -Name 'NewResourceScopeValue')
    $roleId = [string](Get-ConfigValue -Name 'NewResourceAppRoleId')
    $roleValue = [string](Get-ConfigValue -Name 'NewResourceAppRoleValue')

    $enabledScopeCount = 0
    $configuredScopeFound = $false
    foreach ($scope in @((Get-OptionalPropertyValue -InputObject $targetResourceServicePrincipal -Name 'oauth2PermissionScopes'))) {
        if ($null -eq $scope) {
            continue
        }

        if (Test-GraphPermissionEnabled -Permission $scope) {
            $enabledScopeCount++
            if ([string](Get-OptionalPropertyValue -InputObject $scope -Name 'id') -eq $scopeId -and
                [string](Get-OptionalPropertyValue -InputObject $scope -Name 'value') -eq $scopeValue) {
                $configuredScopeFound = $true
            }
        }
    }

    if (-not $configuredScopeFound) {
        throw ("Target resource service principal {0} does not expose enabled scope '{1}' ({2})" -f $ResourceServicePrincipalId, $scopeValue, $scopeId)
    }

    $enabledAppRoleCount = 0
    $configuredAppRoleFound = $false
    foreach ($appRole in @((Get-OptionalPropertyValue -InputObject $targetResourceServicePrincipal -Name 'appRoles'))) {
        if ($null -eq $appRole) {
            continue
        }

        if (Test-GraphPermissionEnabled -Permission $appRole) {
            $enabledAppRoleCount++
            if ([string](Get-OptionalPropertyValue -InputObject $appRole -Name 'id') -eq $roleId -and
                [string](Get-OptionalPropertyValue -InputObject $appRole -Name 'value') -eq $roleValue) {
                $configuredAppRoleFound = $true
            }
        }
    }

    $requiresAppRole = $enabledAppRoleCount -gt 0
    if ($requiresAppRole) {
        if ([string]::IsNullOrWhiteSpace($roleId)) {
            throw ("NewResourceAppRoleId is required because target resource service principal {0} exposes enabled app roles" -f $ResourceServicePrincipalId)
        }

        if ([string]::IsNullOrWhiteSpace($roleValue)) {
            throw ("NewResourceAppRoleValue is required because target resource service principal {0} exposes enabled app roles" -f $ResourceServicePrincipalId)
        }

        if (-not $configuredAppRoleFound) {
            throw ("Target resource service principal {0} does not expose enabled app role '{1}' ({2})" -f $ResourceServicePrincipalId, $roleValue, $roleId)
        }
    }

    $permissionShape = if ($requiresAppRole) { 'Role + Scope' } else { 'Scope-only' }
    Write-Log -Level INFO -Message ("Target resource capabilities: permissionShape={0} enabledAppRoles={1} enabledScopes={2}" -f $permissionShape, $enabledAppRoleCount, $enabledScopeCount)

    return [pscustomobject]@{
        RequiresAppRole = $requiresAppRole
        PermissionShape = $permissionShape
        EnabledAppRoleCount = $enabledAppRoleCount
        EnabledScopeCount = $enabledScopeCount
    }
}

function ConvertTo-NormalizedUnrelatedRequiredResourceAccessJson {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$RequiredResourceAccess,

        [Parameter(Mandatory = $true)]
        [string]$OldResourceAppId,

        [Parameter(Mandatory = $true)]
        [string]$NewResourceAppId
    )

    $normalizedEntries = New-Object System.Collections.ArrayList
    foreach ($entry in @($RequiredResourceAccess)) {
        $resourceAppId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'resourceAppId')
        if ([string]::IsNullOrWhiteSpace($resourceAppId) -or $resourceAppId -eq $OldResourceAppId -or $resourceAppId -eq $NewResourceAppId) {
            continue
        }

        $normalizedAccess = New-Object System.Collections.ArrayList
        foreach ($resourceAccess in @(Get-ResourceAccessCollection -RequiredResourceAccess $entry)) {
            $id = [string](Get-OptionalPropertyValue -InputObject $resourceAccess -Name 'id')
            $type = [string](Get-OptionalPropertyValue -InputObject $resourceAccess -Name 'type')
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($type)) {
                continue
            }

            [void]$normalizedAccess.Add([pscustomobject][ordered]@{
                id = $id
                type = $type
            })
        }

        $sortedAccess = @($normalizedAccess.ToArray() | Sort-Object -Property type, id)
        [void]$normalizedEntries.Add([pscustomobject][ordered]@{
            resourceAppId = $resourceAppId
            resourceAccess = @($sortedAccess)
        })
    }

    $sortedEntries = @($normalizedEntries.ToArray() | Sort-Object -Property resourceAppId)
    if ($sortedEntries.Count -eq 0) {
        return '[]'
    }

    return (ConvertTo-Json -InputObject @($sortedEntries) -Depth 20 -Compress)
}

function Test-RequiredResourceAccessMatchesNewResource {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$RequiredResourceAccess,

        [AllowNull()]
        [object]$BaselineRequiredResourceAccess,

        [Parameter(Mandatory = $true)]
        [bool]$RequiresAppRole
    )

    $oldResourceAppId = [string](Get-ConfigValue -Name 'OldResourceAppId')
    $newResourceAppId = [string](Get-ConfigValue -Name 'NewResourceAppId')
    $scopeId = [string](Get-ConfigValue -Name 'NewResourceScopeId')
    $roleId = [string](Get-ConfigValue -Name 'NewResourceAppRoleId')

    $newEntries = @()
    foreach ($entry in @($RequiredResourceAccess)) {
        $resourceAppId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'resourceAppId')
        if ($resourceAppId -eq $oldResourceAppId) {
            return $false
        }

        if ($resourceAppId -eq $newResourceAppId) {
            $newEntries += $entry
        }
    }

    if ($newEntries.Count -ne 1) {
        return $false
    }

    $hasScope = $false
    $hasRole = $false
    $hasAnyRole = $false
    foreach ($resourceAccess in @(Get-ResourceAccessCollection -RequiredResourceAccess $newEntries[0])) {
        $id = [string](Get-OptionalPropertyValue -InputObject $resourceAccess -Name 'id')
        $type = [string](Get-OptionalPropertyValue -InputObject $resourceAccess -Name 'type')
        if ($id -eq $scopeId -and $type -eq 'Scope') {
            $hasScope = $true
        }

        if ($type -eq 'Role') {
            $hasAnyRole = $true
            if ($id -eq $roleId) {
                $hasRole = $true
            }
        }
    }

    if (-not $hasScope) {
        return $false
    }

    if ($RequiresAppRole) {
        if (-not $hasRole) {
            return $false
        }
    }
    elseif ($hasAnyRole) {
        return $false
    }

    $currentUnrelated = ConvertTo-NormalizedUnrelatedRequiredResourceAccessJson -RequiredResourceAccess $RequiredResourceAccess -OldResourceAppId $oldResourceAppId -NewResourceAppId $newResourceAppId
    $baselineUnrelated = ConvertTo-NormalizedUnrelatedRequiredResourceAccessJson -RequiredResourceAccess $BaselineRequiredResourceAccess -OldResourceAppId $oldResourceAppId -NewResourceAppId $newResourceAppId
    return $currentUnrelated -eq $baselineUnrelated
}

function Update-ClientApplicationRequiredResourceAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RequiresAppRole
    )

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $clientAppObjectId = [string](Get-ConfigValue -Name 'ClientAppObjectId')
    $currentApplication = Get-ApplicationById -ConfigDir $customerConfigDir -ApplicationObjectId $clientAppObjectId
    $currentRequiredResourceAccess = @(Get-RequiredResourceAccessCollection -Application $currentApplication)
    Write-Log -Level INFO -Message ("Current client app requiredResourceAccess: {0}" -f (ConvertTo-CompactJson -Value $currentRequiredResourceAccess))

    if (Test-RequiredResourceAccessMatchesNewResource -RequiredResourceAccess $currentRequiredResourceAccess -BaselineRequiredResourceAccess $currentRequiredResourceAccess -RequiresAppRole $RequiresAppRole) {
        Write-Log -Level INFO -Message 'client app requiredResourceAccess already references new resource (bd0c)'
        return
    }

    $desiredRequiredResourceAccess = @(Build-RequiredResourceAccess `
        -CurrentRequiredResourceAccess $currentRequiredResourceAccess `
        -OldResourceAppId ([string](Get-ConfigValue -Name 'OldResourceAppId')) `
        -NewResourceAppId ([string](Get-ConfigValue -Name 'NewResourceAppId')) `
        -NewResourceScopeId ([string](Get-ConfigValue -Name 'NewResourceScopeId')) `
        -NewResourceAppRoleId ([string](Get-ConfigValue -Name 'NewResourceAppRoleId')) `
        -IncludeAppRole:$RequiresAppRole)

    Update-ApplicationRequiredResourceAccess -ConfigDir $customerConfigDir -ApplicationObjectId $clientAppObjectId -RequiredResourceAccess $desiredRequiredResourceAccess

    $updatedApplication = Get-ApplicationById -ConfigDir $customerConfigDir -ApplicationObjectId $clientAppObjectId
    $updatedRequiredResourceAccess = @(Get-RequiredResourceAccessCollection -Application $updatedApplication)
    if (-not (Test-RequiredResourceAccessMatchesNewResource -RequiredResourceAccess $updatedRequiredResourceAccess -BaselineRequiredResourceAccess $currentRequiredResourceAccess -RequiresAppRole $RequiresAppRole)) {
        throw 'client app requiredResourceAccess did not update to new resource (bd0c) while preserving unrelated entries'
    }

    Write-LogSuccess 'Updated client app requiredResourceAccess to new resource (bd0c)'
    Write-Log -Level INFO -Message ("Updated client app requiredResourceAccess: {0}" -f (ConvertTo-CompactJson -Value $updatedRequiredResourceAccess))
}

function Write-CustomerAppAdminConsentGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RequiresAppRole
    )

    if ($RequiresAppRole) {
        Write-Log -Level INFO -Message 'Complete one tenant-wide admin-consent action for the updated customer app to grant both the target-resource app role and delegated scope.'
    }
    else {
        Write-Log -Level INFO -Message 'Complete one tenant-wide admin-consent action for the updated customer app to grant the target-resource delegated scope.'
    }

    Write-Log -Level INFO -Message 'Azure portal: App registrations -> client app -> API permissions -> Grant admin consent'
    Write-Log -Level INFO -Message ("Portal link: {0}" -f (Get-ConfigValue -Name 'AppRegistrationsPortalUrl'))
    Write-Log -Level INFO -Message ("Locate the client app by appId: {0}" -f (Get-ConfigValue -Name 'ClientAppId'))
}

function Assert-InternalTier2FallbackFixture {
    [CmdletBinding()]
    param()

    $stateJsonFile = [string](Get-ConfigValue -Name 'StateJsonFile')
    if ([string]::IsNullOrWhiteSpace($stateJsonFile)) {
        throw 'AdmeSimInternalForceTier2Fallback is only supported with simulator state; StateJsonFile is not set.'
    }

    if (-not (Test-Path -LiteralPath $stateJsonFile -PathType Leaf)) {
        throw ("AdmeSimInternalForceTier2Fallback is only supported with simulator state; file not found: {0}" -f $stateJsonFile)
    }

    $state = [IO.File]::ReadAllText($stateJsonFile) | ConvertFrom-Json
    $forceTier2Fallback = Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $state -Name 'internal') -Name 'forceTier2Fallback'
    $simDffa = Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $state -Name 'apps') -Name 'simDffa'
    $simDffaAppId = [string](Get-OptionalPropertyValue -InputObject $simDffa -Name 'appId')

    if (-not [bool]$forceTier2Fallback -or $simDffaAppId -ne [string](Get-ConfigValue -Name 'OldResourceAppId')) {
        throw 'AdmeSimInternalForceTier2Fallback is only supported for simulator state created by the internal simulator with that flag enabled.'
    }
}

function Test-HomeTenantContextIsUsable {
    [CmdletBinding()]
    param()

    $homeConfigDir = [string](Get-ConfigValue -Name 'HomeConfigDir')
    if ([string]::IsNullOrWhiteSpace($homeConfigDir)) {
        return $false
    }

    $expectedHomeTenantId = [string](Get-ConfigValue -Name 'HomeTenantId')
    if ([string]::IsNullOrWhiteSpace($expectedHomeTenantId)) {
        return $true
    }

    try {
        $actualHomeTenantId = Get-CurrentTenantId -ConfigDir $homeConfigDir
    }
    catch {
        Write-LogWarn 'HOME_CONFIG_DIR is set, but Azure CLI home-tenant context could not be read; direct repair will use customer-tenant state only.'
        return $false
    }

    if ($actualHomeTenantId -ne $expectedHomeTenantId) {
        Write-LogWarn ("HOME_CONFIG_DIR points to tenant {0}, expected home tenant {1}; direct repair will use customer-tenant state only." -f $actualHomeTenantId, $expectedHomeTenantId)
        return $false
    }

    return $true
}

function Get-ApplicationServicePrincipalNames {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Application
    )

    $names = New-Object System.Collections.ArrayList
    $appId = [string](Get-OptionalPropertyValue -InputObject $Application -Name 'appId')
    if (-not [string]::IsNullOrWhiteSpace($appId)) {
        [void]$names.Add($appId)
    }

    foreach ($identifierUri in @(Get-StringArrayValues -InputObject (Get-OptionalPropertyValue -InputObject $Application -Name 'identifierUris'))) {
        if (-not ($names -contains $identifierUri)) {
            [void]$names.Add($identifierUri)
        }
    }

    return @($names)
}

function Get-HomeApplicationServicePrincipalNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    if (-not (Test-HomeTenantContextIsUsable)) {
        return $null
    }

    try {
        $application = Get-ApplicationByAppId -ConfigDir (Get-ConfigValue -Name 'HomeConfigDir') -AppId $AppId
    }
    catch {
        Write-LogWarn ("Home-tenant application metadata for {0} appId {1} was not available; direct repair will use customer-tenant state only." -f $Label, $AppId)
        return $null
    }

    if ($null -eq $application) {
        Write-LogWarn ("Home-tenant application metadata for {0} appId {1} was not available; direct repair will use customer-tenant state only." -f $Label, $AppId)
        return $null
    }

    return Get-ApplicationServicePrincipalNames -Application $application
}

function Assert-CustomerTenantContext {
    [CmdletBinding()]
    param()

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $expectedTenantId = [string](Get-ConfigValue -Name 'CustomerTenantId')
    $actualTenantId = Get-CurrentTenantId -ConfigDir $customerConfigDir
    if ($actualTenantId -ne $expectedTenantId) {
        throw ("Customer Azure CLI context is tenant {0}, expected {1}" -f $actualTenantId, $expectedTenantId)
    }

    Write-LogSuccess ("Customer Azure CLI context is ready for tenant {0}" -f $expectedTenantId)
}

function Get-CurrentPrincipalInfo {
    [CmdletBinding()]
    param()

    $tokenResponse = Invoke-AzCliCommand -ConfigDir (Get-ConfigValue -Name 'CustomerConfigDir') -Arguments @('account', 'get-access-token', '--resource-type', 'ms-graph', '-o', 'json')
    $accessToken = [string](Get-OptionalPropertyValue -InputObject $tokenResponse -Name 'accessToken')
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'Could not acquire a Microsoft Graph token for role validation.'
    }

    $claims = ConvertFrom-JwtPayload -Token $accessToken
    $principalObjectId = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'oid')
    if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
        throw 'Could not resolve the current principal object ID from the Microsoft Graph token.'
    }

    $principalType = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'idtyp')
    if ([string]::IsNullOrWhiteSpace($principalType)) {
        $principalType = 'user'
    }

    return [pscustomobject]@{
        ObjectId = $principalObjectId
        PrincipalType = $principalType
    }
}

function Get-CurrentPrincipalRoleNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalObjectId
    )

    $response = Invoke-GraphRequest -Method GET -ConfigDir (Get-ConfigValue -Name 'CustomerConfigDir') -Uri ("/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '{0}'&`$expand=roleDefinition" -f $PrincipalObjectId)
    $roleNames = New-Object System.Collections.ArrayList
    foreach ($assignment in @($response.value)) {
        $roleDefinition = Get-OptionalPropertyValue -InputObject $assignment -Name 'roleDefinition'
        $displayName = [string](Get-OptionalPropertyValue -InputObject $roleDefinition -Name 'displayName')
        if ([string]::IsNullOrWhiteSpace($displayName) -or $roleNames -contains $displayName) {
            continue
        }

        [void]$roleNames.Add($displayName)
    }

    return @($roleNames)
}

function Assert-TenantAdminRole {
    [CmdletBinding()]
    param()

    $principalInfo = Get-CurrentPrincipalInfo
    $roleNames = @(Get-CurrentPrincipalRoleNames -PrincipalObjectId $principalInfo.ObjectId)
    if ($roleNames.Count -eq 0) {
        throw ("Current {0} principal {1} does not have an active Application Administrator, Cloud Application Administrator, or Global Administrator role assignment in tenant {2}" -f $principalInfo.PrincipalType, $principalInfo.ObjectId, (Get-ConfigValue -Name 'CustomerTenantId'))
    }

    foreach ($requiredRoleName in $script:RequiredRoleNames) {
        if ($roleNames -contains $requiredRoleName) {
            Write-LogSuccess ("Current {0} principal {1} has required role '{2}'" -f $principalInfo.PrincipalType, $principalInfo.ObjectId, $requiredRoleName)
            return
        }
    }

    throw ("Current {0} principal {1} is missing the required role. Found: {2}" -f $principalInfo.PrincipalType, $principalInfo.ObjectId, ($roleNames -join ', '))
}

function Invoke-MigrateAdmeAudience {
    [CmdletBinding()]
    param()

    Write-LogStep 'Loading runtime state and validating adme-audience prerequisites'
    Load-RuntimeState
    Write-ConfigSummary
    Assert-CustomerTenantContext
    Assert-TenantAdminRole

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $customerTenantId = [string](Get-ConfigValue -Name 'CustomerTenantId')
    $oldResourceServicePrincipalId = [string](Get-ConfigValue -Name 'OldResourceServicePrincipalId')
    $oldResourceAppId = [string](Get-ConfigValue -Name 'OldResourceAppId')
    $newResourceAppId = [string](Get-ConfigValue -Name 'NewResourceAppId')
    $newResourceIdentifierUri = [string](Get-ConfigValue -Name 'NewResourceIdentifierUri')
    $oldResourceIdentifierUri = [string](Get-ConfigValue -Name 'OldResourceIdentifierUri')
    $newResourceScopeValue = [string](Get-ConfigValue -Name 'NewResourceScopeValue')
    $internalForceTier2Fallback = Test-TruthyString -Value ([string](Get-ConfigValue -Name 'AdmeSimInternalForceTier2Fallback'))

    if ($internalForceTier2Fallback) {
        Assert-InternalTier2FallbackFixture
        Write-LogWarn 'INTERNAL SIMULATION MODE: forcing migrate adme-audience past the probe-tag refresh path to exercise direct servicePrincipalNames repair.'
    }

    $dffaCustomerServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId
    $probeStartDffaServicePrincipal = $dffaCustomerServicePrincipal
    $probeStartDffaServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $probeStartDffaServicePrincipal
    if ($internalForceTier2Fallback -and (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $probeStartDffaServicePrincipal)) {
        throw ("Internal direct-repair fallback fixture expected stale old resource (dffa) servicePrincipalNames before the probe-tag refresh, but the customer service principal is already refreshed: {0}" -f (ConvertTo-CompactJson -Value $probeStartDffaServicePrincipalNames))
    }

    $originalTags = Get-StringArrayValues -InputObject (Get-OptionalPropertyValue -InputObject $dffaCustomerServicePrincipal -Name 'tags')

    Write-Log -Level INFO -Message 'Preflight:'
    Write-Log -Level INFO -Message ("  customer tenant: {0}" -f $customerTenantId)
    Write-Log -Level INFO -Message ("  old resource (dffa) customer servicePrincipalId: {0}" -f $oldResourceServicePrincipalId)
    Write-Log -Level INFO -Message ("  expected refreshed old resource (dffa) identifierUri: {0}" -f $oldResourceIdentifierUri)
    Write-Log -Level INFO -Message ("  new resource (bd0c) appId to provision in customer tenant: {0}" -f $newResourceAppId)
    Write-Log -Level INFO -Message ("  expected new resource (bd0c) identifierUri: {0}" -f $newResourceIdentifierUri)
    if ($script:Options.AllowRecreateDffa) {
        Write-Log -Level INFO -Message '  fallback mode: --allow-recreate-dffa enabled'
    }
    else {
        Write-Log -Level INFO -Message '  fallback mode: default safe stop if refresh remains stale'
    }

    Confirm-IfNeeded -ActionLabel 'adme-audience migration'

    $probeTag = New-RefreshProbeTag
    $patchedTags = Get-StringArrayValues -InputObject (@($originalTags) + @($probeTag))
    $probeTagApplied = $false
    $refreshSucceeded = $false
    $refreshedDffaServicePrincipal = $probeStartDffaServicePrincipal
    $refreshedDffaServicePrincipalNames = $probeStartDffaServicePrincipalNames

    try {
        Write-LogStep 'Applying a temporary refresh probe tag to the stale old resource (dffa) customer service principal'
        Update-ServicePrincipalTags -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId -Tags $patchedTags
        $probeTagApplied = $true
        Write-LogSuccess ("Applied refresh probe tag {0}" -f $probeTag)

        Write-LogStep 'Polling for the refreshed old resource (dffa) servicePrincipalNames'
        for ($refreshAttempt = 1; $refreshAttempt -le 3; $refreshAttempt++) {
            $refreshedDffaServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId
            $refreshedDffaServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $refreshedDffaServicePrincipal
            if (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $refreshedDffaServicePrincipal) {
                if ($internalForceTier2Fallback) {
                    Write-LogWarn ("INTERNAL SIMULATION MODE: probe-tag refresh reached target state on attempt {0}; treating it as stale to exercise direct servicePrincipalNames repair." -f $refreshAttempt)
                    $refreshedDffaServicePrincipal = $probeStartDffaServicePrincipal
                    $refreshedDffaServicePrincipalNames = $probeStartDffaServicePrincipalNames
                    break
                }

                Write-LogSuccess ("old resource (dffa) customer servicePrincipalNames refreshed on attempt {0}: {1}" -f $refreshAttempt, (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
                $refreshSucceeded = $true
                break
            }

            Write-Log -Level INFO -Message ("old resource (dffa) customer servicePrincipalNames not refreshed on attempt {0}/3 yet: {1}" -f $refreshAttempt, (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
            if ($refreshAttempt -lt 3) {
                Start-Sleep -Seconds 5
            }
        }
    }
    finally {
        if ($probeTagApplied) {
            try {
                Write-LogStep 'Removing the temporary refresh probe tag'
                Update-ServicePrincipalTags -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId -Tags $originalTags
                Write-LogSuccess ("Removed refresh probe tag {0}" -f $probeTag)
            }
            catch {
                Write-LogWarn ("Failed to remove refresh probe tag {0}: {1}" -f $probeTag, $_.Exception.Message)
            }
        }
    }

    if (-not $refreshSucceeded) {
        if ($internalForceTier2Fallback) {
            $refreshedDffaServicePrincipal = $probeStartDffaServicePrincipal
            $refreshedDffaServicePrincipalNames = $probeStartDffaServicePrincipalNames
            Write-LogWarn ("INTERNAL SIMULATION MODE: old resource (dffa) customer servicePrincipalNames intentionally treated as stale after the probe-tag refresh path: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
        }
        else {
            Write-LogWarn ("old resource (dffa) customer servicePrincipalNames remained stale after 3 refresh attempts: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
        }

        $directRepairTargetDffaServicePrincipalNames = Build-OldResourceTargetServicePrincipalNames -CurrentNames $refreshedDffaServicePrincipalNames
        $homeDffaServicePrincipalNames = Get-HomeApplicationServicePrincipalNames -Label 'old resource (dffa)' -AppId $oldResourceAppId
        if ($null -ne $homeDffaServicePrincipalNames) {
            Write-Log -Level INFO -Message ("Home old resource (dffa) application canonical servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $homeDffaServicePrincipalNames))
            if (-not (Test-OldResourceServicePrincipalNamesAreRefreshed -Names $homeDffaServicePrincipalNames)) {
                throw ("Home old resource (dffa) application metadata does not advertise the expected migrated state. Expected it to include {0} and not include {1}. Direct repair and delete/recreate cannot fix the customer tenant until the home-tenant application metadata is updated." -f $oldResourceIdentifierUri, $newResourceIdentifierUri)
            }

            $directRepairTargetDffaServicePrincipalNames = $homeDffaServicePrincipalNames
        }

        Write-Log -Level INFO -Message ("Direct repair current old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
        Write-Log -Level INFO -Message ("Direct repair target old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $directRepairTargetDffaServicePrincipalNames))

        if (Test-StringArrayMatchesTarget -CurrentValues $refreshedDffaServicePrincipalNames -TargetValues $directRepairTargetDffaServicePrincipalNames) {
            $refreshSucceeded = $true
            Write-LogSuccess 'Direct repair skipped PATCH because old resource (dffa) servicePrincipalNames already match the target set'
        }
        else {
            Write-LogStep 'Trying direct servicePrincipalNames repair on the stale old resource (dffa) customer service principal'
            $directRepairResult = Update-ServicePrincipalNames -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId -ServicePrincipalNames $directRepairTargetDffaServicePrincipalNames
            if (-not $directRepairResult.Success) {
                Write-LogWarn ("Direct servicePrincipalNames repair failed: {0}" -f (Format-ServicePrincipalNamesPatchError -ErrorMessage $directRepairResult.ErrorMessage))
            }
            else {
                $refreshedDffaServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId
                $refreshedDffaServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $refreshedDffaServicePrincipal
                if (Test-StringArrayMatchesTarget -CurrentValues $refreshedDffaServicePrincipalNames -TargetValues $directRepairTargetDffaServicePrincipalNames) {
                    $refreshSucceeded = $true
                    Write-LogSuccess ("Direct repair updated old resource (dffa) servicePrincipalNames to target set: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
                }
                else {
                    Write-LogWarn ("Direct repair verification failed; old resource (dffa) servicePrincipalNames remain off-target: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
                }
            }
        }

        if (-not $refreshSucceeded -and -not $script:Options.AllowRecreateDffa) {
            throw 'old resource (dffa) customer servicePrincipalNames remained stale after the probe-tag refresh and direct servicePrincipalNames repair. Default mode stops before delete/recreate and before provisioning new resource (bd0c). Review output-logging/ and rerun with: ./Invoke-AdmeMigration.ps1 --yes migrate adme-audience --allow-recreate-dffa'
        }

        if (-not $refreshSucceeded) {
            if (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $refreshedDffaServicePrincipal) {
                throw 'Refusing delete/recreate because the old resource (dffa) servicePrincipalNames already match the target state.'
            }

            Write-LogStep 'Preparing the bounded delete/recreate fallback for the stale old resource (dffa) service principal'
            Write-Log -Level INFO -Message ("Before recreate old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $refreshedDffaServicePrincipalNames))
            Confirm-DestructiveIfNeeded -ActionLabel 'deleting and recreating the stale old resource (dffa) customer service principal'

            Remove-ServicePrincipal -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId
            Write-LogSuccess ("Deleted customer old resource (dffa) service principal {0}" -f $oldResourceServicePrincipalId)

            $oldResourceServicePrincipalId = Ensure-ServicePrincipal -ConfigDir $customerConfigDir -TenantId $customerTenantId -AppId $oldResourceAppId
            $oldResourceServicePrincipalId = Wait-ServicePrincipal -ConfigDir $customerConfigDir -AppId $oldResourceAppId
            Set-ConfigValue -Name 'OldResourceServicePrincipalId' -Value $oldResourceServicePrincipalId -Source 'recreated during migrate adme-audience'

            $recreatedDffaServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $oldResourceServicePrincipalId
            $recreatedDffaServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $recreatedDffaServicePrincipal
            Write-Log -Level INFO -Message ("After recreate old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $recreatedDffaServicePrincipalNames))
            if (-not (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $recreatedDffaServicePrincipal)) {
                throw ("Recreated old resource (dffa) servicePrincipalNames still include {0}; stop and review the home-tenant application metadata before retrying." -f $newResourceIdentifierUri)
            }

            Write-LogSuccess ("Verified recreated old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $recreatedDffaServicePrincipalNames))
            $refreshedDffaServicePrincipal = $recreatedDffaServicePrincipal
            $refreshedDffaServicePrincipalNames = $recreatedDffaServicePrincipalNames
            $refreshSucceeded = $true
        }
    }

    Write-LogStep 'Ensuring new resource (bd0c) exists in the customer tenant'
    $bd0cCustomerServicePrincipalId = Ensure-ServicePrincipal -ConfigDir $customerConfigDir -TenantId $customerTenantId -AppId $newResourceAppId
    $bd0cCustomerServicePrincipalId = Wait-ServicePrincipal -ConfigDir $customerConfigDir -AppId $newResourceAppId
    $bd0cCustomerServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $bd0cCustomerServicePrincipalId
    $bd0cCustomerServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $bd0cCustomerServicePrincipal

    if (-not (Test-NewResourceServicePrincipalOwnsSharedAudience -ServicePrincipal $bd0cCustomerServicePrincipal)) {
        $homeBd0cServicePrincipalNames = Get-HomeApplicationServicePrincipalNames -Label 'new resource (bd0c)' -AppId $newResourceAppId
        if ($null -ne $homeBd0cServicePrincipalNames) {
            Write-Log -Level INFO -Message ("Home new resource (bd0c) application canonical servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $homeBd0cServicePrincipalNames))
            if (-not (Test-StringArrayContains -Values $homeBd0cServicePrincipalNames -ExpectedValue $newResourceIdentifierUri)) {
                throw ("Home new resource (bd0c) application metadata does not advertise {0}. Update the home-tenant application metadata before retrying." -f $newResourceIdentifierUri)
            }

            Write-LogStep 'Updating customer new resource (bd0c) servicePrincipalNames from home-tenant application metadata'
            $bd0cRepairResult = Update-ServicePrincipalNames -ConfigDir $customerConfigDir -ServicePrincipalId $bd0cCustomerServicePrincipalId -ServicePrincipalNames $homeBd0cServicePrincipalNames
            if (-not $bd0cRepairResult.Success) {
                throw ("customer new resource (bd0c) servicePrincipalNames do not include {0}, and direct repair from home-tenant application metadata failed: {1}" -f $newResourceIdentifierUri, (Format-ServicePrincipalNamesPatchError -ErrorMessage $bd0cRepairResult.ErrorMessage))
            }

            $bd0cCustomerServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $bd0cCustomerServicePrincipalId
            $bd0cCustomerServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $bd0cCustomerServicePrincipal
        }
    }

    if (-not (Test-NewResourceServicePrincipalOwnsSharedAudience -ServicePrincipal $bd0cCustomerServicePrincipal)) {
        throw ("customer new resource (bd0c) servicePrincipalNames do not include {0}" -f $newResourceIdentifierUri)
    }

    Write-LogSuccess ("Verified customer new resource (bd0c) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $bd0cCustomerServicePrincipalNames))

    Write-LogStep 'Ensuring Azure CLI can request the new resource (bd0c) delegated scope non-interactively'
    $azureCliCustomerServicePrincipalId = Ensure-ServicePrincipal -ConfigDir $customerConfigDir -TenantId $customerTenantId -AppId (Get-ConfigValue -Name 'AzureCliAppId')
    $azureCliCustomerServicePrincipalId = Wait-ServicePrincipal -ConfigDir $customerConfigDir -AppId (Get-ConfigValue -Name 'AzureCliAppId')
    $grantResult = Ensure-OAuth2PermissionGrant -ConfigDir $customerConfigDir -ClientServicePrincipalId $azureCliCustomerServicePrincipalId -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue $newResourceScopeValue
    switch ($grantResult.Action) {
        'Created' {
            Write-LogSuccess ("Created customer Microsoft Azure CLI delegated new resource (bd0c) grant with scope '{0}'" -f $grantResult.Scope)
        }
        'Updated' {
            Write-LogSuccess ("Updated customer Microsoft Azure CLI delegated new resource (bd0c) grant to scope '{0}'" -f $grantResult.Scope)
        }
        'Unchanged' {
            Write-Log -Level INFO -Message ("customer Microsoft Azure CLI delegated new resource (bd0c) grant already exists with scope '{0}'" -f $grantResult.Scope)
        }
        'AlreadyExists' {
            Write-Log -Level INFO -Message 'customer Microsoft Azure CLI delegated new resource (bd0c) grant is already satisfied by an existing permission entry or the resource application''s pre-authorized-client consent model'
        }
        default {
            throw ("Unsupported delegated-grant result action: {0}" -f $grantResult.Action)
        }
    }

    $grantCount = Get-OAuth2PermissionGrantCount -ConfigDir $customerConfigDir -ClientServicePrincipalId $azureCliCustomerServicePrincipalId -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue $newResourceScopeValue
    Write-Log -Level INFO -Message ("Azure CLI delegated grant rows matching scope '{0}': {1}" -f $newResourceScopeValue, $grantCount)

    Write-Log -Level INFO -Message 'SUMMARY: migrate adme-audience complete'
    Write-Log -Level INFO -Message ("  old resource (dffa) customer servicePrincipalId={0} now advertises {1}" -f $oldResourceServicePrincipalId, $oldResourceIdentifierUri)
    Write-Log -Level INFO -Message ("  new resource (bd0c) customer servicePrincipalId={0} now advertises {1}" -f $bd0cCustomerServicePrincipalId, $newResourceIdentifierUri)
}

function Invoke-MigrateApiPermissions {
    [CmdletBinding()]
    param()

    Write-LogStep 'Loading runtime state and validating api-permissions prerequisites'
    Load-RuntimeState
    Write-ConfigSummary
    Assert-CustomerTenantContext
    Assert-TenantAdminRole
    Resolve-SelectedClient -Purpose 'migrate api-permissions'

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $bd0cCustomerServicePrincipalId = Get-ServicePrincipalIdByAppId -ConfigDir $customerConfigDir -AppId (Get-ConfigValue -Name 'NewResourceAppId')
    if ([string]::IsNullOrWhiteSpace($bd0cCustomerServicePrincipalId)) {
        throw "Customer new resource (bd0c) service principal not found. Run 'migrate adme-audience' first."
    }

    $targetPermissionContract = Resolve-TargetResourcePermissionContract -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId

    Write-Log -Level INFO -Message 'Preflight:'
    Write-Log -Level INFO -Message ("  customer tenant: {0}" -f (Get-ConfigValue -Name 'CustomerTenantId'))
    Write-Log -Level INFO -Message ("  client app appId: {0}" -f (Get-ConfigValue -Name 'ClientAppId'))
    Write-Log -Level INFO -Message ("  new resource (bd0c) appId: {0}" -f (Get-ConfigValue -Name 'NewResourceAppId'))
    Write-Log -Level INFO -Message ("  new resource (bd0c) servicePrincipalId: {0}" -f $bd0cCustomerServicePrincipalId)
    if ($targetPermissionContract.RequiresAppRole) {
        Write-Log -Level INFO -Message ("  app role to grant: {0} ({1})" -f (Get-ConfigValue -Name 'NewResourceAppRoleValue'), (Get-ConfigValue -Name 'NewResourceAppRoleId'))
    }
    else {
        Write-Log -Level INFO -Message '  app role to grant: not applicable (target resource exposes no enabled app roles)'
    }

    Write-Log -Level INFO -Message ("  delegated scope to preserve in requiredResourceAccess: {0} ({1})" -f (Get-ConfigValue -Name 'NewResourceScopeValue'), (Get-ConfigValue -Name 'NewResourceScopeId'))
    Write-Log -Level INFO -Message ("  requiredResourceAccess target shape: {0}" -f $targetPermissionContract.PermissionShape)
    if ($script:Options.AutoGrant) {
        Write-Log -Level INFO -Message '  customer-app consent mode: --auto-grant'
    }
    else {
        Write-Log -Level INFO -Message '  customer-app consent mode: default manual admin-consent action'
        Write-CustomerAppAdminConsentGuidance -RequiresAppRole ([bool]$targetPermissionContract.RequiresAppRole)
    }

    Confirm-IfNeeded -ActionLabel 'api-permissions migration'

    Write-LogStep 'Validating the requiredResourceAccess PATCH contract against client app'
    Update-ClientApplicationRequiredResourceAccess -RequiresAppRole ([bool]$targetPermissionContract.RequiresAppRole)

    Write-Log -Level INFO -Message 'Old resource (dffa) grants are left in place intentionally if they exist; they are now stale informational artifacts.'
    Write-Log -Level INFO -Message 'SUMMARY: migrate api-permissions complete'
    Write-Log -Level INFO -Message '  client app requiredResourceAccess now references new resource (bd0c)'

    if ($script:Options.AutoGrant) {
        $matchingAssignmentId = ''
        $assignmentCount = 0
        if ($targetPermissionContract.RequiresAppRole) {
            Write-LogStep 'Ensuring the new resource (bd0c) app role assignment exists for client app'
            $assignmentResult = Ensure-AppRoleAssignment -ConfigDir $customerConfigDir -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -AppRoleId (Get-ConfigValue -Name 'NewResourceAppRoleId')
            switch ($assignmentResult.Action) {
                'Created' { Write-LogSuccess 'Created client app -> new resource (bd0c) app role assignment' }
                'Unchanged' { Write-Log -Level INFO -Message ("client app already has app role assignment {0} on new resource (bd0c)" -f $assignmentResult.AssignmentId) }
                'AlreadyExists' { Write-Log -Level INFO -Message 'client app app role assignment already exists on new resource (bd0c)' }
                default { throw ("Unsupported app-role-assignment result action: {0}" -f $assignmentResult.Action) }
            }

            $matchingAssignment = Wait-AppRoleAssignment -ConfigDir $customerConfigDir -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -AppRoleId (Get-ConfigValue -Name 'NewResourceAppRoleId')
            $matchingAssignmentId = [string](Get-OptionalPropertyValue -InputObject $matchingAssignment -Name 'id')
            Write-LogSuccess ("Verified client app app role assignment: {0}" -f $matchingAssignmentId)
            $assignmentCount = Get-AppRoleAssignmentCount -ConfigDir $customerConfigDir -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -AppRoleId (Get-ConfigValue -Name 'NewResourceAppRoleId')
            if ($assignmentCount -ne 1) {
                throw ("Expected exactly one matching new resource (bd0c) app role assignment for client app, found {0}" -f $assignmentCount)
            }
        }
        else {
            Write-Log -Level INFO -Message 'Skipping app-role grant creation because the target resource exposes no enabled app roles'
        }

        Write-LogStep 'Ensuring the new resource (bd0c) delegated grant exists for client app'
        $grantResult = Ensure-OAuth2PermissionGrant -ConfigDir $customerConfigDir -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue (Get-ConfigValue -Name 'NewResourceScopeValue')
        switch ($grantResult.Action) {
            'Created' { Write-LogSuccess ("Created client app delegated new resource (bd0c) grant with scope '{0}'" -f $grantResult.Scope) }
            'Updated' { Write-LogSuccess ("Updated client app delegated new resource (bd0c) grant to scope '{0}'" -f $grantResult.Scope) }
            'Unchanged' { Write-Log -Level INFO -Message ("client app delegated new resource (bd0c) grant already exists with scope '{0}'" -f $grantResult.Scope) }
            'AlreadyExists' { Write-Log -Level INFO -Message 'client app delegated new resource (bd0c) grant is already satisfied by an existing permission entry' }
            default { throw ("Unsupported delegated-grant result action: {0}" -f $grantResult.Action) }
        }

        $clientDelegatedGrantCount = Get-OAuth2PermissionGrantCount -ConfigDir $customerConfigDir -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue (Get-ConfigValue -Name 'NewResourceScopeValue')
        if ($clientDelegatedGrantCount -lt 1) {
            throw ("Expected the client app delegated grant for new resource (bd0c) scope '{0}' to exist after --auto-grant" -f (Get-ConfigValue -Name 'NewResourceScopeValue'))
        }

        Write-LogSuccess ("Verified client app delegated grant wiring for new resource (bd0c) scope '{0}'" -f (Get-ConfigValue -Name 'NewResourceScopeValue'))
        Write-Log -Level INFO -Message '  customer app grants were created programmatically (--auto-grant)'
        if ($targetPermissionContract.RequiresAppRole) {
            Write-Log -Level INFO -Message ("  new resource (bd0c) app role assignment id={0}" -f $matchingAssignmentId)
        }
        else {
            Write-Log -Level INFO -Message '  new resource (bd0c) app role assignment: not applicable'
        }
    }
    else {
        $matchingAssignmentId = ''
        if ($targetPermissionContract.RequiresAppRole) {
            $matchingAssignment = Find-AppRoleAssignment -ConfigDir $customerConfigDir -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -AppRoleId (Get-ConfigValue -Name 'NewResourceAppRoleId')
            if ($null -ne $matchingAssignment) {
                $matchingAssignmentId = [string](Get-OptionalPropertyValue -InputObject $matchingAssignment -Name 'id')
            }

            $assignmentCount = Get-AppRoleAssignmentCount -ConfigDir $customerConfigDir -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -AppRoleId (Get-ConfigValue -Name 'NewResourceAppRoleId')
        }
        else {
            $assignmentCount = 0
        }

        $clientDelegatedGrantCount = Get-OAuth2PermissionGrantCount -ConfigDir $customerConfigDir -ClientServicePrincipalId (Get-ConfigValue -Name 'ClientServicePrincipalId') -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue (Get-ConfigValue -Name 'NewResourceScopeValue')

        Write-Log -Level INFO -Message '  customer app grants were not modified on the default path'
        if ($targetPermissionContract.RequiresAppRole) {
            Write-Log -Level INFO -Message ("  existing customer-app grant state (informational): appRoleAssignments={0} delegatedGrants={1}" -f $assignmentCount, $clientDelegatedGrantCount)
        }
        else {
            Write-Log -Level INFO -Message ("  existing customer-app grant state (informational): appRoleAssignments=not-applicable delegatedGrants={0}" -f $clientDelegatedGrantCount)
        }

        if (-not [string]::IsNullOrWhiteSpace($matchingAssignmentId)) {
            Write-Log -Level INFO -Message ("  existing new resource (bd0c) app role assignment id={0}" -f $matchingAssignmentId)
        }

        Write-CustomerAppAdminConsentGuidance -RequiresAppRole ([bool]$targetPermissionContract.RequiresAppRole)
    }
}

function ConvertTo-TextBlock {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Output
    )

    if ($null -eq $Output) {
        return ''
    }

    $lines = New-Object System.Collections.ArrayList
    foreach ($item in @($Output)) {
        if ($null -eq $item) {
            continue
        }

        [void]$lines.Add([string]$item)
    }

    return [string]::Join([Environment]::NewLine, [string[]]$lines.ToArray([string]))
}

function Invoke-NativeTextCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @()
    )

    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        try {
            $output = & $Command @Arguments 2> $stderrPath
            $exitCode = $LASTEXITCODE
            $stderr = ''
            if (Test-Path -LiteralPath $stderrPath) {
                $stderr = [IO.File]::ReadAllText($stderrPath)
            }

            return [pscustomobject]@{
                Success = ($exitCode -eq 0)
                ExitCode = $exitCode
                Stdout = (ConvertTo-TextBlock -Output $output)
                Stderr = $stderr
            }
        }
        catch {
            return [pscustomobject]@{
                Success = $false
                ExitCode = -1
                Stdout = ''
                Stderr = $_.Exception.Message
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
    }
}

function Invoke-WithTemporaryEnvironmentValues {
    [CmdletBinding()]
    param(
        [hashtable]$Values,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $originalValues = @{}
    foreach ($entry in $Values.GetEnumerator()) {
        $originalValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }

    try {
        return & $ScriptBlock
    }
    finally {
        foreach ($entry in $originalValues.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

function Get-PythonMsalLauncher {
    [CmdletBinding()]
    param()

    $candidates = @(
        [pscustomobject]@{ Command = 'py'; Arguments = @('-3') },
        [pscustomobject]@{ Command = 'python3'; Arguments = @() },
        [pscustomobject]@{ Command = 'python'; Arguments = @() }
    )

    foreach ($candidate in $candidates) {
        $probeArguments = @($candidate.Arguments) + @('-c', 'import json, msal; print(json.dumps({"ok": True}))')
        $probe = Invoke-NativeTextCommand -Command $candidate.Command -Arguments $probeArguments
        if (-not $probe.Success) {
            continue
        }

        try {
            $probeResult = $probe.Stdout.Trim() | ConvertFrom-Json
            if ($null -ne $probeResult -and [bool](Get-OptionalPropertyValue -InputObject $probeResult -Name 'ok')) {
                return [pscustomobject]@{
                    Command = $candidate.Command
                    Arguments = @($candidate.Arguments)
                }
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function New-TemporaryDirectory {
    [CmdletBinding()]
    param(
        [string]$Prefix = 'adme-verify'
    )

    $path = Join-Path ([IO.Path]::GetTempPath()) ('{0}-{1}' -f $Prefix, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-DelegatedTokenForceRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$AzureCliAppId,

        [Parameter(Mandatory = $true)]
        [string]$Scope
    )

    $launcher = Get-PythonMsalLauncher
    if ($null -eq $launcher) {
        return [pscustomobject]@{
            skipped = $true
            reason = 'python_msal_unavailable'
            warning = ("Skipping delegated forced-refresh proof for scope {0} because Python with the msal package is unavailable. The Graph delegated-grant wiring check still ran." -f $Scope)
        }
    }

    $tempDir = New-TemporaryDirectory -Prefix 'adme-verify-msal'
    $scriptPath = Join-Path $tempDir 'force-refresh.py'
    $pythonSource = @'
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
        "skipped": True,
        "reason": "missing_plaintext_token_cache",
        "warning": "Skipping delegated forced-refresh proof because the Azure CLI plaintext MSAL token cache was not found. Falling back to az account get-access-token with claim validation.",
    }))
    raise SystemExit(0)

cache = msal.SerializableTokenCache()
try:
    cache.deserialize(cache_path.read_text() or "{}")
except Exception as exc:
    print(json.dumps({
        "skipped": True,
        "reason": "unreadable_plaintext_token_cache",
        "warning": f"Skipping delegated forced-refresh proof because the Azure CLI token cache could not be read by msal: {exc}. Falling back to az account get-access-token with claim validation.",
    }))
    raise SystemExit(0)

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
'@

    try {
        [IO.File]::WriteAllText($scriptPath, $pythonSource)
        $environmentValues = @{
            AZURE_CONFIG_DIR = $ConfigDir
            AAD_TENANT_ID = $TenantId
            AZURE_CLI_CLIENT_ID = $AzureCliAppId
            REQUESTED_SCOPE = $Scope
        }

        $pythonResult = Invoke-WithTemporaryEnvironmentValues -Values $environmentValues -ScriptBlock {
            $pythonArguments = @($launcher.Arguments) + @($scriptPath)
            Invoke-NativeTextCommand -Command $launcher.Command -Arguments $pythonArguments
        }

        if (-not $pythonResult.Success) {
            $description = (($pythonResult.Stderr + [Environment]::NewLine + $pythonResult.Stdout).Trim())
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = 'Python MSAL forced-refresh helper failed without output.'
            }

            return [pscustomobject]@{
                error = 'python_msal_force_refresh_failed'
                error_description = $description
            }
        }

        $jsonText = $pythonResult.Stdout.Trim()
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            return [pscustomobject]@{
                error = 'python_msal_empty_output'
                error_description = 'Python MSAL forced-refresh helper returned no JSON output.'
            }
        }

        return ($jsonText | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DelegatedTokenFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$Scope
    )

    try {
        $tokenResponse = Invoke-AzCliCommand -ConfigDir $ConfigDir -Arguments @('account', 'get-access-token', '--tenant', $TenantId, '--scope', $Scope, '-o', 'json')
        $accessToken = [string](Get-OptionalPropertyValue -InputObject $tokenResponse -Name 'accessToken')
        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            return [pscustomobject]@{
                error = 'az_account_get_access_token_empty'
                error_description = 'Azure CLI did not return a delegated access token.'
            }
        }

        return [pscustomobject]@{
            access_token = $accessToken
            source = 'az_account_get_access_token'
        }
    }
    catch {
        return [pscustomobject]@{
            error = 'az_account_get_access_token_failed'
            error_description = $_.Exception.Message
        }
    }
}

function Invoke-AppOnlyTokenProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter(Mandatory = $true)]
        [string]$ResourceUri
    )

    $launcher = Get-PythonMsalLauncher
    if ($null -eq $launcher) {
        return [pscustomobject]@{
            error = 'python_msal_unavailable'
            error_description = 'Python with the msal package is required for the selected-client app-only proof.'
        }
    }

    $getTokenPath = Join-Path $PSScriptRoot 'get-token.py'
    if (-not (Test-Path -LiteralPath $getTokenPath -PathType Leaf)) {
        return [pscustomobject]@{
            error = 'get_token_py_not_found'
            error_description = ("get-token.py was not found at {0}" -f $getTokenPath)
        }
    }

    try {
        $environmentValues = @{
            APP_TENANT_ID = $TenantId
            API_APP_ID = [string](Get-ConfigValue -Name 'NewResourceAppId')
            RESOURCE_APP_ID_URI = $ResourceUri
            APP_CLIENT_ID = $ClientId
            APP_CLIENT_SECRET = $ClientSecret
            AUTH_FLOW = 'client_credentials'
        }

        $tokenResult = Invoke-WithTemporaryEnvironmentValues -Values $environmentValues -ScriptBlock {
            $pythonArguments = @($launcher.Arguments) + @($getTokenPath)
            Invoke-NativeTextCommand -Command $launcher.Command -Arguments $pythonArguments
        }

        if (-not $tokenResult.Success) {
            $description = (($tokenResult.Stderr + [Environment]::NewLine + $tokenResult.Stdout).Trim())
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = 'get-token.py failed without output.'
            }

            return [pscustomobject]@{
                error = 'get_token_py_app_only_failed'
                error_description = (Protect-LogMessage -Message $description)
            }
        }

        $accessTokenMatch = [regex]::Match($tokenResult.Stdout, 'Access Token:\s+(?<token>eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)')
        $accessToken = ''
        if ($accessTokenMatch.Success) {
            $accessToken = $accessTokenMatch.Groups['token'].Value
        }

        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            return [pscustomobject]@{
                error = 'get_token_py_app_only_token_empty'
                error_description = 'get-token.py did not emit an app-only access token.'
            }
        }

        return [pscustomobject]@{
            access_token = $accessToken
            source = 'get_token_py_client_credentials'
        }
    }
    catch {
        return [pscustomobject]@{
            error = 'get_token_py_app_only_failed'
            error_description = $_.Exception.Message
        }
    }
}

function Test-ErrorCodesContains {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    foreach ($errorCode in @((Get-OptionalPropertyValue -InputObject $InputObject -Name 'error_codes'))) {
        if ([string]$errorCode -eq [string]$Code) {
            return $true
        }
    }

    return $false
}

function Add-VerifyFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:VerifyFailures++
    Write-Log -Level ERROR -Message ("FAIL: {0}" -f $Message)
}

function Test-DelegatedTokenClaims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    try {
        $claims = ConvertFrom-JwtPayload -Token $AccessToken
    }
    catch {
        Add-VerifyFailure -Message ("Delegated token could not be decoded: {0}" -f $_.Exception.Message)
        return $false
    }

    $delegatedAudience = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'aud')
    $delegatedScope = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'scp')
    $delegatedAuthorizedParty = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'azp')
    $expectedAudience = [string](Get-ConfigValue -Name 'NewResourceAppId')
    $expectedScope = [string](Get-ConfigValue -Name 'NewResourceScopeValue')
    $expectedAuthorizedParty = [string](Get-ConfigValue -Name 'AzureCliAppId')

    if ($delegatedAudience -ne $expectedAudience) {
        Add-VerifyFailure -Message ("Delegated token aud '{0}' did not match new resource (bd0c) appId '{1}'" -f $delegatedAudience, $expectedAudience)
        return $false
    }

    if ($delegatedScope -ne $expectedScope) {
        Add-VerifyFailure -Message ("Delegated token scp '{0}' did not match '{1}'" -f $delegatedScope, $expectedScope)
        return $false
    }

    if ($delegatedAuthorizedParty -ne $expectedAuthorizedParty) {
        Add-VerifyFailure -Message ("Delegated token azp '{0}' did not match Microsoft Azure CLI appId '{1}'" -f $delegatedAuthorizedParty, $expectedAuthorizedParty)
        return $false
    }

    Write-LogSuccess ("Verified Azure CLI delegated token aud={0} azp={1} scp={2}" -f $delegatedAudience, $delegatedAuthorizedParty, $delegatedScope)
    return $true
}

function Test-AppOnlyTokenClaims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    try {
        $claims = ConvertFrom-JwtPayload -Token $AccessToken
    }
    catch {
        Add-VerifyFailure -Message ("App-only token could not be decoded: {0}" -f $_.Exception.Message)
        return $false
    }

    $appOnlyAudience = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'aud')
    $appOnlyAuthorizedParty = [string](Get-OptionalPropertyValue -InputObject $claims -Name 'azp')
    $expectedAudience = [string](Get-ConfigValue -Name 'NewResourceAppId')
    $expectedAuthorizedParty = [string](Get-ConfigValue -Name 'ClientAppId')

    if ($appOnlyAudience -ne $expectedAudience) {
        Add-VerifyFailure -Message ("App-only token aud '{0}' did not match new resource (bd0c) appId '{1}'" -f $appOnlyAudience, $expectedAudience)
        return $false
    }

    if ($appOnlyAuthorizedParty -ne $expectedAuthorizedParty) {
        Add-VerifyFailure -Message ("App-only token azp '{0}' did not match client app appId '{1}'" -f $appOnlyAuthorizedParty, $expectedAuthorizedParty)
        return $false
    }

    Write-LogSuccess ("Verified app-only token aud={0} azp={1}" -f $appOnlyAudience, $appOnlyAuthorizedParty)
    return $true
}

function Select-MatchingClientSecretForVerify {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateClientAppId
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientSecret)) {
        Set-ConfigValue -Name 'ClientSecret' -Value ([string]$script:Options.SelectedClientSecret) -Source '--client-secret'
        return
    }

    if ((Get-ConfigSource -Name 'ClientSecret') -eq 'environment') {
        return
    }

    $clientAppId = [string](Get-ConfigValue -Name 'ClientAppId')
    $matchedSecret = ''
    if ($clientAppId -eq [string](Get-ConfigValue -Name 'Sim3PClientAppId')) {
        $matchedSecret = [string](Get-ConfigValue -Name 'Sim3PClientSecret')
    }
    elseif ($clientAppId -eq [string](Get-ConfigValue -Name 'Sim3PClient2AppId')) {
        $matchedSecret = [string](Get-ConfigValue -Name 'Sim3PClient2Secret')
    }
    elseif ($clientAppId -eq [string](Get-ConfigValue -Name 'Sim3PClient3AppId')) {
        $matchedSecret = [string](Get-ConfigValue -Name 'Sim3PClient3Secret')
    }

    if (-not [string]::IsNullOrWhiteSpace($matchedSecret)) {
        Set-ConfigValue -Name 'ClientSecret' -Value $matchedSecret -Source 'matched simulator client secret from runtime state'
        Write-Log -Level INFO -Message ("Using matching simulator client secret from runtime state for selected client appId {0}" -f $clientAppId)
        return
    }

    $currentSecret = [string](Get-ConfigValue -Name 'ClientSecret')
    if (-not [string]::IsNullOrWhiteSpace($currentSecret) -and $StateClientAppId -ne $clientAppId) {
        Write-LogWarn ("Ignoring CLIENT_SECRET from runtime state because it belongs to client appId {0}, but verify selected client appId {1}" -f $StateClientAppId, $clientAppId)
        Set-ConfigValue -Name 'ClientSecret' -Value $null -Source 'ignored runtime-state client secret'
    }
}

function Write-VerifyResourceOverrideWarning {
    [CmdletBinding()]
    param()

    if ($script:StateDirExplicit) {
        return
    }

    $overriddenNames = New-Object System.Collections.ArrayList
    foreach ($name in @('OldResourceAppId', 'NewResourceAppId', 'OldResourceIdentifierUri', 'NewResourceIdentifierUri', 'NewResourceScopeId', 'NewResourceScopeValue', 'NewResourceAppRoleId', 'NewResourceAppRoleValue')) {
        $source = [string](Get-ConfigSource -Name $name)
        if ($source -ne 'default' -and -not [string]::IsNullOrWhiteSpace($source)) {
            [void]$overriddenNames.Add($name)
        }
    }

    if ($overriddenNames.Count -gt 0) {
        Write-LogWarn ("verify is using resource overrides without an explicit --state-dir/-StateDir ({0}). If this is simulator validation, pass -StateDir to make the runtime state source explicit." -f ([string]::Join(', ', [string[]]$overriddenNames.ToArray([string]))))
    }
}

function Invoke-Verify {
    [CmdletBinding()]
    param()

    Write-LogStep 'Loading runtime state and validating verify prerequisites'
    Load-RuntimeState
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientSecret)) {
        Set-ConfigValue -Name 'ClientSecret' -Value ([string]$script:Options.SelectedClientSecret) -Source '--client-secret'
    }

    Write-ConfigSummary
    Write-VerifyResourceOverrideWarning
    Assert-CustomerTenantContext

    $script:VerifyFailures = 0
    $selectedClientVerify = -not [string]::IsNullOrWhiteSpace([string]$script:Options.SelectedClientId)
    $stateClientAppId = [string](Get-ConfigValue -Name 'ClientAppId')
    if ($selectedClientVerify) {
        Resolve-SelectedClient -Purpose 'verify'
        Select-MatchingClientSecretForVerify -StateClientAppId $stateClientAppId
    }
    else {
        Write-Log -Level INFO -Message 'Running tenant/audience verification because --client-id was not provided; selected-client app-only proof is skipped.'
        $clientSecretSource = [string](Get-ConfigSource -Name 'ClientSecret')
        if (($clientSecretSource -eq 'environment' -or $clientSecretSource -eq '--client-secret') -and -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'ClientSecret'))) {
            Write-LogWarn 'Ignoring CLIENT_SECRET because verify without --client-id does not run the selected-client app-only proof. Use verify --client-id <client-app-id> to test app-only.'
        }
    }

    $customerConfigDir = [string](Get-ConfigValue -Name 'CustomerConfigDir')
    $customerTenantId = [string](Get-ConfigValue -Name 'CustomerTenantId')
    $newResourceAppId = [string](Get-ConfigValue -Name 'NewResourceAppId')
    $newResourceIdentifierUri = [string](Get-ConfigValue -Name 'NewResourceIdentifierUri')
    $newResourceScopeValue = [string](Get-ConfigValue -Name 'NewResourceScopeValue')

    Write-LogStep 'Checking customer-tenant service principal state'
    $dffaCustomerServicePrincipal = $null
    try {
        $dffaCustomerServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId (Get-ConfigValue -Name 'OldResourceServicePrincipalId')
        $dffaCustomerServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $dffaCustomerServicePrincipal
        if (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $dffaCustomerServicePrincipal) {
            Write-LogSuccess ("Verified customer old resource (dffa) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $dffaCustomerServicePrincipalNames))
            Write-LogSuccess ("Verified customer old resource (dffa) no longer owns shared audience {0}" -f $newResourceIdentifierUri)
        }
        else {
            Add-VerifyFailure -Message ("customer old resource (dffa) servicePrincipalNames are not refreshed to the old identifierUri: {0}" -f (ConvertTo-CompactJson -Value $dffaCustomerServicePrincipalNames))
        }
    }
    catch {
        Add-VerifyFailure -Message ("customer old resource (dffa) service principal could not be read: {0}" -f $_.Exception.Message)
    }

    $bd0cCustomerServicePrincipalId = Get-ServicePrincipalIdByAppId -ConfigDir $customerConfigDir -AppId $newResourceAppId
    $bd0cCustomerServicePrincipal = $null
    $targetPermissionContract = $null
    if ([string]::IsNullOrWhiteSpace($bd0cCustomerServicePrincipalId)) {
        Add-VerifyFailure -Message 'Customer new resource (bd0c) service principal not found'
    }
    else {
        try {
            $bd0cCustomerServicePrincipal = Get-ServicePrincipalById -ConfigDir $customerConfigDir -ServicePrincipalId $bd0cCustomerServicePrincipalId
            $bd0cCustomerServicePrincipalNames = Get-ServicePrincipalNames -ServicePrincipal $bd0cCustomerServicePrincipal
            if (Test-NewResourceServicePrincipalOwnsSharedAudience -ServicePrincipal $bd0cCustomerServicePrincipal) {
                Write-LogSuccess ("Verified customer new resource (bd0c) servicePrincipalNames: {0}" -f (ConvertTo-CompactJson -Value $bd0cCustomerServicePrincipalNames))
                Write-LogSuccess ("Verified customer new resource (bd0c) owns shared audience {0}" -f $newResourceIdentifierUri)
            }
            else {
                Add-VerifyFailure -Message ("customer new resource (bd0c) servicePrincipalNames do not include {0}: {1}" -f $newResourceIdentifierUri, (ConvertTo-CompactJson -Value $bd0cCustomerServicePrincipalNames))
            }

            try {
                $targetPermissionContract = Resolve-TargetResourcePermissionContract -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId
            }
            catch {
                Add-VerifyFailure -Message $_.Exception.Message
            }
        }
        catch {
            Add-VerifyFailure -Message ("customer new resource (bd0c) service principal could not be read: {0}" -f $_.Exception.Message)
        }
    }

    $appOnlyProofAttempted = $false
    $appOnlyProofRan = $false
    $delegatedProofRan = $false

    if ($selectedClientVerify) {
        Write-LogStep 'Validating selected-client runtime token proof'
        Write-Log -Level INFO -Message 'Selected-client verify is token-focused; run adme-entra-inventory.sh for API-permission and admin-consent status.'
        if ($null -eq $targetPermissionContract) {
            Write-LogWarn 'Skipping the selected-client app-only token proof because target resource permissions contract validation did not complete.'
        }
        elseif (-not [bool]$targetPermissionContract.RequiresAppRole) {
            Write-Log -Level INFO -Message 'Skipping the selected-client app-only token proof because the target resource exposes no enabled app roles.'
            Write-Log -Level INFO -Message 'Use verify without --client-id for the Azure CLI delegated token proof, and use test.sh to call the ADME endpoint.'
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Name 'ClientSecret'))) {
            Write-LogStep 'Validating the post-migration app-only token'
            $appOnlyProofAttempted = $true
            $appOnlyResult = Invoke-AppOnlyTokenProof -TenantId $customerTenantId -ClientId ([string](Get-ConfigValue -Name 'ClientAppId')) -ClientSecret ([string](Get-ConfigValue -Name 'ClientSecret')) -ResourceUri $newResourceIdentifierUri
            $appOnlyError = [string](Get-OptionalPropertyValue -InputObject $appOnlyResult -Name 'error')
            if (-not [string]::IsNullOrWhiteSpace($appOnlyError)) {
                $appOnlyDescription = [string](Get-OptionalPropertyValue -InputObject $appOnlyResult -Name 'error_description')
                if ([string]::IsNullOrWhiteSpace($appOnlyDescription)) {
                    $appOnlyDescription = '<no description>'
                }

                Add-VerifyFailure -Message ("Post-migration app-only token acquisition failed: {0} ({1})" -f $appOnlyError, $appOnlyDescription)
                Write-LogWarn ("App-only proof uses the selected client app secret value for appId {0}." -f (Get-ConfigValue -Name 'ClientAppId'))
                Write-LogWarn ("Remedy: export CLIENT_SECRET=<CLIENT_SECRET> with the secret value (not the secret ID), then rerun verify --client-id {0}." -f (Get-ConfigValue -Name 'ClientAppId'))
                Write-LogWarn 'If you do not have the secret value, create a new client secret for this app registration; Entra cannot reveal existing secret values.'
            }
            else {
                $appOnlyAccessToken = [string](Get-OptionalPropertyValue -InputObject $appOnlyResult -Name 'access_token')
                if (Test-AppOnlyTokenClaims -AccessToken $appOnlyAccessToken) {
                    $appOnlyProofRan = $true
                }
            }
        }
        else {
            Write-LogWarn 'Skipping the selected-client app-only token proof because no matching selected-client secret was available from state, CLIENT_SECRET, or --client-secret.'
            Write-LogWarn ("To run the app-only proof, export CLIENT_SECRET=<CLIENT_SECRET> with the selected client app secret value, then rerun verify --client-id {0}." -f (Get-ConfigValue -Name 'ClientAppId'))
        }
    }
    else {
        Write-Log -Level INFO -Message 'Skipping selected-client app-only proof because --client-id was not provided.'
        if (-not [string]::IsNullOrWhiteSpace($bd0cCustomerServicePrincipalId)) {
            Write-LogStep 'Checking the Azure CLI delegated grant wiring for new resource (bd0c)'
            $azureCliCustomerServicePrincipalId = Get-ServicePrincipalIdByAppId -ConfigDir $customerConfigDir -AppId (Get-ConfigValue -Name 'AzureCliAppId')
            if ([string]::IsNullOrWhiteSpace($azureCliCustomerServicePrincipalId)) {
                Add-VerifyFailure -Message 'Customer Microsoft Azure CLI service principal not found'
            }
            else {
                $azureCliDelegatedGrantCount = Get-OAuth2PermissionGrantCount -ConfigDir $customerConfigDir -ClientServicePrincipalId $azureCliCustomerServicePrincipalId -ResourceServicePrincipalId $bd0cCustomerServicePrincipalId -ScopeValue $newResourceScopeValue
                if ($azureCliDelegatedGrantCount -ge 1) {
                    Write-LogSuccess ("Verified Azure CLI delegated grant wiring for new resource (bd0c) scope '{0}'" -f $newResourceScopeValue)
                }
                else {
                    Write-LogWarn ("Azure CLI oauth2PermissionGrant row for new resource (bd0c) scope '{0}' was not found; attempting delegated token proof in case the resource uses pre-authorized-client consent" -f $newResourceScopeValue)
                }

                Write-LogStep 'Validating the Azure CLI delegated token diagnostic with a forced refresh to avoid stale Azure CLI cache hits'
                $delegatedScope = '{0}/{1}' -f $newResourceIdentifierUri.TrimEnd('/'), $newResourceScopeValue
                $delegatedResult = Invoke-DelegatedTokenForceRefresh -ConfigDir $customerConfigDir -TenantId $customerTenantId -AzureCliAppId ([string](Get-ConfigValue -Name 'AzureCliAppId')) -Scope $delegatedScope
                $delegatedSkipped = [bool](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'skipped')
                $delegatedError = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error')
                if ($delegatedSkipped) {
                    $delegatedWarning = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'warning')
                    if ([string]::IsNullOrWhiteSpace($delegatedWarning)) {
                        $delegatedWarning = 'Skipping delegated forced-refresh proof; using Azure CLI fallback with claim validation.'
                    }

                    Write-LogWarn $delegatedWarning
                    $delegatedResult = Invoke-DelegatedTokenFallback -ConfigDir $customerConfigDir -TenantId $customerTenantId -Scope $delegatedScope
                    $delegatedError = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error')
                    if (-not [string]::IsNullOrWhiteSpace($delegatedError)) {
                        $delegatedDescription = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error_description')
                        if ([string]::IsNullOrWhiteSpace($delegatedDescription)) {
                            $delegatedDescription = '<no description>'
                        }

                        if ($azureCliDelegatedGrantCount -eq 0) {
                            Add-VerifyFailure -Message ("Azure CLI oauth2PermissionGrant row is missing and delegated token fallback failed: {0} ({1})" -f $delegatedError, $delegatedDescription)
                        }
                        else {
                            Add-VerifyFailure -Message ("Azure CLI delegated token fallback failed: {0} ({1})" -f $delegatedError, $delegatedDescription)
                        }

                        if ($delegatedDescription -like '*AADSTS65001*') {
                            Write-LogWarn ("Run once: AZURE_CONFIG_DIR=`"{0}`" az login --tenant `"{1}`" --scope `"{2}`" --allow-no-subscriptions" -f $customerConfigDir, $customerTenantId, $delegatedScope)
                        }
                    }
                    else {
                        Write-LogWarn 'Using az account get-access-token fallback and validating token claims because forced refresh is unavailable'
                        if (Test-DelegatedTokenClaims -AccessToken ([string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'access_token'))) {
                            $delegatedProofRan = $true
                            if ($azureCliDelegatedGrantCount -eq 0) {
                                Write-LogSuccess 'Verified Azure CLI delegated access by token proof without an oauth2PermissionGrant row; target resource likely uses pre-authorized-client consent'
                            }
                        }
                    }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($delegatedError)) {
                    if (Test-ErrorCodesContains -InputObject $delegatedResult -Code 65001) {
                        $delegatedResult = Invoke-DelegatedTokenFallback -ConfigDir $customerConfigDir -TenantId $customerTenantId -Scope $delegatedScope
                        $delegatedError = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error')
                        if ([string]::IsNullOrWhiteSpace($delegatedError)) {
                            Write-LogWarn ("Azure CLI MSAL force-refresh returned consent_required for scope {0}; using az account get-access-token fallback and validating token claims to reject stale cache hits" -f $delegatedScope)
                            if (Test-DelegatedTokenClaims -AccessToken ([string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'access_token'))) {
                                $delegatedProofRan = $true
                                if ($azureCliDelegatedGrantCount -eq 0) {
                                    Write-LogSuccess 'Verified Azure CLI delegated access by token proof without an oauth2PermissionGrant row; target resource likely uses pre-authorized-client consent'
                                }
                            }
                        }
                        else {
                            $delegatedDescription = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error_description')
                            if ([string]::IsNullOrWhiteSpace($delegatedDescription)) {
                                $delegatedDescription = '<no description>'
                            }

                            Write-LogWarn ("Azure CLI forced-refresh delegated token request still requires one-time interactive consent for scope {0}" -f $delegatedScope)
                            Write-LogWarn ("Run once: AZURE_CONFIG_DIR=`"{0}`" az login --tenant `"{1}`" --scope `"{2}`" --allow-no-subscriptions" -f $customerConfigDir, $customerTenantId, $delegatedScope)
                            Add-VerifyFailure -Message ("Azure CLI delegated diagnostic is blocked until the operator completes the one-time Azure CLI consent for {0}: {1} ({2})" -f $delegatedScope, $delegatedError, $delegatedDescription)
                        }
                    }
                    else {
                        $delegatedDescription = [string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'error_description')
                        if ([string]::IsNullOrWhiteSpace($delegatedDescription)) {
                            $delegatedDescription = '<no description>'
                        }

                        Add-VerifyFailure -Message ("Azure CLI delegated token diagnostic failed: {0} ({1})" -f $delegatedError, $delegatedDescription)
                    }
                }
                else {
                    if (Test-DelegatedTokenClaims -AccessToken ([string](Get-OptionalPropertyValue -InputObject $delegatedResult -Name 'access_token'))) {
                        $delegatedProofRan = $true
                        if ($azureCliDelegatedGrantCount -eq 0) {
                            Write-LogSuccess 'Verified Azure CLI delegated access by token proof without an oauth2PermissionGrant row; target resource likely uses pre-authorized-client consent'
                        }
                    }
                }
            }
        }
    }

    Write-Log -Level INFO -Message 'Verify status'
    if ($null -ne $dffaCustomerServicePrincipal -and $null -ne $bd0cCustomerServicePrincipal -and
        (Test-OldResourceServicePrincipalIsRefreshed -ServicePrincipal $dffaCustomerServicePrincipal) -and
        (Test-NewResourceServicePrincipalOwnsSharedAudience -ServicePrincipal $bd0cCustomerServicePrincipal)) {
        Write-Log -Level INFO -Message ("  OK Audience migration - new resource (bd0c) owns {0}" -f $newResourceIdentifierUri)
    }
    else {
        Write-Log -Level ERROR -Message '  WARN Audience migration - old/new resource servicePrincipalNames are not in the expected migrated state'
    }

    if (-not $selectedClientVerify) {
        if ($delegatedProofRan) {
            Write-Log -Level INFO -Message '  OK Azure CLI delegated token - diagnostic passed'
        }
        else {
            Write-LogWarn '  WAIT Azure CLI delegated token - action needed; see the earlier FAIL/remedy lines'
        }

        Write-Log -Level INFO -Message '  INFO Selected-client app-only proof - skipped because --client-id was not provided'
        Write-Log -Level INFO -Message '  INFO App-specific token proof - run verify --client-id <client-app-id-or-service-principal-id> for each customer app shown by inventory'
        Write-Log -Level INFO -Message ("  INFO ADME endpoint - not tested; run ./test.sh <adme-instance-host> `"{0}/.default`"" -f $newResourceIdentifierUri)
        if ($script:VerifyFailures -gt 0) {
            Write-Log -Level ERROR -Message ("  WARN Verification failed - {0} failing check(s)" -f $script:VerifyFailures)
            Write-Log -Level ERROR -Message ("SUMMARY: verify found {0} failing check(s)" -f $script:VerifyFailures)
            throw 'verify detected broken migration state'
        }

        Write-Log -Level INFO -Message 'SUMMARY: verify complete - tenant audience migration is healthy and Azure CLI delegated diagnostic passed'
        return
    }

    Write-Log -Level INFO -Message '  INFO Selected client configuration - not checked by verify; run adme-entra-inventory.sh for API permissions and admin consent status'
    if ($appOnlyProofRan) {
        Write-Log -Level INFO -Message '  OK App-only token proof - passed'
    }
    elseif ($appOnlyProofAttempted) {
        Write-LogWarn '  WAIT App-only token proof - action needed; see the earlier FAIL/remedy lines'
    }
    elseif ($null -ne $targetPermissionContract -and -not [bool]$targetPermissionContract.RequiresAppRole) {
        Write-Log -Level INFO -Message '  INFO App-only token proof - not applicable because the target resource has no enabled app roles'
    }
    else {
        Write-LogWarn '  WAIT App-only token proof - skipped; export CLIENT_SECRET=<CLIENT_SECRET> to run it'
    }

    Write-Log -Level INFO -Message '  INFO Azure CLI delegated token - skipped because --client-id verifies the selected customer app; run verify without --client-id for Azure CLI delegated proof'
    Write-Log -Level INFO -Message ("  INFO ADME endpoint - not tested; run ./test.sh <adme-instance-host> `"{0}/.default`"" -f $newResourceIdentifierUri)
    if ($script:VerifyFailures -gt 0) {
        Write-Log -Level ERROR -Message ("  WARN Verification failed - {0} failing check(s)" -f $script:VerifyFailures)
        Write-Log -Level ERROR -Message ("SUMMARY: verify found {0} failing check(s)" -f $script:VerifyFailures)
        throw 'verify detected broken migration state'
    }

    if ($appOnlyProofRan) {
        Write-Log -Level INFO -Message 'SUMMARY: verify complete - selected-client app-only token proof passed'
    }
    elseif ($null -ne $targetPermissionContract -and -not [bool]$targetPermissionContract.RequiresAppRole) {
        Write-Log -Level INFO -Message 'SUMMARY: verify complete - selected-client app-only token proof is not applicable for this delegated-only target resource'
    }
    else {
        Write-LogWarn 'SUMMARY: verify completed without selected-client app-only token proof'
    }
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    Initialize-Defaults
    Apply-EnvironmentOverrides
    Initialize-ParameterOverrides
    $script:CommandContext = Resolve-CommandContext -Arguments $script:RemainingArguments

    if ($script:Options.ShowHelp) {
        Show-Usage
        return
    }

    Initialize-Logging
    Assert-AzCliAvailable
    Write-Log -Level INFO -Message ("Starting command: {0} {1}" -f $script:CommandContext.Command, $script:CommandContext.Subcommand)
    Write-Log -Level INFO -Message ("Log file: {0}" -f $script:LogFile)

    switch ("{0}/{1}" -f $script:CommandContext.Command, $script:CommandContext.Subcommand) {
        'migrate/adme-audience' { Invoke-MigrateAdmeAudience; return }
        'migrate/api-permissions' { Invoke-MigrateApiPermissions; return }
        'verify/' { Invoke-Verify; return }
        default { throw ("Unsupported command context: {0}/{1}" -f $script:CommandContext.Command, $script:CommandContext.Subcommand) }
    }
}

try {
    Invoke-Main
}
catch {
    $message = $_.Exception.Message
    if ($script:LogInitialized) {
        Write-Log -Level ERROR -Message $message
    }
    else {
        [Console]::Error.WriteLine((Protect-LogMessage -Message $message))
    }

    exit 1
}
