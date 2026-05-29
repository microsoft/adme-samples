Set-StrictMode -Version Latest
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$script:GraphServiceRoot = "https://graph.microsoft.com"
$script:GraphBaseUrl = "$script:GraphServiceRoot/v1.0"

function Test-IsWindowsPlatform {
    [CmdletBinding()]
    param()

    if ($env:OS -eq 'Windows_NT') {
        return $true
    }

    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Resolve-GraphRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if ($Uri -match '^[a-zA-Z][a-zA-Z0-9+\.-]*://') {
        return $Uri
    }

    if ($Uri.StartsWith('/')) {
        return '{0}{1}' -f $script:GraphServiceRoot, $Uri
    }

    return '{0}/{1}' -f $script:GraphBaseUrl.TrimEnd('/'), $Uri.TrimStart('/')
}

function ConvertFrom-JsonText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return $Text | ConvertFrom-Json
}

function ConvertTo-ProcessOutputText {
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

function ConvertTo-StringArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $values = New-Object System.Collections.ArrayList
    if ($null -eq $InputObject) {
        return [string[]]@()
    }

    foreach ($item in $InputObject) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        [void]$values.Add($text)
    }

    return [string[]]$values.ToArray([string])
}

function Get-ObjectPropertyValue {
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

function Test-GraphItemEnabled {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $isEnabled = Get-ObjectPropertyValue -InputObject $InputObject -Name 'isEnabled'
    if ($null -eq $isEnabled) {
        return $true
    }

    return [bool]$isEnabled
}

function Get-AzRestStatusCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $patterns = @(
        'Response status:\s+(?<Status>\d{3})',
        'StatusCode:\s+(?<Status>\d{3})',
        'HTTP/\S+\s+(?<Status>\d{3})',
        'returned error:\s+\(?(?<Status>\d{3})\)?'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return [int]$match.Groups['Status'].Value
        }
    }

    return $null
}

function Get-AzRestErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $lines = @(
        $Text -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $errorLine = @($lines | Where-Object { $_ -like 'ERROR:*' } | Select-Object -Last 1)[0]
    if (-not [string]::IsNullOrWhiteSpace($errorLine)) {
        return ($errorLine -replace '^ERROR:\s+[^:]+:\s+', 'ERROR: ')
    }

    if ($lines.Count -gt 0) {
        return $lines[-1]
    }

    return 'az rest failed.'
}

function ConvertFrom-JwtPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $segments = @($Token -split '\.')
    if ($segments.Count -lt 2 -or [string]::IsNullOrWhiteSpace($segments[1])) {
        throw 'JWT must contain a payload segment.'
    }

    $payloadSegment = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payloadSegment.Length % 4) {
        0 { }
        2 { $payloadSegment += '==' }
        3 { $payloadSegment += '=' }
        default { throw 'JWT payload segment is not valid base64url text.' }
    }

    try {
        $payloadBytes = [Convert]::FromBase64String($payloadSegment)
    }
    catch {
        throw ('JWT payload decode failed: {0}' -f $_.Exception.Message)
    }

    $payloadText = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
    return ConvertFrom-JsonText -Text $payloadText
}

function Get-AzCliPath {
    [CmdletBinding()]
    param()

    $candidateNames = if (Test-IsWindowsPlatform) {
        @('az.cmd', 'az.exe', 'az.bat', 'az')
    }
    else {
        @('az')
    }

    foreach ($pathEntry in ($env:PATH -split [IO.Path]::PathSeparator)) {
        if ([string]::IsNullOrWhiteSpace($pathEntry)) {
            continue
        }

        foreach ($candidateName in $candidateNames) {
            $candidatePath = Join-Path $pathEntry $candidateName
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                return $candidatePath
            }
        }
    }

    return $null
}

function Test-AzCliAvailable {
    [CmdletBinding()]
    param()

    return $null -ne (Get-AzCliPath)
}

function Invoke-WithAzConfigDir {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    if ([string]::IsNullOrWhiteSpace($ConfigDir)) {
        return & $ScriptBlock
    }

    $originalConfigDir = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR')
    try {
        $env:AZURE_CONFIG_DIR = $ConfigDir
        return & $ScriptBlock
    }
    finally {
        if ($null -eq $originalConfigDir) {
            Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:AZURE_CONFIG_DIR = $originalConfigDir
        }
    }
}

