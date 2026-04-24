#Requires -Version 7
$ErrorActionPreference = 'Stop'

#---------------------------------------------------------------------------
# Input Validation
#---------------------------------------------------------------------------
$requiredVars = @(
    'PBI_TENANT_ID', 'PBI_APP_ID', 'PBI_APP_SECRET',
    'PBI_GROUP_ID', 'PBI_APP', 'PBI_ENV', 'POWERBI_MARKET', 'WORKSPACE'
)
$missing = $requiredVars | Where-Object {
    [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($_))
}
if ($missing) {
    throw "Missing required environment variables: $($missing -join ', ')"
}

#---------------------------------------------------------------------------
# Config
#---------------------------------------------------------------------------
$cfg = @{
    Market        = $env:POWERBI_MARKET
    App           = $env:PBI_APP
    Env           = $env:PBI_ENV
    GroupId       = $env:PBI_GROUP_ID
    FindString    = $env:PBI_FIND_STRING
    ReplaceString = $env:PBI_REPLACE_STRING
    AllowReplace  = ($env:PBI_ALLOW_REPLACE -eq 'true')
    DryRun        = ($env:PBI_DRY_RUN       -eq 'true')
}

#---------------------------------------------------------------------------
# Token cache (script-scope)
#---------------------------------------------------------------------------
$script:AuthHeaders = $null
$script:TokenExpiry = [DateTime]::MinValue

#---------------------------------------------------------------------------
# Helpers
#---------------------------------------------------------------------------
function Write-Section([string]$title) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ""
    Write-Host "[$ts] ========== $title =========="
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$Context      = 'REST',
        [int]$MaxAttempts     = 3,
        [int]$BaseDelaySec    = 5
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Action)
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}

            # Permanent client errors — do not retry
            if ($code -and $code -ge 400 -and $code -lt 500 -and $code -ne 429) { throw }

            if ($attempt -ge $MaxAttempts) {
                Write-Host "ERROR: [$Context] All $MaxAttempts attempts exhausted."
                throw
            }

            $delaySec = if ($code -eq 429) {
                # Respect rate-limit: minimum 30 s back-off
                [Math]::Max([Math]::Pow(2, $attempt) * $BaseDelaySec, 30)
            } else {
                [Math]::Pow(2, $attempt - 1) * $BaseDelaySec
            }

            $label = if ($code) { " (HTTP $code)" } else { '' }
            Write-Host "WARNING: [$Context] Attempt $attempt failed${label}. Retrying in ${delaySec}s..."
            Start-Sleep -Seconds $delaySec
        }
    }
}

function Get-AccessToken {
    # Return cached token if still valid (refresh 5 min before expiry)
    if ($null -ne $script:AuthHeaders -and [DateTime]::UtcNow -lt $script:TokenExpiry) {
        return $script:AuthHeaders
    }

    Write-Host "Acquiring Azure AD token..."
    $body = @{
        client_id     = $env:PBI_APP_ID
        client_secret = $env:PBI_APP_SECRET
        scope         = 'https://analysis.windows.net/powerbi/api/.default'
        grant_type    = 'client_credentials'
    }

    $token = Invoke-WithRetry -Context 'AcquireToken' -Action {
        Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$env:PBI_TENANT_ID/oauth2/v2.0/token" `
            -Body $body -ContentType 'application/x-www-form-urlencoded'
    }

    if ([string]::IsNullOrWhiteSpace($token.access_token)) {
        throw 'Azure AD returned an empty access token.'
    }

    $expiresIn          = if ($token.expires_in) { [int]$token.expires_in } else { 3600 }
    $script:TokenExpiry = [DateTime]::UtcNow.AddSeconds($expiresIn - 300)
    $script:AuthHeaders = @{ Authorization = "Bearer $($token.access_token)" }

    Write-Host "Token acquired. Refreshes at: $($script:TokenExpiry.ToLocalTime().ToString('HH:mm:ss')) local."
    return $script:AuthHeaders
}

function Get-WorkspaceReports([string]$groupId, [hashtable]$headers) {
    $res = Invoke-WithRetry -Context 'GetReports' -Action {
        Invoke-RestMethod -Method Get `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$groupId/reports" `
            -Headers $headers
    }
    if ($null -eq $res -or $null -eq $res.value) { return @() }
    return @($res.value)
}

function Find-ExistingReport([object[]]$reports, [string]$fileName) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    return $reports |
        Where-Object { $_.name -eq $baseName -or $_.name -eq $fileName } |
        Select-Object -First 1
}

