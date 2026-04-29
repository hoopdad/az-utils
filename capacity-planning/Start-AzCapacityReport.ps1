[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [string]$SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SubscriptionFile,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path,

    [ValidateRange(1, 3650)]
    [int]$DaysBack = 30,

    [Parameter()]
    [switch]$SkipElevated

)

$script:piiMap = @{}
$script:piiCounters = @{
    SubscriptionId   = 0
    SubscriptionName = 0
    TenantId         = 0
    Email            = 0
    ObjectId         = 0
    ResourceGroup    = 0
    StorageAccount   = 0
    Guid             = 0
}
$script:logBuilder = [System.Text.StringBuilder]::new()
$script:guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:emailPattern = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'

function New-PiiPseudonym {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SubscriptionId', 'SubscriptionName', 'TenantId', 'Email', 'ObjectId', 'ResourceGroup', 'StorageAccount', 'Guid')]
        [string]$Category
    )

    $script:piiCounters[$Category] = [int]$script:piiCounters[$Category] + 1
    $index = $script:piiCounters[$Category]

    switch ($Category) {
        'SubscriptionId' { return "Subscription-$index" }
        'SubscriptionName' { return "SubName-$index" }
        'TenantId' { return "Tenant-$index" }
        'Email' { return "user-$index@example.com" }
        'ObjectId' { return "ObjectId-$index" }
        'ResourceGroup' { return "ResourceGroup-$index" }
        'StorageAccount' { return "StorageAccount-$index" }
        'Guid' { return "GUID-$index" }
    }
}

function Register-Pii {
    param(
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [ValidateSet('SubscriptionId', 'SubscriptionName', 'TenantId', 'Email', 'ObjectId', 'ResourceGroup', 'StorageAccount', 'Guid')]
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmedValue = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
        return $null
    }

    if ($Category -eq 'ResourceGroup' -and $trimmedValue -eq 'global') {
        return $trimmedValue
    }

    if ($script:piiMap.ContainsKey($trimmedValue)) {
        return $script:piiMap[$trimmedValue]
    }

    $pseudonym = New-PiiPseudonym -Category $Category
    $script:piiMap[$trimmedValue] = $pseudonym
    return $pseudonym
}

function Register-PiiFromResourceId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return
    }

    $subscriptionMatch = [regex]::Match($ResourceId, "/subscriptions/(?<subscription>$($script:guidPattern))", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($subscriptionMatch.Success) {
        Register-Pii -Value $subscriptionMatch.Groups['subscription'].Value -Category 'SubscriptionId' | Out-Null
    }

    $resourceGroupMatch = [regex]::Match($ResourceId, '/resourceGroups/(?<resourceGroup>[^/]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($resourceGroupMatch.Success) {
        Register-Pii -Value $resourceGroupMatch.Groups['resourceGroup'].Value -Category 'ResourceGroup' | Out-Null
    }

    $storageAccountMatch = [regex]::Match($ResourceId, '/storageAccounts/(?<storageAccount>[^/]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($storageAccountMatch.Success) {
        Register-Pii -Value $storageAccountMatch.Groups['storageAccount'].Value -Category 'StorageAccount' | Out-Null
    }
}

function Register-PiiFromProperties {
    param(
        [AllowNull()]
        [object]$InputObject,

        [AllowNull()]
        [string]$TypeHint,

        [AllowNull()]
        [string]$NameHint
    )

    if ($null -eq $InputObject) {
        return
    }

    if ($InputObject -is [string]) {
        $text = [string]$InputObject
        foreach ($emailMatch in [regex]::Matches($text, $script:emailPattern)) {
            Register-Pii -Value $emailMatch.Value -Category 'Email' | Out-Null
        }
        if ($text -match '(?i)^/subscriptions/') {
            Register-PiiFromResourceId -ResourceId $text
        }
        return
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Collections.IDictionary])) {
        foreach ($item in $InputObject) {
            Register-PiiFromProperties -InputObject $item
        }
        return
    }

    $propertyEntries = @()
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $propertyEntries += [pscustomobject]@{
                Name  = [string]$key
                Value = $InputObject[$key]
            }
        }
    }
    else {
        $propertyEntries = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } | ForEach-Object {
            [pscustomobject]@{
                Name  = [string]$_.Name
                Value = $_.Value
            }
        })
    }

    if ($propertyEntries.Count -eq 0) {
        return
    }

    $effectiveType = $TypeHint
    if ([string]::IsNullOrWhiteSpace($effectiveType)) {
        $typeProperty = $propertyEntries | Where-Object { $_.Name -in @('type', 'resourceType') } | Select-Object -First 1
        if ($null -ne $typeProperty -and -not [string]::IsNullOrWhiteSpace([string]$typeProperty.Value)) {
            $effectiveType = [string]$typeProperty.Value
        }
    }

    $effectiveName = $NameHint
    if ([string]::IsNullOrWhiteSpace($effectiveName)) {
        $nameProperty = $propertyEntries | Where-Object { $_.Name -eq 'name' } | Select-Object -First 1
        if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            $effectiveName = [string]$nameProperty.Value
        }
    }

    foreach ($propertyEntry in $propertyEntries) {
        $name = $propertyEntry.Name
        $value = $propertyEntry.Value

        switch -Regex ($name) {
            '^subscriptionId$' {
                Register-Pii -Value ([string]$value) -Category 'SubscriptionId' | Out-Null
                continue
            }
            '^subscriptionName$' {
                Register-Pii -Value ([string]$value) -Category 'SubscriptionName' | Out-Null
                continue
            }
            '^tenantId$' {
                Register-Pii -Value ([string]$value) -Category 'TenantId' | Out-Null
                continue
            }
            '^(objectId|principalId)$' {
                Register-Pii -Value ([string]$value) -Category 'ObjectId' | Out-Null
                continue
            }
            '^(email|userPrincipalName|principalName)$' {
                Register-Pii -Value ([string]$value) -Category 'Email' | Out-Null
                continue
            }
            '^(resourceGroup|resourceGroupName)$' {
                Register-Pii -Value ([string]$value) -Category 'ResourceGroup' | Out-Null
                continue
            }
            '^(storageAccount|storageAccountName)$' {
                Register-Pii -Value ([string]$value) -Category 'StorageAccount' | Out-Null
                continue
            }
            '^(id|resourceId)$' {
                Register-PiiFromResourceId -ResourceId ([string]$value)
            }
        }

        Register-PiiFromProperties -InputObject $value
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveType) -and $effectiveType -match 'Microsoft\.Storage/storageAccounts' -and -not [string]::IsNullOrWhiteSpace($effectiveName)) {
        Register-Pii -Value $effectiveName -Category 'StorageAccount' | Out-Null
    }
}