function Invoke-GraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [hashtable]$Headers,

        [object]$Body,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [int[]]$AllowedStatusCodes,

        [switch]$Raw
    )

    if (-not (Test-AzCliAvailable)) {
        throw "Azure CLI ('az') is required but was not found on PATH. Install Azure CLI or run inside the repo devshell."
    }

    $azPath = Get-AzCliPath
    $requestUri = Resolve-GraphRequestUri -Uri $Uri
    $captureStatus = $PSBoundParameters.ContainsKey('AllowedStatusCodes')
    $arguments = @('rest', '--method', $Method, '--url', $requestUri, '--output', 'json')
    if ($captureStatus) {
        $arguments += '--debug'
    }

    if ($Headers) {
        $headerArgs = @(foreach ($entry in $Headers.GetEnumerator()) {
            "{0}={1}" -f $entry.Key, $entry.Value
        })
        if ($headerArgs.Count -gt 0) {
            $arguments += '--headers'
            $arguments += $headerArgs
        }
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $bodyValue = if ($Body -is [string]) {
            $Body
        }
        else {
            $Body | ConvertTo-Json -Depth 20 -Compress
        }

        $arguments += '--body'
        $arguments += $bodyValue
    }

    $errorText = ''
    if ($captureStatus) {
        $stderrPath = [IO.Path]::GetTempFileName()
        try {
            $output = Invoke-WithAzConfigDir -ConfigDir $ConfigDir -ScriptBlock {
                & $azPath @arguments 2> $stderrPath
            }
            if (Test-Path -LiteralPath $stderrPath) {
                $errorText = [IO.File]::ReadAllText($stderrPath)
            }
        }
        finally {
            Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
        }
    }
    else {
        $output = Invoke-WithAzConfigDir -ConfigDir $ConfigDir -ScriptBlock {
            & $azPath @arguments 2>&1
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $combinedError = ((ConvertTo-ProcessOutputText -Output $output) + [Environment]::NewLine + $errorText).Trim()
        $statusCode = Get-AzRestStatusCode -Text $combinedError
        if ($captureStatus -and $null -ne $statusCode -and $AllowedStatusCodes -contains $statusCode) {
            return [pscustomobject]@{
                StatusCode = $statusCode
                IsSuccessStatusCode = $false
                Body = $null
                RawContent = $null
                ErrorMessage = Get-AzRestErrorMessage -Text $combinedError
            }
        }

        throw ('az rest failed: {0}' -f (Get-AzRestErrorMessage -Text $combinedError))
    }

    $text = (ConvertTo-ProcessOutputText -Output $output).Trim()
    $content = if ($Raw) {
        $text
    }
    else {
        ConvertFrom-JsonText -Text $text
    }

    if ($captureStatus) {
        $statusCode = Get-AzRestStatusCode -Text $errorText
        if ($null -eq $statusCode) {
            $statusCode = if ([string]::IsNullOrWhiteSpace($text)) { 204 } else { 200 }
        }

        return [pscustomobject]@{
            StatusCode = $statusCode
            IsSuccessStatusCode = $true
            Body = $content
            RawContent = $text
            ErrorMessage = $null
        }
    }

    return $content
}

function Invoke-AzCliCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [switch]$Raw
    )

    if (-not (Test-AzCliAvailable)) {
        throw "Azure CLI ('az') is required but was not found on PATH. Install Azure CLI or run inside the repo devshell."
    }

    $azPath = Get-AzCliPath
    $output = Invoke-WithAzConfigDir -ConfigDir $ConfigDir -ScriptBlock {
        & $azPath @Arguments 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("az command failed: {0}" -f ((ConvertTo-ProcessOutputText -Output $output).Trim()))
    }

    $text = (ConvertTo-ProcessOutputText -Output $output).Trim()
    if ($Raw) {
        return $text
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ConvertFrom-JsonText -Text $text
}

function Resolve-ServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $uri = "{0}/servicePrincipals?`$filter=appId eq '{1}'" -f $script:GraphBaseUrl, $AppId
    $response = Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir

    if ($null -eq $response -or $null -eq $response.value -or @($response.value).Count -eq 0) {
        return $null
    }

    return $response.value[0]
}

function Get-CurrentTenantId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $tenantId = Invoke-AzCliCommand -Arguments @('account', 'show', '--query', 'tenantId', '-o', 'tsv') -ConfigDir $ConfigDir -Raw
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        return $null
    }

    return $tenantId.Trim()
}