function Get-ImportUrl([string]$groupId, [string]$fileName, [string]$mode) {
    $name = [System.Uri]::EscapeDataString(
        [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    )
    return "https://api.powerbi.com/v1.0/myorg/groups/$groupId/imports?datasetDisplayName=$name&nameConflict=$mode"
}

function Write-RestError([string]$context, $err) {
    Write-Host "ERROR CONTEXT : $context"
    if ($err.Exception.Message)       { Write-Host "Exception     : $($err.Exception.Message)" }
    if ($err.ErrorDetails.Message)    { Write-Host "ErrorDetails  : $($err.ErrorDetails.Message)" }
    try {
        $code = [int]$err.Exception.Response.StatusCode
        Write-Host "HTTP Status   : $code"
    } catch {}
    try {
        $body = $err.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($body) { Write-Host "Response Body : $body" }
    } catch {}
    try {
        if ($err.ScriptStackTrace) { Write-Host "Stack Trace   :`n$($err.ScriptStackTrace)" }
    } catch {}
}

function Wait-ImportDone([string]$groupId, [string]$importId, [hashtable]$headers) {
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$groupId/imports/$importId"
    for ($poll = 1; $poll -le 60; $poll++) {
        $res = Invoke-WithRetry -Context "Poll[$importId]" -MaxAttempts 2 -BaseDelaySec 3 -Action {
            Invoke-RestMethod -Method Get -Uri $url -Headers (Get-AccessToken)
        }
        Write-Host "Poll $poll | State: $($res.importState)"
        if ($res.importState -eq 'Succeeded') { return $res }
        if ($res.importState -eq 'Failed') {
            $code = if ($res.error -and $res.error.code) { $res.error.code } else { 'Unknown' }
            throw "Import FAILED. ID: $importId | ErrorCode: $code"
        }
        Start-Sleep -Seconds 5
    }
    throw "Import timed out after 5 minutes. ID: $importId"
}

function Import-RdlFile([string]$groupId, [string]$fileName, [string]$fullPath, [string]$mode, [hashtable]$headers) {
    $importUrl = Get-ImportUrl -groupId $groupId -fileName $fileName -mode $mode
    Write-Host "Import Mode : $mode"
    Write-Host "Import URL  : $importUrl"
    Write-Host "Local File  : $fullPath"

    $res = Invoke-WithRetry -Context "ImportRdl[$fileName]" -Action {
        Invoke-RestMethod -Method Post -Uri $importUrl -Headers $headers `
                          -Form @{ value = Get-Item -LiteralPath $fullPath }
    }

    if (-not $res.id) { throw "Import API returned no Import ID for: $fileName" }
    return [string]$res.id
}

function Apply-OdbcConnectionReplace([string]$fullPath, [string]$findString, [string]$replaceString) {
    if ([string]::IsNullOrWhiteSpace($findString)) {
        Write-Host "Find_String is empty — ODBC replacement skipped."
        return $false
    }
    $content = Get-Content -LiteralPath $fullPath -Raw
    $updated = $content.Replace($findString, $replaceString)
    if ($updated -ne $content) {
        Set-Content -LiteralPath $fullPath -Value $updated -Encoding utf8
        Write-Host "ODBC string replaced in: $(Split-Path $fullPath -Leaf)"
        return $true
    }
    Write-Host "Find string not found in RDL — no change: $(Split-Path $fullPath -Leaf)"
    return $false
}

function Get-ReportDatasources([string]$groupId, [string]$reportId, [hashtable]$headers) {
    $res = Invoke-WithRetry -Context "GetDatasources[$reportId]" -Action {
        Invoke-RestMethod -Method Get `
            -Uri "https://api.powerbi.com/v1.0/myorg/groups/$groupId/reports/$reportId/datasources" `
            -Headers $headers
    }
    if ($null -eq $res -or $null -eq $res.value) { return @() }
    return @($res.value)
}

function Update-ReportDatasources([string]$groupId, [string]$reportId, [string]$replaceString, [hashtable]$headers) {
    $datasources = Get-ReportDatasources -groupId $groupId -reportId $reportId -headers $headers

    if (-not $datasources -or $datasources.Count -eq 0) {
        Write-Host "WARNING: No datasources found for report $reportId — binding skipped."
        return
    }

    Write-Host "Binding $($datasources.Count) datasource(s) → $replaceString"

    $updateDetails = @(foreach ($ds in $datasources) {
        Write-Host "  DS: $($ds.name) | Type: $($ds.datasourceType) | Was: $($ds.connectionDetails.connectionString)"
        @{
            datasourceName     = $ds.name
            connectionDetails  = @{ connectionString = $replaceString }
            datasourceSelector = @{
                datasourceType    = $ds.datasourceType
                connectionDetails = @{ connectionString = $ds.connectionDetails.connectionString }
            }
        }
    })

    $body = @{ updateDetails = $updateDetails } | ConvertTo-Json -Depth 10
    $url  = "https://api.powerbi.com/v1.0/myorg/groups/$groupId/reports/$reportId/Default.UpdateDatasources"

    Invoke-WithRetry -Context "UpdateDatasources[$reportId]" -Action {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers `
                          -Body $body -ContentType 'application/json'
    }
    Write-Host "Datasource binding OK for report: $reportId"
}

#---------------------------------------------------------------------------
# Resolve RDL path
#---------------------------------------------------------------------------
Write-Section 'Runtime Info'
$PSVersionTable | Out-String | Write-Host

$basePath = Join-Path $env:WORKSPACE "$($cfg.Market)-$($cfg.App)"
$rdlPath  = Join-Path $basePath $cfg.Env

Write-Host "Market       : $($cfg.Market)"
Write-Host "App          : $($cfg.App)"
Write-Host "Environment  : $($cfg.Env)"
Write-Host "Workspace ID : $($cfg.GroupId)"
Write-Host "Workspace    : $env:WORKSPACE"
Write-Host "RDL Path     : $rdlPath"
Write-Host "Dry Run      : $($cfg.DryRun)"
Write-Host "Allow Replace: $($cfg.AllowReplace)"

if (-not (Test-Path -LiteralPath $rdlPath)) {
    throw "RDL directory not found: $rdlPath"
}

$rdlFiles = Get-ChildItem -LiteralPath $rdlPath -Filter '*.rdl' -File | Sort-Object Name
if (-not $rdlFiles -or $rdlFiles.Count -eq 0) {
    throw "No .rdl files found in: $rdlPath"
}

#---------------------------------------------------------------------------
# Authenticate
#---------------------------------------------------------------------------
Write-Section 'Authentication'
$headers = Get-AccessToken

#---------------------------------------------------------------------------
# List files vs current workspace state
#---------------------------------------------------------------------------
$workspaceReports = Get-WorkspaceReports -groupId $cfg.GroupId -headers $headers

Write-Section "RDL Files ($($rdlFiles.Count) found)"
$rdlFiles | ForEach-Object {
    $ex = Find-ExistingReport -reports $workspaceReports -fileName $_.Name
    [PSCustomObject]@{
        File          = $_.Name
        'Size(KB)'    = [Math]::Round($_.Length / 1KB, 1)
        LastModified  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        WorkspaceId   = if ($ex) { $ex.id } else { '(new)' }
    }
} | Format-Table -AutoSize | Out-String | Write-Host

#---------------------------------------------------------------------------
# Deploy — process all files, collect failures, do not fail-fast
#---------------------------------------------------------------------------
Write-Section 'Deployment Start'
$deploymentResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$fileErrors        = [System.Collections.Generic.List[string]]::new()

foreach ($file in $rdlFiles) {
    $fileName         = $file.Name
    $reportLookupName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $fullPath         = $file.FullName

    Write-Host ""
    Write-Host "--- Processing: $fileName ---"

    $result = [PSCustomObject]@{
        FileName         = $fileName
        BeforeReportName = ''
        BeforeReportId   = ''
        AfterReportName  = ''
        AfterReportId    = ''
        IdCompareStatus  = ''
        Status           = 'PENDING'
        Error            = ''
    }

    try {
        $headers  = Get-AccessToken   # auto-refresh if near expiry
        $existing = Find-ExistingReport -reports (Get-WorkspaceReports -groupId $cfg.GroupId -headers $headers) `
                                        -fileName $fileName

        $result.BeforeReportId   = if ($existing) { [string]$existing.id }   else { '' }
        $result.BeforeReportName = if ($existing) { [string]$existing.name } else { '' }

        if ($existing) {
            Write-Host "Existing report: $($existing.name) [$($existing.id)]"

            if (-not $cfg.AllowReplace) {
                throw "Report already exists in workspace. Set ALLOW_REPLACE_EXISTING_RDL=true to overwrite."
            }

            Write-Host "ALLOW_REPLACE=true — overwrite mode."
            Apply-OdbcConnectionReplace -fullPath $fullPath -findString $cfg.FindString -replaceString $cfg.ReplaceString

            if ($cfg.DryRun) {
                Write-Host "DRY RUN: Would overwrite-import $fileName"
                $result.AfterReportId   = $existing.id
                $result.AfterReportName = $existing.name
                $result.IdCompareStatus = 'DRY_RUN'
            } else {
                $importId  = Import-RdlFile -groupId $cfg.GroupId -fileName $fileName `
                                            -fullPath $fullPath -mode 'Overwrite' -headers $headers
                $importRes = Wait-ImportDone -groupId $cfg.GroupId -importId $importId -headers $headers
                $report    = $importRes.reports | Select-Object -First 1

                $result.AfterReportId   = [string]$report.id
                $result.AfterReportName = [string]$report.name

                $headers = Get-AccessToken
                Update-ReportDatasources -groupId $cfg.GroupId -reportId $result.AfterReportId `
                                         -replaceString $cfg.ReplaceString -headers $headers
            }
        } else {
            Write-Host "New report — first-time import."
            Apply-OdbcConnectionReplace -fullPath $fullPath -findString $cfg.FindString -replaceString $cfg.ReplaceString

            if ($cfg.DryRun) {
                Write-Host "DRY RUN: Would new-import $fileName"
                $result.AfterReportId   = "dry-run-$(New-Guid)"
                $result.AfterReportName = $reportLookupName
                $result.IdCompareStatus = 'DRY_RUN'
            } else {
                $importId  = Import-RdlFile -groupId $cfg.GroupId -fileName $fileName `
                                            -fullPath $fullPath -mode 'Abort' -headers $headers
                $importRes = Wait-ImportDone -groupId $cfg.GroupId -importId $importId -headers $headers
                $newReport = $importRes.reports | Select-Object -First 1

                $result.AfterReportId   = [string]$newReport.id
                $result.AfterReportName = [string]$newReport.name

                $headers = Get-AccessToken
                Update-ReportDatasources -groupId $cfg.GroupId -reportId $result.AfterReportId `
                                         -replaceString $cfg.ReplaceString -headers $headers
            }
        }

        if ($result.IdCompareStatus -ne 'DRY_RUN') {
            $result.IdCompareStatus =
                if (-not $existing)                                               { 'NEW_REPORT_CREATED' }
                elseif ($result.BeforeReportId -eq $result.AfterReportId)        { 'UNCHANGED' }
                else                                                               { 'ID_CHANGED' }
        }

        $result.Status = 'SUCCESS'
        Write-Host "OK: $fileName → [$($result.IdCompareStatus)] ID=$($result.AfterReportId)"

    } catch {
        $msg = $_.ToString()
        Write-Host "FAILED: $fileName"
        Write-Host "Reason: $msg"
        Write-RestError "Deploy [$fileName]" $_
        $result.Status = 'FAILED'
        $result.Error  = $msg
        $fileErrors.Add("$fileName : $msg")
    }

    $deploymentResults.Add($result)
}

#---------------------------------------------------------------------------
# Summary table
#---------------------------------------------------------------------------
Write-Section 'Deployment Summary'
$deploymentResults |
    Format-Table FileName, BeforeReportId, AfterReportId, IdCompareStatus, Status -AutoSize |
    Out-String | Write-Host

if ($fileErrors.Count -gt 0) {
    Write-Host "FAILURES ($($fileErrors.Count) of $($deploymentResults.Count)):"
    $fileErrors | ForEach-Object { Write-Host "  - $_" }
}

#---------------------------------------------------------------------------
# Export artifacts
#---------------------------------------------------------------------------
$cols     = 'FileName','BeforeReportName','BeforeReportId','AfterReportName','AfterReportId','IdCompareStatus','Status','Error'
$csvPath  = Join-Path $env:WORKSPACE 'report-id-comparison-summary.csv'
$jsonPath = Join-Path $env:WORKSPACE 'report-id-comparison-summary.json'

$deploymentResults | Select-Object $cols | Export-Csv  -LiteralPath $csvPath  -NoTypeInformation -Encoding UTF8
$deploymentResults | Select-Object $cols | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Write-Host "CSV  : $csvPath"
Write-Host "JSON : $jsonPath"

Write-Section 'Done'
$successCount = ($deploymentResults | Where-Object Status -eq 'SUCCESS').Count
$failedCount  = ($deploymentResults | Where-Object Status -eq 'FAILED').Count
Write-Host "Total: $($deploymentResults.Count) | Success: $successCount | Failed: $failedCount"

if ($failedCount -gt 0) {
    exit 1
}