function ConvertTo-Obfuscated {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    $obfuscated = [string]$Text

    foreach ($match in [regex]::Matches($obfuscated, '(?i)/subscriptions/' + $script:guidPattern + '/resourceGroups/[^\s]+')) {
        Register-PiiFromResourceId -ResourceId $match.Value
    }

    foreach ($match in [regex]::Matches($obfuscated, '(?i)(?:tenant(?:\s+id)?|tenantId)[^0-9a-fA-F]*(?<tenant>' + $script:guidPattern + ')')) {
        Register-Pii -Value $match.Groups['tenant'].Value -Category 'TenantId' | Out-Null
    }

    foreach ($match in [regex]::Matches($obfuscated, '(?i)(?:object(?:\s+id)?|principal(?:\s+id)?|objectId|principalId)[^0-9a-fA-F]*(?<object>' + $script:guidPattern + ')')) {
        Register-Pii -Value $match.Groups['object'].Value -Category 'ObjectId' | Out-Null
    }

    foreach ($emailMatch in [regex]::Matches($obfuscated, $script:emailPattern)) {
        Register-Pii -Value $emailMatch.Value -Category 'Email' | Out-Null
    }

    foreach ($guidMatch in [regex]::Matches($obfuscated, $script:guidPattern)) {
        Register-Pii -Value $guidMatch.Value -Category 'Guid' | Out-Null
    }

    $obfuscated = [regex]::Replace($obfuscated, '(?i)([A-Z]:\\Users\\)[^\\]+', '$1<user>')
    $obfuscated = [regex]::Replace($obfuscated, '(?i)(/home/)[^/\s]+', '$1<user>')

    $replacementEntries = @($script:piiMap.GetEnumerator() | Sort-Object { $_.Key.Length } -Descending)
    foreach ($entry in $replacementEntries) {
        $obfuscated = [regex]::Replace(
            $obfuscated,
            [regex]::Escape([string]$entry.Key),
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) [string]$entry.Value },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $obfuscated
}

function Add-LogEntry {
    param(
        [AllowNull()]
        [string]$Message = '',

        [Parameter()]
        [switch]$NoNewline
    )

    [void]$script:logBuilder.Append((ConvertTo-Obfuscated -Text $Message))
    if (-not $NoNewline) {
        [void]$script:logBuilder.AppendLine()
    }
}

function Write-Log {
    param(
        [AllowNull()]
        [object]$Message = '',

        [Parameter()]
        [System.ConsoleColor]$ForegroundColor,

        [Parameter()]
        [switch]$NoNewline
    )

    $text = if ($null -eq $Message) { '' } else { [string]$Message }

    $writeHostParams = @{ Object = $text }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        $writeHostParams['ForegroundColor'] = $ForegroundColor
    }
    if ($NoNewline) {
        $writeHostParams['NoNewline'] = $true
    }

    Write-Host @writeHostParams
    Add-LogEntry -Message $text -NoNewline:$NoNewline
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

$scriptDefs = @(
    [pscustomobject]@{ Name = 'Service Inventory';   File = 'Get-AzServiceInventory.ps1';   Output = 'service-inventory.json';   Category = 'Core';     RequiredRole = 'Reader';                                               Elevated = $false }
    [pscustomobject]@{ Name = 'Region Capabilities'; File = 'Get-AzRegionCapabilities.ps1'; Output = 'region-capabilities.json'; Category = 'Core';     RequiredRole = 'Reader';                                               Elevated = $false }
    [pscustomobject]@{ Name = 'Quota Usage';         File = 'Get-AzQuotaUsage.ps1';         Output = 'quota-usage.json';         Category = 'Core';     RequiredRole = 'Reader';                                               Elevated = $false }
    [pscustomobject]@{ Name = 'Usage Trends';        File = 'Get-AzUsageTrends.ps1';        Output = 'usage-trends.json';        Category = 'Core';     RequiredRole = 'Reader';                                               Elevated = $false }
    [pscustomobject]@{ Name = 'Reserved Instances';  File = 'Get-AzReservedInstances.ps1';  Output = 'reserved-instances.json';  Category = 'Elevated'; RequiredRole = 'Reservations Reader (tenant or billing scope)'; Elevated = $true }
)