function Get-ServicePrincipalById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [switch]$AllowMissing
    )

    $uri = "/v1.0/servicePrincipals/{0}" -f $ServicePrincipalId
    if ($AllowMissing) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir -AllowedStatusCodes 404
        if (-not $response.IsSuccessStatusCode -and $response.StatusCode -eq 404) {
            return $null
        }

        return $response.Body
    }

    return Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir
}

function Get-ServicePrincipalIdByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $servicePrincipal = Resolve-ServicePrincipal -AppId $AppId -ConfigDir $ConfigDir
    if ($null -eq $servicePrincipal) {
        return $null
    }

    return [string]$servicePrincipal.id
}

function Get-ApplicationByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $uri = "/v1.0/applications?`$filter=appId eq '{0}'&`$select=id,appId,displayName,identifierUris" -f $AppId
    $response = Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir
    if ($null -eq $response -or $null -eq $response.value -or @($response.value).Count -eq 0) {
        return $null
    }

    return $response.value[0]
}

function Get-ApplicationById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationObjectId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [switch]$AllowMissing
    )

    $uri = "/v1.0/applications/{0}?`$select=id,appId,displayName,identifierUris,requiredResourceAccess" -f $ApplicationObjectId
    if ($AllowMissing) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir -AllowedStatusCodes 404
        if (-not $response.IsSuccessStatusCode -and $response.StatusCode -eq 404) {
            return $null
        }

        return $response.Body
    }

    return Invoke-GraphRequest -Method GET -Uri $uri -ConfigDir $ConfigDir
}

function New-RequiredResourceAccessEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Role', 'Scope')]
        [string]$Type
    )

    return [pscustomobject][ordered]@{
        id = $Id
        type = $Type
    }
}

function Add-RequiredResourceAccessEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EntryByKey,

        [AllowNull()]
        [object]$Entry
    )

    if ($null -eq $Entry) {
        return
    }

    $id = [string](Get-ObjectPropertyValue -InputObject $Entry -Name 'id')
    $type = [string](Get-ObjectPropertyValue -InputObject $Entry -Name 'type')
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($type)) {
        return
    }

    if ($type -ne 'Role' -and $type -ne 'Scope') {
        return
    }

    $key = '{0}:{1}' -f $type, $id
    if (-not $EntryByKey.ContainsKey($key)) {
        $EntryByKey[$key] = New-RequiredResourceAccessEntry -Id $id -Type $type
    }
}

function Build-RequiredResourceAccess {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$CurrentRequiredResourceAccess,

        [Parameter(Mandatory = $true)]
        [string]$OldResourceAppId,

        [Parameter(Mandatory = $true)]
        [string]$NewResourceAppId,

        [Parameter(Mandatory = $true)]
        [string]$NewResourceScopeId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$NewResourceAppRoleId,

        [switch]$IncludeAppRole
    )

    $result = New-Object System.Collections.ArrayList
    $newResourceAccessByKey = @{}

    foreach ($entry in @($CurrentRequiredResourceAccess)) {
        if ($null -eq $entry) {
            continue
        }

        $resourceAppId = [string](Get-ObjectPropertyValue -InputObject $entry -Name 'resourceAppId')
        if ([string]::IsNullOrWhiteSpace($resourceAppId)) {
            continue
        }

        if ($resourceAppId -eq $OldResourceAppId) {
            continue
        }

        if ($resourceAppId -eq $NewResourceAppId) {
            continue
        }

        $resourceAccessValues = New-Object System.Collections.ArrayList
        foreach ($resourceAccess in @((Get-ObjectPropertyValue -InputObject $entry -Name 'resourceAccess'))) {
            $id = [string](Get-ObjectPropertyValue -InputObject $resourceAccess -Name 'id')
            $type = [string](Get-ObjectPropertyValue -InputObject $resourceAccess -Name 'type')
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($type)) {
                continue
            }

            [void]$resourceAccessValues.Add((New-RequiredResourceAccessEntry -Id $id -Type $type))
        }

        if ($resourceAccessValues.Count -eq 0) {
            continue
        }

        [void]$result.Add([pscustomobject][ordered]@{
            resourceAppId = $resourceAppId
            resourceAccess = @($resourceAccessValues.ToArray())
        })
    }

    Add-RequiredResourceAccessEntry -EntryByKey $newResourceAccessByKey -Entry (New-RequiredResourceAccessEntry -Id $NewResourceScopeId -Type 'Scope')
    if ($IncludeAppRole) {
        if ([string]::IsNullOrWhiteSpace($NewResourceAppRoleId)) {
            throw 'NewResourceAppRoleId is required when IncludeAppRole is set.'
        }

        Add-RequiredResourceAccessEntry -EntryByKey $newResourceAccessByKey -Entry (New-RequiredResourceAccessEntry -Id $NewResourceAppRoleId -Type 'Role')
    }

    $mergedNewResourceAccess = @($newResourceAccessByKey.Values | Sort-Object -Property type, id)
    if ($mergedNewResourceAccess.Count -gt 0) {
        [void]$result.Add([pscustomobject][ordered]@{
            resourceAppId = $NewResourceAppId
            resourceAccess = @($mergedNewResourceAccess)
        })
    }

    return @($result.ToArray())
}

function Update-ApplicationRequiredResourceAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationObjectId,

        [AllowNull()]
        [object]$RequiredResourceAccess,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    Invoke-GraphRequest -Method PATCH -Uri ("/v1.0/applications/{0}" -f $ApplicationObjectId) -ConfigDir $ConfigDir -Body @{
        requiredResourceAccess = @($RequiredResourceAccess)
    } | Out-Null
}

function Ensure-ServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId
    )

    $existingServicePrincipalId = Get-ServicePrincipalIdByAppId -AppId $AppId -ConfigDir $ConfigDir
    if (-not [string]::IsNullOrWhiteSpace($existingServicePrincipalId)) {
        return $existingServicePrincipalId
    }

    $createError = $null
    try {
        $createdServicePrincipal = Invoke-AzCliCommand -Arguments @('ad', 'sp', 'create', '--id', $AppId, '-o', 'json') -ConfigDir $ConfigDir
        if ($null -ne $createdServicePrincipal -and -not [string]::IsNullOrWhiteSpace([string]$createdServicePrincipal.id)) {
            return [string]$createdServicePrincipal.id
        }
    }
    catch {
        $createError = $_.Exception.Message
    }

    $graphFallbackError = $null
    try {
        $createdServicePrincipal = Invoke-GraphRequest -Method POST -Uri '/v1.0/servicePrincipals' -ConfigDir $ConfigDir -Body @{ appId = $AppId }
        if ($null -ne $createdServicePrincipal -and -not [string]::IsNullOrWhiteSpace([string]$createdServicePrincipal.id)) {
            return [string]$createdServicePrincipal.id
        }
    }
    catch {
        $graphFallbackError = $_.Exception.Message
    }

    $existingServicePrincipalId = Get-ServicePrincipalIdByAppId -AppId $AppId -ConfigDir $ConfigDir
    if (-not [string]::IsNullOrWhiteSpace($existingServicePrincipalId)) {
        return $existingServicePrincipalId
    }

    $message = "Service principal for appId $AppId could not be created automatically"
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $message += " in tenant $TenantId"
    }

    if (-not [string]::IsNullOrWhiteSpace($createError)) {
        $message += ". Azure CLI create failed: $createError"
    }

    if (-not [string]::IsNullOrWhiteSpace($graphFallbackError)) {
        $message += ". Graph fallback failed: $graphFallbackError"
    }

    throw $message
}

function Wait-ServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [int]$MaxAttempts = 5,

        [int]$DelaySeconds = 2
    )

    if ($MaxAttempts -lt 1) {
        throw 'MaxAttempts must be at least 1.'
    }

    if ($DelaySeconds -lt 0) {
        throw 'DelaySeconds cannot be negative.'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $servicePrincipalId = Get-ServicePrincipalIdByAppId -AppId $AppId -ConfigDir $ConfigDir
        if (-not [string]::IsNullOrWhiteSpace($servicePrincipalId)) {
            return $servicePrincipalId
        }

        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "Service principal for appId $AppId did not appear after $MaxAttempts attempts."
}

function Update-ServicePrincipalTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [AllowNull()]
        [object]$Tags,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    Invoke-GraphRequest -Method PATCH -Uri ("/v1.0/servicePrincipals/{0}" -f $ServicePrincipalId) -ConfigDir $ConfigDir -Body @{
        tags = @(ConvertTo-StringArray -InputObject $Tags)
    } | Out-Null
}

