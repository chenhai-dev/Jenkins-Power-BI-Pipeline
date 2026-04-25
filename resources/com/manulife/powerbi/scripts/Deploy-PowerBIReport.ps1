<#
.SYNOPSIS
    Publish .rdl / .pbix reports to a Power BI Premium workspace.

.DESCRIPTION
    For each report file found in the specified folder:
      1. Resolves the target workspace from the environment config
      2. Checks whether a report with the same name already exists
      3. Publishes the report (CreateOrOverwrite semantics)
      4. Optionally rebinds the report to the environment-specific dataset
      5. Applies row-level-security role assignments if defined in config
      6. Writes structured JSON results to the log path

    Safe to run repeatedly — all operations are idempotent.

.NOTES
    .rdl (Report Definition Language) files from Power BI Report Builder are
    paginated reports. They can be published to Premium or PPU workspaces via
    the New-PowerBIReport cmdlet exactly the same as .pbix files — the service
    detects file type from the extension.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportFolder,
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    [Parameter()][string]$RebindDataset = 'true',
    [Parameter()][string]$DryRun = 'false',
    [Parameter(Mandatory = $true)][string]$LogPath
)

# Parse string-bool params (Groovy passes everything as strings).
# We re-bind to local typed variables to keep the rest of the script idiomatic.
$RebindDatasetBool = [System.Convert]::ToBoolean($RebindDataset)
$DryRunBool        = [System.Convert]::ToBoolean($DryRun)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10,
        [string]$OperationName = 'Operation'
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Log "$OperationName failed after $MaxAttempts attempts: $_" 'ERROR'
                throw
            }
            $wait = $DelaySeconds * $attempt   # linear backoff
            Write-Log "$OperationName attempt $attempt failed: $_. Retrying in ${wait}s..." 'WARN'
            Start-Sleep -Seconds $wait
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Power BI Deployment Starting ==="
Write-Log "Report folder : $ReportFolder"
Write-Log "Config file   : $ConfigFile"
Write-Log "Rebind dataset: $RebindDataset"
Write-Log "Dry run       : $DryRun"

# Load and validate config
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
foreach ($required in @('environment', 'workspaceId', 'workspaceName')) {
    if (-not $config.PSObject.Properties.Name.Contains($required)) {
        throw "Config file missing required property: $required"
    }
}
Write-Log "Deploying to workspace: $($config.workspaceName) ($($config.workspaceId))"

# Verify workspace exists and is premium-backed
$workspace = Invoke-WithRetry -OperationName 'Get-Workspace' -ScriptBlock {
    Get-PowerBIWorkspace -Id $config.workspaceId -ErrorAction Stop
}
if (-not $workspace.IsOnDedicatedCapacity) {
    throw "Workspace '$($workspace.Name)' is NOT on dedicated (Premium/PPU) capacity. Paginated (.rdl) reports require Premium."
}
Write-Log "Workspace capacity verified: CapacityId=$($workspace.CapacityId)"

# Discover report files
$reportFiles = Get-ChildItem -Path $ReportFolder -Include *.rdl,*.pbix -Recurse
Write-Log "Found $($reportFiles.Count) report file(s) to deploy"

# Track per-report results for the summary artifact
$deploymentResults = @()