function Get-PropertyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-IsPermissionIssue {
    param(
        [string]$Message,
        [AllowNull()]
        [object]$Data,
        [AllowNull()]
        [object]$ScriptDef
    )

    $segments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $segments.Add($Message) | Out-Null
    }

    if ($null -ne $Data) {
        $status = Get-PropertyValue -InputObject $Data -PropertyName 'status'
        $reason = Get-PropertyValue -InputObject $Data -PropertyName 'reason'
        if (-not [string]::IsNullOrWhiteSpace([string]$status)) {
            $segments.Add([string]$status) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) {
            $segments.Add([string]$reason) | Out-Null
        }

        $metadata = Get-PropertyValue -InputObject $Data -PropertyName 'metadata'
        if ($null -ne $metadata) {
            foreach ($propertyName in @('permissionStatus', 'permissionNotes')) {
                $value = Get-PropertyValue -InputObject $metadata -PropertyName $propertyName
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    $segments.Add([string]$value) | Out-Null
                }
            }

            foreach ($errorItem in @(Get-PropertyValue -InputObject $metadata -PropertyName 'errors')) {
                if ($null -ne $errorItem) {
                    $segments.Add([string]$errorItem) | Out-Null
                }
            }

            foreach ($warningItem in @(Get-PropertyValue -InputObject $metadata -PropertyName 'warnings')) {
                if ($null -ne $warningItem) {
                    $segments.Add([string]$warningItem) | Out-Null
                }
            }
        }
    }

    $combined = ($segments -join "`n")
    if ([string]::IsNullOrWhiteSpace($combined)) {
        return $false
    }

    $patterns = @(
        'AuthorizationFailed',
        'does not have authorization',
        'insufficient permissions',
        'Insufficient privileges',
        'status code 403',
        'Forbidden',
        'Microsoft\.Capacity/reservationOrders/read',
        'Reservations Reader',
        'permissionStatus',
        'insufficientPermissions'
    )

    foreach ($pattern in $patterns) {
        if ($combined -match $pattern) {
            return $true
        }
    }

    if ($null -ne $Data -and $null -ne $ScriptDef -and $ScriptDef.Elevated) {
        $status = [string](Get-PropertyValue -InputObject $Data -PropertyName 'status')
        $reason = [string](Get-PropertyValue -InputObject $Data -PropertyName 'reason')
        if ($status -eq 'skipped' -and $reason -match 'permission') {
            return $true
        }
    }

    return $false
}

function Get-PermissionNote {
    param(
        [AllowNull()]
        [object]$Data,
        [string]$DefaultMessage
    )

    if ($null -ne $Data) {
        $reason = Get-PropertyValue -InputObject $Data -PropertyName 'reason'
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) {
            return [string]$reason
        }

        $metadata = Get-PropertyValue -InputObject $Data -PropertyName 'metadata'
        if ($null -ne $metadata) {
            foreach ($propertyName in @('permissionNotes', 'requiredRole')) {
                $value = Get-PropertyValue -InputObject $metadata -PropertyName $propertyName
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    return [string]$value
                }
            }
        }
    }

    return $DefaultMessage
}

function Get-StatusIcon {
    param([string]$Status)

    switch ($Status) {
        'success' { return '✅' }
        'permission-failed' { return '🔒' }
        'failed' { return '❌' }
        'skipped' { return '⏭️' }
        default { return '⚠️' }
    }
}

function Get-ResultCounts {
    param([hashtable]$Results)

    $values = @($Results.Values)
    return [ordered]@{
        Success            = @($values | Where-Object { $_.Status -eq 'success' }).Count
        PermissionFailures = @($values | Where-Object { $_.Status -eq 'permission-failed' }).Count
        ScriptFailures     = @($values | Where-Object { $_.Status -eq 'failed' }).Count
        Skipped            = @($values | Where-Object { $_.Status -eq 'skipped' }).Count
    }
}

function Format-ResultSummary {
    param(
        [int]$Success,
        [int]$PermissionFailures,
        [int]$ScriptFailures,
        [int]$Skipped
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Success -gt 0) {
        $parts.Add("$Success succeeded") | Out-Null
    }
    if ($PermissionFailures -gt 0) {
        $parts.Add("$PermissionFailures permission issue(s)") | Out-Null
    }
    if ($ScriptFailures -gt 0) {
        $parts.Add("$ScriptFailures failed") | Out-Null
    }
    if ($Skipped -gt 0) {
        $parts.Add("$Skipped skipped") | Out-Null
    }

    if ($parts.Count -eq 0) {
        return 'No scripts were executed.'
    }

    return ($parts -join ', ')
}