function Update-ServicePrincipalNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [AllowNull()]
        [object]$ServicePrincipalNames,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $response = Invoke-GraphRequest -Method PATCH -Uri ("/v1.0/servicePrincipals/{0}" -f $ServicePrincipalId) -ConfigDir $ConfigDir -Body @{
        servicePrincipalNames = @(ConvertTo-StringArray -InputObject $ServicePrincipalNames)
    } -AllowedStatusCodes 400, 403, 404, 409

    return [pscustomobject]@{
        Success = [bool]$response.IsSuccessStatusCode
        StatusCode = [int]$response.StatusCode
        ErrorMessage = $response.ErrorMessage
    }
}

function Remove-ServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    Invoke-GraphRequest -Method DELETE -Uri ("/v1.0/servicePrincipals/{0}" -f $ServicePrincipalId) -ConfigDir $ConfigDir -Raw | Out-Null
}

function Test-OAuth2PermissionGrantScopeValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$DesiredScopeValue
    )

    foreach ($scopeToken in @($Scope -split '\s+')) {
        if (-not [string]::IsNullOrWhiteSpace($scopeToken) -and $scopeToken -eq $DesiredScopeValue) {
            return $true
        }
    }

    return $false
}

function Merge-OAuth2PermissionGrantScope {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExistingScope,

        [Parameter(Mandatory = $true)]
        [string]$DesiredScopeValue
    )

    $scopeValues = New-Object System.Collections.ArrayList
    foreach ($scopeToken in @($ExistingScope -split '\s+') + @($DesiredScopeValue)) {
        if ([string]::IsNullOrWhiteSpace($scopeToken) -or $scopeValues -contains $scopeToken) {
            continue
        }

        [void]$scopeValues.Add($scopeToken)
    }

    return [string]::Join(' ', @($scopeValues | Sort-Object))
}

function Ensure-OAuth2PermissionGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ScopeValue,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $queryUri = "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '{0}' and resourceId eq '{1}' and consentType eq 'AllPrincipals'" -f $ClientServicePrincipalId, $ResourceServicePrincipalId
    $existingResponse = Invoke-GraphRequest -Method GET -Uri $queryUri -ConfigDir $ConfigDir
    $existingGrants = @($existingResponse.value)
    $existingGrant = if ($existingGrants.Count -gt 0) { $existingGrants[0] } else { $null }

    if ($null -ne $existingGrant) {
        $existingScope = [string]$existingGrant.scope
        if (Test-OAuth2PermissionGrantScopeValue -Scope $existingScope -DesiredScopeValue $ScopeValue) {
            return [pscustomobject]@{
                Action = 'Unchanged'
                GrantId = [string]$existingGrant.id
                Scope = $existingScope
            }
        }

        $mergedScope = Merge-OAuth2PermissionGrantScope -ExistingScope $existingScope -DesiredScopeValue $ScopeValue
        Invoke-GraphRequest -Method PATCH -Uri ("/v1.0/oauth2PermissionGrants/{0}" -f $existingGrant.id) -ConfigDir $ConfigDir -Body @{
            scope = $mergedScope
        } | Out-Null

        return [pscustomobject]@{
            Action = 'Updated'
            GrantId = [string]$existingGrant.id
            Scope = $mergedScope
        }
    }

    try {
        $createdGrant = Invoke-GraphRequest -Method POST -Uri '/v1.0/oauth2PermissionGrants' -ConfigDir $ConfigDir -Body @{
            clientId = $ClientServicePrincipalId
            consentType = 'AllPrincipals'
            resourceId = $ResourceServicePrincipalId
            scope = $ScopeValue
        }

        return [pscustomobject]@{
            Action = 'Created'
            GrantId = [string]$createdGrant.id
            Scope = $ScopeValue
        }
    }
    catch {
        if ($_.Exception.Message -like '*Permission entry already exists*') {
            return [pscustomobject]@{
                Action = 'AlreadyExists'
                GrantId = $null
                Scope = $ScopeValue
            }
        }

        throw
    }
}

function Get-OAuth2PermissionGrantCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ScopeValue,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $queryUri = "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '{0}' and resourceId eq '{1}' and consentType eq 'AllPrincipals'" -f $ClientServicePrincipalId, $ResourceServicePrincipalId
    $existingResponse = Invoke-GraphRequest -Method GET -Uri $queryUri -ConfigDir $ConfigDir
    $count = 0
    foreach ($grant in @($existingResponse.value)) {
        if (Test-OAuth2PermissionGrantScopeValue -Scope ([string]$grant.scope) -DesiredScopeValue $ScopeValue) {
            $count++
        }
    }

    return $count
}