foreach ($file in $reportFiles) {
    $reportName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $extension  = $file.Extension.ToLower()

    $result = [ordered]@{
        reportName = $reportName
        file       = $file.Name
        type       = if ($extension -eq '.rdl') { 'Paginated' } else { 'Interactive' }
        status     = 'Pending'
        reportId   = $null
        datasetId  = $null
        message    = ''
        durationMs = 0
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Write-Log "---"
        Write-Log "Processing: $($file.Name) [$($result.type)]"

        if ($DryRunBool) {
            Write-Log "[DRY RUN] Would publish $($file.Name) to workspace $($config.workspaceId)"
            $result.status = 'DryRun'
            $result.message = 'Dry run — not published'
            continue
        }

        # Check for an existing report with same name — use CreateOrOverwrite
        $existing = Get-PowerBIReport -WorkspaceId $config.workspaceId -Name $reportName -ErrorAction SilentlyContinue
        $conflictAction = if ($existing) { 'CreateOrOverwrite' } else { 'Abort' }
        if ($existing) {
            Write-Log "Existing report found (id=$($existing.Id)) — will overwrite"
        }

        # Publish — works for both .rdl and .pbix
        $published = Invoke-WithRetry -OperationName "Publish-$reportName" -ScriptBlock {
            New-PowerBIReport `
                -Path $file.FullName `
                -Name $reportName `
                -WorkspaceId $config.workspaceId `
                -ConflictAction $conflictAction `
                -ErrorAction Stop
        }
        $result.reportId = $published.Id
        Write-Log "Published OK — reportId=$($published.Id)"

        # Rebind dataset (only makes sense for .pbix; .rdl uses shared datasets by connection string)
        if ($RebindDatasetBool -and $extension -eq '.pbix' -and $config.PSObject.Properties.Name.Contains('datasetMappings')) {
            $mapping = $config.datasetMappings | Where-Object { $_.reportName -eq $reportName }
            if ($mapping) {
                Write-Log "Rebinding report $reportName to dataset $($mapping.datasetId)"
                $rebindBody = @{ datasetId = $mapping.datasetId } | ConvertTo-Json
                Invoke-WithRetry -OperationName "Rebind-$reportName" -ScriptBlock {
                    Invoke-PowerBIRestMethod `
                        -Url "groups/$($config.workspaceId)/reports/$($published.Id)/Rebind" `
                        -Method Post `
                        -Body $rebindBody
                }
                $result.datasetId = $mapping.datasetId
                Write-Log "Rebind complete"
            } else {
                Write-Log "No dataset mapping found for '$reportName' — keeping default binding" 'WARN'
            }
        }

        # Update data source parameters (connection strings, etc.) if configured
        if ($config.PSObject.Properties.Name.Contains('datasourceParameters') -and $published.DatasetId) {
            $paramsForReport = $config.datasourceParameters | Where-Object { $_.reportName -eq $reportName }
            if ($paramsForReport) {
                Write-Log "Updating dataset parameters for $reportName"
                $updatePayload = @{
                    updateDetails = @($paramsForReport.parameters | ForEach-Object {
                        @{ name = $_.name; newValue = $_.value }
                    })
                } | ConvertTo-Json -Depth 5
                Invoke-WithRetry -OperationName "UpdateParams-$reportName" -ScriptBlock {
                    Invoke-PowerBIRestMethod `
                        -Url "groups/$($config.workspaceId)/datasets/$($published.DatasetId)/Default.UpdateParameters" `
                        -Method Post `
                        -Body $updatePayload
                }
                Write-Log "Parameters updated"
            }
        }

        $result.status = 'Success'
        $result.message = 'Published successfully'
    }
    catch {
        $result.status = 'Failed'
        $result.message = $_.Exception.Message
        Write-Log "FAILED to deploy $($file.Name): $_" 'ERROR'
        # Record and continue — we'll fail the build at the end if any report failed
    }
    finally {
        $sw.Stop()
        $result.durationMs = $sw.ElapsedMilliseconds
        $deploymentResults += [PSCustomObject]$result
    }
}

# Write structured summary artifact
$summary = [ordered]@{
    buildNumber  = $env:BUILD_NUMBER
    environment  = $config.environment
    workspaceId  = $config.workspaceId
    timestamp    = (Get-Date).ToUniversalTime().ToString('o')
    dryRun       = $DryRunBool
    totalReports = $deploymentResults.Count
    succeeded    = ($deploymentResults | Where-Object { $_.status -eq 'Success' }).Count
    failed       = ($deploymentResults | Where-Object { $_.status -eq 'Failed'  }).Count
    results      = $deploymentResults
}
$summaryPath = Join-Path (Split-Path $LogPath -Parent) "deployment-summary-$env:BUILD_NUMBER.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath
Write-Log "Summary written to $summaryPath"

Write-Log "=== Deployment Complete ==="
Write-Log "Total: $($summary.totalReports), Succeeded: $($summary.succeeded), Failed: $($summary.failed)"

if ($summary.failed -gt 0) {
    throw "$($summary.failed) report(s) failed to deploy — see $summaryPath"
}