function Invoke-CapacityCollection {
    param(
        [string]$SubId,
        [string]$SubName,
        [string]$ReportDir
    )

    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

    Write-Log "`nSubscription: $SubName ($SubId)" -ForegroundColor Green
    Write-Log "Report directory: $ReportDir"
    Write-Log "Metrics window: $DaysBack days"
    if ($SkipElevated) {
        Write-Log 'Elevated scripts: skipped by request (-SkipElevated)' -ForegroundColor Yellow
    }
    Write-Log ''

    $results = @{}

    foreach ($s in $scriptDefs) {
        $scriptPath = Join-Path $scriptDir $s.File
        if (-not (Test-Path $scriptPath)) {
            Write-Log "  [SKIP] $($s.Name) - script not found: $($s.File)" -ForegroundColor Yellow
            $results[$s.Name] = @{
                Status          = 'skipped'
                Duration        = $null
                Error           = 'Script not found'
                Errors          = @()
                Warnings        = @()
                Note            = 'Script file is missing.'
                Category        = $s.Category
                RequiredRole    = $s.RequiredRole
                RequiresElevated = $s.Elevated
            }
            continue
        }

        if ($SkipElevated -and $s.Elevated) {
            $note = "Skipped by -SkipElevated. Requires $($s.RequiredRole)."
            Write-Log "  [SKIP] $($s.Name) - $note" -ForegroundColor Yellow
            $results[$s.Name] = @{
                Status           = 'skipped'
                Duration         = 0
                Error            = $null
                Errors           = @()
                Warnings         = @()
                Note             = $note
                Category         = $s.Category
                RequiredRole     = $s.RequiredRole
                RequiresElevated = $s.Elevated
            }
            continue
        }

        Write-Log "Running: $($s.Name)..." -ForegroundColor Cyan -NoNewline
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $splatParams = @{
                SubscriptionId = $SubId
                OutputPath     = $ReportDir
            }
            if ($s.Name -eq 'Usage Trends') {
                $splatParams['DaysBack'] = $DaysBack
            }

            & $scriptPath @splatParams
            $sw.Stop()

            $outputFile = Join-Path $ReportDir $s.Output
            if (-not (Test-Path $outputFile)) {
                $results[$s.Name] = @{
                    Status           = 'failed'
                    Duration         = $sw.Elapsed.TotalSeconds
                    Error            = 'Script completed without producing the expected output file.'
                    Errors           = @('Script completed without producing the expected output file.')
                    Warnings         = @()
                    Note             = 'Script bug or unexpected early exit.'
                    Category         = $s.Category
                    RequiredRole     = $s.RequiredRole
                    RequiresElevated = $s.Elevated
                }
                Write-Log ' FAILED (no output file)' -ForegroundColor Red
                continue
            }

            $data = Get-Content $outputFile -Raw | ConvertFrom-Json -Depth 100
            Register-PiiFromProperties -InputObject $data
            $metadata = Get-PropertyValue -InputObject $data -PropertyName 'metadata'
            $errs = @()
            $warns = @()
            if ($null -ne $metadata) {
                $metadataErrors = Get-PropertyValue -InputObject $metadata -PropertyName 'errors'
                $metadataWarnings = Get-PropertyValue -InputObject $metadata -PropertyName 'warnings'
                if ($null -ne $metadataErrors) { $errs = @($metadataErrors) }
                if ($null -ne $metadataWarnings) { $warns = @($metadataWarnings) }
            }

            $status = 'success'
            $note = $null
            if (Test-IsPermissionIssue -Data $data -ScriptDef $s) {
                $status = 'permission-failed'
                $note = Get-PermissionNote -Data $data -DefaultMessage "Insufficient permissions. Requires $($s.RequiredRole)."
                Write-Log " permission issue ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Yellow
            }
            elseif ([string](Get-PropertyValue -InputObject $data -PropertyName 'status') -eq 'skipped') {
                $status = 'skipped'
                $note = [string](Get-PropertyValue -InputObject $data -PropertyName 'reason')
                if ([string]::IsNullOrWhiteSpace($note)) {
                    $note = 'Script reported a skip condition.'
                }
                Write-Log " skipped ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Yellow
            }
            else {
                Write-Log " done ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
            }

            $results[$s.Name] = @{
                Status           = $status
                Duration         = $sw.Elapsed.TotalSeconds
                Data             = $data
                Error            = $null
                Errors           = $errs
                Warnings         = $warns
                Note             = $note
                Category         = $s.Category
                RequiredRole     = $s.RequiredRole
                RequiresElevated = $s.Elevated
            }
        }
        catch {
            $sw.Stop()
            $message = $_.Exception.Message
            $isPermission = Test-IsPermissionIssue -Message $message -ScriptDef $s
            $status = if ($isPermission) { 'permission-failed' } else { 'failed' }
            $note = if ($isPermission) {
                "Insufficient permissions. Requires $($s.RequiredRole)."
            }
            else {
                $message
            }

            $results[$s.Name] = @{
                Status           = $status
                Duration         = $sw.Elapsed.TotalSeconds
                Error            = $message
                Errors           = @($message)
                Warnings         = @()
                Note             = $note
                Category         = $s.Category
                RequiredRole     = $s.RequiredRole
                RequiresElevated = $s.Elevated
            }

            if ($isPermission) {
                Write-Log " PERMISSION ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Yellow
                Write-Log "    Requires: $($s.RequiredRole)" -ForegroundColor Yellow
            }
            else {
                Write-Log " FAILED ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Red
                Write-Log "    Error: $message" -ForegroundColor Red
            }
        }
    }

    return $results
}