function Find-AppRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$AppRoleId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    if ([string]::IsNullOrWhiteSpace($AppRoleId)) {
        return $null
    }

    $response = Invoke-GraphRequest -Method GET -Uri ("/v1.0/servicePrincipals/{0}/appRoleAssignedTo" -f $ResourceServicePrincipalId) -ConfigDir $ConfigDir
    foreach ($assignment in @($response.value)) {
        if ([string](Get-ObjectPropertyValue -InputObject $assignment -Name 'principalId') -eq $ClientServicePrincipalId -and
            [string](Get-ObjectPropertyValue -InputObject $assignment -Name 'appRoleId') -eq $AppRoleId) {
            return $assignment
        }
    }

    return $null
}

function Ensure-AppRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$AppRoleId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    $existingAssignment = Find-AppRoleAssignment -ResourceServicePrincipalId $ResourceServicePrincipalId -ClientServicePrincipalId $ClientServicePrincipalId -AppRoleId $AppRoleId -ConfigDir $ConfigDir
    if ($null -ne $existingAssignment) {
        return [pscustomobject]@{
            Action = 'Unchanged'
            AssignmentId = [string](Get-ObjectPropertyValue -InputObject $existingAssignment -Name 'id')
        }
    }

    try {
        $createdAssignment = Invoke-GraphRequest -Method POST -Uri ("/v1.0/servicePrincipals/{0}/appRoleAssignedTo" -f $ResourceServicePrincipalId) -ConfigDir $ConfigDir -Body @{
            principalId = $ClientServicePrincipalId
            resourceId = $ResourceServicePrincipalId
            appRoleId = $AppRoleId
        }

        return [pscustomobject]@{
            Action = 'Created'
            AssignmentId = [string](Get-ObjectPropertyValue -InputObject $createdAssignment -Name 'id')
        }
    }
    catch {
        if ($_.Exception.Message -like '*Permission being assigned already exists*' -or $_.Exception.Message -like '*already exists*') {
            return [pscustomobject]@{
                Action = 'AlreadyExists'
                AssignmentId = $null
            }
        }

        throw
    }
}

function Wait-AppRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$AppRoleId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir,

        [int]$MaxAttempts = 3,

        [int]$DelaySeconds = 3
    )

    if ($MaxAttempts -lt 1) {
        throw 'MaxAttempts must be at least 1.'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $assignment = Find-AppRoleAssignment -ResourceServicePrincipalId $ResourceServicePrincipalId -ClientServicePrincipalId $ClientServicePrincipalId -AppRoleId $AppRoleId -ConfigDir $ConfigDir
        if ($null -ne $assignment) {
            return $assignment
        }

        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw 'client app app role assignment to new resource (bd0c) was not visible after creation'
}

function Get-AppRoleAssignmentCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ClientServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$AppRoleId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigDir
    )

    if ([string]::IsNullOrWhiteSpace($AppRoleId)) {
        return 0
    }

    $response = Invoke-GraphRequest -Method GET -Uri ("/v1.0/servicePrincipals/{0}/appRoleAssignedTo" -f $ResourceServicePrincipalId) -ConfigDir $ConfigDir
    $count = 0
    foreach ($assignment in @($response.value)) {
        if ([string](Get-ObjectPropertyValue -InputObject $assignment -Name 'principalId') -eq $ClientServicePrincipalId -and
            [string](Get-ObjectPropertyValue -InputObject $assignment -Name 'appRoleId') -eq $AppRoleId) {
            $count++
        }
    }

    return $count
}

Export-ModuleMember -Function Test-AzCliAvailable, Invoke-GraphRequest, Invoke-AzCliCommand, Resolve-ServicePrincipal, ConvertFrom-JwtPayload, Get-CurrentTenantId, Get-ServicePrincipalById, Get-ServicePrincipalIdByAppId, Get-ApplicationByAppId, Get-ApplicationById, Build-RequiredResourceAccess, Update-ApplicationRequiredResourceAccess, Ensure-ServicePrincipal, Wait-ServicePrincipal, Update-ServicePrincipalTags, Update-ServicePrincipalNames, Remove-ServicePrincipal, Ensure-OAuth2PermissionGrant, Get-OAuth2PermissionGrantCount, Find-AppRoleAssignment, Ensure-AppRoleAssignment, Wait-AppRoleAssignment, Get-AppRoleAssignmentCount