function New-SubscriptionSummary {
    param(
        [string]$SubId,
        [string]$SubName,
        [string]$ReportDir,
        [hashtable]$Results
    )

    $counts = Get-ResultCounts -Results $Results
    $coreScriptNames = @($scriptDefs | Where-Object { -not $_.Elevated } | ForEach-Object { $_.Name })
    $elevatedScriptNames = @($scriptDefs | Where-Object { $_.Elevated } | ForEach-Object { $_.Name })

    $md = [System.Text.StringBuilder]::new()
    [void]$md.AppendLine('# Azure Capacity Planning Report')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Field | Value |')
    [void]$md.AppendLine('|-------|-------|')
    [void]$md.AppendLine("| **Subscription** | $SubName ($SubId) |")
    [void]$md.AppendLine("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
    [void]$md.AppendLine("| **Metrics Window** | $DaysBack days |")
    [void]$md.AppendLine("| **Core Scripts** | $($coreScriptNames -join ', ') |")
    [void]$md.AppendLine("| **Elevated Scripts** | $($elevatedScriptNames -join ', ') |")
    [void]$md.AppendLine("| **Skip Elevated** | $(if ($SkipElevated) { 'Yes' } else { 'No' }) |")
    [void]$md.AppendLine('')

    [void]$md.AppendLine('## Collection Status')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Script | Category | Required Role | Status | Duration | Errors | Warnings | Notes |')
    [void]$md.AppendLine('|--------|----------|---------------|--------|----------|--------|----------|-------|')
    foreach ($s in $scriptDefs) {
        $r = $Results[$s.Name]
        if ($null -eq $r) { continue }
        $duration = if ($r.ContainsKey('Duration') -and $null -ne $r.Duration) { "$([math]::Round([double]$r.Duration, 1))s" } else { '-' }
        $errCount = if ($r.ContainsKey('Errors') -and $r.Errors) { @($r.Errors).Count } else { 0 }
        $warnCount = if ($r.ContainsKey('Warnings') -and $r.Warnings) { @($r.Warnings).Count } else { 0 }
        $statusIcon = Get-StatusIcon -Status $r.Status
        $note = if ($r.ContainsKey('Note') -and -not [string]::IsNullOrWhiteSpace([string]$r.Note)) { [string]$r.Note } else { '' }
        [void]$md.AppendLine("| $($s.Name) | $($s.Category) | $($s.RequiredRole) | $statusIcon $($r.Status) | $duration | $errCount | $warnCount | $note |")
    }
    [void]$md.AppendLine('')

    [void]$md.AppendLine('### Summary')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("- **Successful Scripts**: $($counts.Success)")
    [void]$md.AppendLine("- **Permission Issues**: $($counts.PermissionFailures)")
    [void]$md.AppendLine("- **Script Failures**: $($counts.ScriptFailures)")
    [void]$md.AppendLine("- **Skipped Scripts**: $($counts.Skipped)")
    [void]$md.AppendLine('')

    if ($Results['Service Inventory'].Status -eq 'success') {
        $inv = $Results['Service Inventory'].Data
        [void]$md.AppendLine('## Service Inventory')
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Total Resources**: $($inv.summary.totalResources)")
        [void]$md.AppendLine("- **Resource Types**: $($inv.summary.uniqueResourceTypes)")
        [void]$md.AppendLine("- **Regions**: $($inv.summary.uniqueRegions)")
        [void]$md.AppendLine("- **Resource Groups**: $($inv.summary.uniqueResourceGroups)")
        [void]$md.AppendLine('')
        if ($inv.summary.topResourceTypes) {
            [void]$md.AppendLine('### Top Resource Types')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Type | Count |')
            [void]$md.AppendLine('|------|-------|')
            foreach ($t in $inv.summary.topResourceTypes | Select-Object -First 10) {
                [void]$md.AppendLine("| $($t.type) | $($t.count) |")
            }
            [void]$md.AppendLine('')
        }
        if ($inv.summary.topRegions) {
            [void]$md.AppendLine('### Resources by Region')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Region | Count |')
            [void]$md.AppendLine('|--------|-------|')
            foreach ($regionEntry in $inv.summary.topRegions) {
                [void]$md.AppendLine("| $($regionEntry.region) | $($regionEntry.count) |")
            }
            [void]$md.AppendLine('')
        }
    }

    if ($Results['Quota Usage'].Status -eq 'success') {
        $q = $Results['Quota Usage'].Data
        [void]$md.AppendLine('## Quota Usage')
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Total Quotas Checked**: $($q.summary.totalQuotasChecked)")
        [void]$md.AppendLine("- **Regions Checked**: $($q.summary.regionsChecked)")
        [void]$md.AppendLine("- **Quotas >80% Used**: $($q.summary.quotasAbove80Percent)")
        [void]$md.AppendLine("- **Quotas >90% Used**: $($q.summary.quotasAbove90Percent)")
        [void]$md.AppendLine('')

        $critical = @($q.records | Where-Object { $_.usagePercent -ge 80 })
        if ($critical.Count -gt 0) {
            [void]$md.AppendLine('### ⚠️ Quotas Approaching Limits')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Provider | Region | Quota | Usage | Limit | % Used |')
            [void]$md.AppendLine('|----------|--------|-------|-------|-------|--------|')
            foreach ($c in $critical | Sort-Object -Property usagePercent -Descending) {
                [void]$md.AppendLine("| $($c.provider) | $($c.region) | $($c.quotaName) | $($c.currentUsage) | $($c.limit) | $([math]::Round($c.usagePercent, 1))% |")
            }
            [void]$md.AppendLine('')
        }
    }

    if ($Results['Region Capabilities'].Status -eq 'success') {
        $reg = $Results['Region Capabilities'].Data
        [void]$md.AppendLine('## Region Capabilities')
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Total Regions**: $($reg.summary.totalRegions)")
        [void]$md.AppendLine("- **Regions with Zone Support**: $($reg.summary.regionsWithZoneSupport)")
        [void]$md.AppendLine("- **Total VM SKUs**: $($reg.summary.totalVmSkus)")
        [void]$md.AppendLine('')
    }

    if ($Results['Usage Trends'].Status -eq 'success') {
        $ut = $Results['Usage Trends'].Data
        [void]$md.AppendLine("## Usage Trends ($DaysBack days)")
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Resources Analyzed**: $($ut.summary.totalResourcesAnalyzed)")
        [void]$md.AppendLine("- **Resource Types**: $(($ut.summary.resourceTypesAnalyzed | Measure-Object).Count)")
        [void]$md.AppendLine("- **Period**: $($ut.summary.periodStart) to $($ut.summary.periodEnd)")
        [void]$md.AppendLine('')

        $highUsage = @($ut.records | Where-Object { $_.unit -eq 'Percent' -and $_.p95 -ge 80 })
        if ($highUsage.Count -gt 0) {
            [void]$md.AppendLine('### ⚠️ High Utilization Resources (P95 ≥ 80%)')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Resource | Metric | Avg | P95 | Max |')
            [void]$md.AppendLine('|----------|--------|-----|-----|-----|')
            foreach ($h in $highUsage | Sort-Object -Property p95 -Descending) {
                [void]$md.AppendLine("| $($h.resourceName) | $($h.metricName) | $([math]::Round($h.average, 1))% | $([math]::Round($h.p95, 1))% | $([math]::Round($h.maximum, 1))% |")
            }
            [void]$md.AppendLine('')
        }
    }

    $reservedResult = $Results['Reserved Instances']
    if ($reservedResult.Status -eq 'success') {
        $ri = $reservedResult.Data
        [void]$md.AppendLine('## Reserved Instances')
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Total Reservations**: $($ri.summary.totalReservations)")
        if ($ri.summary.activeReservations) {
            [void]$md.AppendLine("- **Active Reservations**: $($ri.summary.activeReservations)")
        }
        if ($ri.summary.expiringWithin90Days) {
            [void]$md.AppendLine("- **⚠️ Expiring Within 90 Days**: $($ri.summary.expiringWithin90Days)")
        }
        if ($ri.metadata.permissionNotes) {
            [void]$md.AppendLine("- **Permission Status**: $($ri.metadata.permissionNotes)")
        }
        [void]$md.AppendLine('')
    }
    elseif ($null -ne $reservedResult -and ($reservedResult.Status -eq 'permission-failed' -or $reservedResult.Status -eq 'skipped')) {
        [void]$md.AppendLine('## Reserved Instances')
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- **Status**: $(Get-StatusIcon -Status $reservedResult.Status) $($reservedResult.Status)")
        if (-not [string]::IsNullOrWhiteSpace([string]$reservedResult.Note)) {
            [void]$md.AppendLine("- **Note**: $($reservedResult.Note)")
        }
        [void]$md.AppendLine('')
    }

    [void]$md.AppendLine('## Report Files')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| File | Description |')
    [void]$md.AppendLine('|------|-------------|')
    foreach ($s in $scriptDefs) {
        $outputFile = Join-Path $ReportDir $s.Output
        if (Test-Path $outputFile) {
            $size = [math]::Round((Get-Item $outputFile).Length / 1024, 1)
            [void]$md.AppendLine("| ``$($s.Output)`` | $($s.Name) ($size KB) |")
        }
    }
    [void]$md.AppendLine('| ``summary.md`` | This summary report |')
    [void]$md.AppendLine('')

    $summaryPath = Join-Path $ReportDir 'summary.md'
    $md.ToString() | Out-File -FilePath $summaryPath -Encoding utf8

    return $summaryPath
}

# --- Main execution ---

Write-Log "`n========================================" -ForegroundColor Cyan
Write-Log ' Azure Capacity Planning Report' -ForegroundColor Cyan
Write-Log '========================================' -ForegroundColor Cyan
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Build list of subscriptions to process
$subscriptions = @()

if ($PSCmdlet.ParameterSetName -eq 'File') {
    $lines = Get-Content $SubscriptionFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    foreach ($line in $lines) {
        $parts = $line -split '[,\t]', 2
        $id = $parts[0].Trim() -replace '#.*', '' | ForEach-Object { $_.Trim() }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $name = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { ($parts[1].Trim() -replace '#.*', '').Trim() } else { '' }
        $subscriptions += @{ Id = $id; Name = $name }
    }
    if ($subscriptions.Count -eq 0) {
        Add-LogEntry -Message "No valid subscription IDs found in '$SubscriptionFile'."
        Write-Error "No valid subscription IDs found in '$SubscriptionFile'."
        return
    }
    Write-Log "`nLoaded $($subscriptions.Count) subscription(s) from: $SubscriptionFile" -ForegroundColor Green
}
else {
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $accountJson = az account show -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-LogEntry -Message "Not logged in to Azure CLI. Run 'az login' first."
            Write-Error "Not logged in to Azure CLI. Run 'az login' first."
            return
        }
        $account = $accountJson | ConvertFrom-Json
        Register-Pii -Value $account.id -Category 'SubscriptionId' | Out-Null
        Register-Pii -Value $account.name -Category 'SubscriptionName' | Out-Null
        Register-Pii -Value $account.tenantId -Category 'TenantId' | Out-Null
        $subscriptions += @{ Id = $account.id; Name = $account.name }
    }
    else {
        $subscriptions += @{ Id = $SubscriptionId; Name = '' }
    }
}

# Process each subscription
$allSubResults = @()

foreach ($sub in $subscriptions) {
    $subId = $sub.Id
    Register-Pii -Value $subId -Category 'SubscriptionId' | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$sub.Name)) {
        Register-Pii -Value $sub.Name -Category 'SubscriptionName' | Out-Null
    }

    az account set --subscription $subId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "`n❌ Failed to set subscription: $subId" -ForegroundColor Red
        $allSubResults += @{
            Id     = $subId
            Name   = $sub.Name
            Status = 'failed'
            Error  = 'Could not set subscription context'
        }
        continue
    }

    $account = az account show -o json | ConvertFrom-Json
    $subName = $account.name
    Register-Pii -Value $subId -Category 'SubscriptionId' | Out-Null
    Register-Pii -Value $subName -Category 'SubscriptionName' | Out-Null
    Register-Pii -Value $account.tenantId -Category 'TenantId' | Out-Null


    if ($subscriptions.Count -gt 1) {
        $safeName = ($subName -replace '[^\w\-]', '_').ToLower()
        $subReportDir = Join-Path $OutputPath "capacity-report-$timestamp" $safeName
    }
    else {
        $subReportDir = Join-Path $OutputPath "capacity-report-$timestamp"
    }

    Write-Log "`n----------------------------------------" -ForegroundColor DarkGray
    Write-Log " [$($subscriptions.IndexOf($sub) + 1)/$($subscriptions.Count)] $subName" -ForegroundColor Cyan
    Write-Log '----------------------------------------' -ForegroundColor DarkGray

    $results = Invoke-CapacityCollection -SubId $subId -SubName $subName -ReportDir $subReportDir
    $summaryPath = New-SubscriptionSummary -SubId $subId -SubName $subName -ReportDir $subReportDir -Results $results
    $counts = Get-ResultCounts -Results $results

    $allSubResults += @{
        Id                     = $subId
        Name                   = $subName
        Status                 = 'completed'
        ReportDir              = $subReportDir
        SummaryPath            = $summaryPath
        Results                = $results
        SuccessCount           = $counts.Success
        PermissionFailureCount = $counts.PermissionFailures
        ScriptFailureCount     = $counts.ScriptFailures
        SkipCount              = $counts.Skipped
    }

    $summaryText = Format-ResultSummary -Success $counts.Success -PermissionFailures $counts.PermissionFailures -ScriptFailures $counts.ScriptFailures -Skipped $counts.Skipped
    $summaryColor = if ($counts.ScriptFailures -gt 0) { 'Yellow' } elseif ($counts.PermissionFailures -gt 0 -or $counts.Skipped -gt 0) { 'Yellow' } else { 'Green' }
    Write-Log "`nScripts: $summaryText" -ForegroundColor $summaryColor
}

# Cross-subscription summary (when processing multiple subscriptions)
if ($subscriptions.Count -gt 1) {
    $crossMd = [System.Text.StringBuilder]::new()
    [void]$crossMd.AppendLine('# Cross-Subscription Capacity Planning Report')
    [void]$crossMd.AppendLine('')
    [void]$crossMd.AppendLine('| Field | Value |')
    [void]$crossMd.AppendLine('|-------|-------|')
    [void]$crossMd.AppendLine("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
    [void]$crossMd.AppendLine("| **Subscriptions** | $($subscriptions.Count) |")
    [void]$crossMd.AppendLine("| **Metrics Window** | $DaysBack days |")
    [void]$crossMd.AppendLine("| **Skip Elevated** | $(if ($SkipElevated) { 'Yes' } else { 'No' }) |")
    [void]$crossMd.AppendLine('')

    [void]$crossMd.AppendLine('## Subscription Overview')
    [void]$crossMd.AppendLine('')
    [void]$crossMd.AppendLine('| Subscription | Resources | Regions | Quotas >80% | High Util | Reservations | Permission Issues | Script Failures | Status |')
    [void]$crossMd.AppendLine('|-------------|-----------|---------|-------------|-----------|--------------|-------------------|-----------------|--------|')

    $totalResources = 0
    $totalQuotaWarnings = 0
    $totalHighUtil = 0
    $totalReservations = 0
    $allCriticalQuotas = @()
    $allHighUsage = @()

    foreach ($subResult in $allSubResults) {
        if ($subResult.Status -eq 'failed') {
            $failedName = if ([string]::IsNullOrWhiteSpace([string]$subResult.Name)) { $subResult.Id } else { $subResult.Name }
            [void]$crossMd.AppendLine("| $failedName | - | - | - | - | - | 0 | 1 | ❌ Failed |")
            continue
        }

        $r = $subResult.Results
        $resCount = '-'
        $regCount = '-'
        $quotaWarn = '-'
        $highUtil = '-'
        $riCount = '-'

        if ($r['Service Inventory'].Status -eq 'success') {
            $resCount = $r['Service Inventory'].Data.summary.totalResources
            $totalResources += [int]$resCount
        }
        if ($r['Quota Usage'].Status -eq 'success') {
            $quotaWarn = $r['Quota Usage'].Data.summary.quotasAbove80Percent
            $totalQuotaWarnings += [int]$quotaWarn
            $allCriticalQuotas += @($r['Quota Usage'].Data.records | Where-Object { $_.usagePercent -ge 80 } | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'subscription' -NotePropertyValue $subResult.Name -PassThru
            })
            $regCount = $r['Quota Usage'].Data.summary.regionsChecked
        }
        if ($r['Usage Trends'].Status -eq 'success') {
            $hu = @($r['Usage Trends'].Data.records | Where-Object { $_.unit -eq 'Percent' -and $_.p95 -ge 80 })
            $highUtil = $hu.Count
            $totalHighUtil += $hu.Count
            $allHighUsage += @($hu | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'subscription' -NotePropertyValue $subResult.Name -PassThru
            })
        }
        if ($r['Reserved Instances'].Status -eq 'success') {
            $riCount = $r['Reserved Instances'].Data.summary.totalReservations
            $totalReservations += [int]$riCount
        }
        elseif ($r['Reserved Instances'].Status -eq 'permission-failed') {
            $riCount = 'permission required'
        }
        elseif ($r['Reserved Instances'].Status -eq 'skipped') {
            $riCount = 'skipped'
        }

        $statusText = Format-ResultSummary -Success $subResult.SuccessCount -PermissionFailures $subResult.PermissionFailureCount -ScriptFailures $subResult.ScriptFailureCount -Skipped $subResult.SkipCount
        [void]$crossMd.AppendLine("| $($subResult.Name) | $resCount | $regCount | $quotaWarn | $highUtil | $riCount | $($subResult.PermissionFailureCount) | $($subResult.ScriptFailureCount) | $statusText |")
    }

    [void]$crossMd.AppendLine('')
    [void]$crossMd.AppendLine("**Totals**: $totalResources resources, $totalQuotaWarnings quota warnings, $totalHighUtil high-utilization metrics, $totalReservations reservations")
    [void]$crossMd.AppendLine('')

    if ($allCriticalQuotas.Count -gt 0) {
        [void]$crossMd.AppendLine('## ⚠️ Quotas Approaching Limits (All Subscriptions)')
        [void]$crossMd.AppendLine('')
        [void]$crossMd.AppendLine('| Subscription | Provider | Region | Quota | Usage | Limit | % Used |')
        [void]$crossMd.AppendLine('|-------------|----------|--------|-------|-------|-------|--------|')
        foreach ($c in $allCriticalQuotas | Sort-Object -Property usagePercent -Descending | Select-Object -First 25) {
            [void]$crossMd.AppendLine("| $($c.subscription) | $($c.provider) | $($c.region) | $($c.quotaName) | $($c.currentUsage) | $($c.limit) | $([math]::Round($c.usagePercent, 1))% |")
        }
        [void]$crossMd.AppendLine('')
    }

    if ($allHighUsage.Count -gt 0) {
        [void]$crossMd.AppendLine('## ⚠️ High Utilization Resources (All Subscriptions, P95 ≥ 80%)')
        [void]$crossMd.AppendLine('')
        [void]$crossMd.AppendLine('| Subscription | Resource | Metric | Avg | P95 | Max |')
        [void]$crossMd.AppendLine('|-------------|----------|--------|-----|-----|-----|')
        foreach ($h in $allHighUsage | Sort-Object -Property p95 -Descending | Select-Object -First 25) {
            [void]$crossMd.AppendLine("| $($h.subscription) | $($h.resourceName) | $($h.metricName) | $([math]::Round($h.average, 1))% | $([math]::Round($h.p95, 1))% | $([math]::Round($h.maximum, 1))% |")
        }
        [void]$crossMd.AppendLine('')
    }

    [void]$crossMd.AppendLine('## Per-Subscription Reports')
    [void]$crossMd.AppendLine('')
    foreach ($subResult in $allSubResults) {
        if ($subResult.Status -eq 'completed') {
            $relPath = [System.IO.Path]::GetFileName($subResult.ReportDir)
            [void]$crossMd.AppendLine("- **$($subResult.Name)**: [$relPath/summary.md]($relPath/summary.md)")
        }
    }
    [void]$crossMd.AppendLine('')

    $crossSummaryDir = Join-Path $OutputPath "capacity-report-$timestamp"
    New-Item -ItemType Directory -Path $crossSummaryDir -Force | Out-Null
    $crossSummaryPath = Join-Path $crossSummaryDir 'cross-subscription-summary.md'
    $crossMd.ToString() | Out-File -FilePath $crossSummaryPath -Encoding utf8
}

# Final output
Write-Log "`n========================================" -ForegroundColor Cyan
Write-Log ' Report Complete' -ForegroundColor Cyan
Write-Log '========================================' -ForegroundColor Cyan

$rootReportDir = Join-Path $OutputPath "capacity-report-$timestamp"
New-Item -ItemType Directory -Path $rootReportDir -Force | Out-Null
Write-Log "`nReport directory: $rootReportDir" -ForegroundColor Green

if ($subscriptions.Count -gt 1) {
    Write-Log "Cross-subscription summary: $(Join-Path $rootReportDir 'cross-subscription-summary.md')"
    $completedCount = @($allSubResults | Where-Object { $_.Status -eq 'completed' }).Count
    $failedCount = @($allSubResults | Where-Object { $_.Status -eq 'failed' }).Count
    Write-Log "`nSubscriptions: $completedCount completed, $failedCount failed" -ForegroundColor $(if ($failedCount -gt 0) { 'Yellow' } else { 'Green' })
}
else {
    $r = $allSubResults[0]
    Write-Log "Summary: $($r.SummaryPath)"
    Write-Log "`nScripts: $(Format-ResultSummary -Success $r.SuccessCount -PermissionFailures $r.PermissionFailureCount -ScriptFailures $r.ScriptFailureCount -Skipped $r.SkipCount)" -ForegroundColor $(if ($r.ScriptFailureCount -gt 0) { 'Yellow' } elseif ($r.PermissionFailureCount -gt 0 -or $r.SkipCount -gt 0) { 'Yellow' } else { 'Green' })
}

# Generate Excel report
$excelScript = Join-Path $scriptDir 'convert_to_excel.py'
$excelOutput = Join-Path $rootReportDir 'capacity-report.xlsx'

if (Test-Path $excelScript) {
    Write-Log "`nGenerating Excel report..." -ForegroundColor Cyan

    $pythonCmd = $null
    foreach ($candidate in @('python3', 'python', 'py')) {
        try {
            $ver = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $pythonCmd = $candidate
                break
            }
        }
        catch {
        }
    }

    if ($pythonCmd) {
        try {
            $checkImport = & $pythonCmd -c "import openpyxl" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log '  Installing openpyxl...' -ForegroundColor Yellow
                & $pythonCmd -m pip install openpyxl --quiet --break-system-packages 2>$null
                if ($LASTEXITCODE -ne 0) {
                    & $pythonCmd -m pip install openpyxl --quiet 2>$null
                }
            }

            & $pythonCmd $excelScript $rootReportDir $excelOutput
            if ($LASTEXITCODE -eq 0 -and (Test-Path $excelOutput)) {
                $excelSize = [math]::Round((Get-Item $excelOutput).Length / 1024, 1)
                Write-Log "  ✅ Excel report: $excelOutput ($excelSize KB)" -ForegroundColor Green
            }
            else {
                Write-Log '  ⚠️  Excel generation failed' -ForegroundColor Yellow
            }
        }
        catch {
            Write-Log "  ⚠️  Excel generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Log '  ⚠️  Python not found - skipping Excel generation' -ForegroundColor Yellow
        Write-Log '     Install Python and openpyxl, then run manually:' -ForegroundColor Gray
        Write-Log "     python3 $excelScript $rootReportDir" -ForegroundColor Gray
    }
}
else {
    Write-Log "`n⚠️  convert_to_excel.py not found - skipping Excel generation" -ForegroundColor Yellow
}

# Write obfuscated log
$logPath = Join-Path $rootReportDir 'obfuscated-log.txt'
$script:logBuilder.ToString() | Out-File -FilePath $logPath -Encoding utf8
Write-Host "`nObfuscated log: $logPath" -ForegroundColor Green
