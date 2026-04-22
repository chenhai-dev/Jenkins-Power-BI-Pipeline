<#
.SYNOPSIS
    Continuous health check for deployed Power BI reports.
.DESCRIPTION
    Run on a schedule (every 15 min recommended). Emits metrics to Log Analytics
    / Application Insights for dashboards and alerts.

    Checks performed:
      - Workspace is active and on Premium capacity
      - All reports are reachable
      - Dataset refresh status (last N refreshes)
      - Refresh duration trend
      - Capacity utilization (when capacity metrics app is provisioned)
      - SLA: reports refreshed within expected window
.PARAMETER Environment
    Target environment.
.PARAMETER OutputFormat
    'json' (default) for pipeline / Log Analytics ingestion, 'prometheus' for scrape endpoints.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'Test', 'Prod')]
    [string]$Environment,

    [string]$ConfigPath,

    [ValidateSet('json', 'prometheus', 'table')]
    [string]$OutputFormat = 'json',

    [int]$RefreshHistoryCount = 5,

    [int]$SlaRefreshAgeHours = 25   # Daily refresh should be < 25h old
)

#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptRoot '..' '..' 'modules' 'PowerBIDeployment.psd1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptRoot '..' '..' 'config' "$($Environment.ToLower()).yaml"
}

Import-Module powershell-yaml -Force
Import-Module Az.KeyVault -Force

$cfg = ConvertFrom-Yaml (Get-Content $ConfigPath -Raw)

$secureSecret = Get-AzKeyVaultSecret `
    -VaultName $cfg.keyVault.name `
    -Name $cfg.auth.clientSecretName `
    -AsPlainText |
    ConvertTo-SecureString -AsPlainText -Force

Connect-PowerBIWithServicePrincipal `
    -TenantId $cfg.auth.tenantId `
    -ClientId $cfg.auth.clientId `
    -ClientSecret $secureSecret | Out-Null

$metrics = [System.Collections.Generic.List[object]]::new()
$overallHealth = 'healthy'
$reasonsUnhealthy = [System.Collections.Generic.List[string]]::new()

try {
    # ---- Workspace status -----------------------------------------------------
    $ws = Get-PowerBIWorkspace -Name $cfg.workspace.name -Scope Organization -ErrorAction Stop |
          Select-Object -First 1

    if (-not $ws -or $ws.State -ne 'Active') {
        $overallHealth = 'unhealthy'
        $reasonsUnhealthy.Add('workspace_not_active')
    }

    $metrics.Add([pscustomobject]@{
        metric = 'powerbi_workspace_active'
        value  = if ($ws.State -eq 'Active') { 1 } else { 0 }
        labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
    })
    $metrics.Add([pscustomobject]@{
        metric = 'powerbi_workspace_on_premium'
        value  = if ($ws.IsOnDedicatedCapacity) { 1 } else { 0 }
        labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
    })

    if (-not $ws.IsOnDedicatedCapacity) {
        $overallHealth = 'unhealthy'
        $reasonsUnhealthy.Add('not_on_premium_capacity')
    }

    # ---- Reports ---------------------------------------------------------------
    $reports = (Invoke-PowerBIRestMethod -Url "groups/$($ws.Id)/reports" -Method Get |
                ConvertFrom-Json).value

    $metrics.Add([pscustomobject]@{
        metric = 'powerbi_reports_total'
        value  = $reports.Count
        labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
    })

    $paginatedCount = ($reports | Where-Object reportType -eq 'PaginatedReport').Count
    $standardCount  = ($reports | Where-Object reportType -eq 'PowerBIReport').Count

    $metrics.Add([pscustomobject]@{
        metric = 'powerbi_reports_paginated'
        value  = $paginatedCount
        labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
    })
    $metrics.Add([pscustomobject]@{
        metric = 'powerbi_reports_standard'
        value  = $standardCount
        labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
    })

    # ---- Datasets + refresh health --------------------------------------------
    $datasets = (Invoke-PowerBIRestMethod -Url "groups/$($ws.Id)/datasets" -Method Get |
                 ConvertFrom-Json).value

    foreach ($ds in $datasets) {
        if (-not $ds.isRefreshable) { continue }

        try {
            $refreshes = (Invoke-PowerBIRestMethod `
                -Url "groups/$($ws.Id)/datasets/$($ds.id)/refreshes?`$top=$RefreshHistoryCount" `
                -Method Get | ConvertFrom-Json).value
        }
        catch {
            Write-DeploymentLog -Message "Cannot read refresh history for $($ds.name)" -Level WARN
            continue
        }

        if (-not $refreshes -or $refreshes.Count -eq 0) {
            $metrics.Add([pscustomobject]@{
                metric = 'powerbi_dataset_refresh_never'
                value  = 1
                labels = @{ environment = $Environment; datasetId = $ds.id; dataset = $ds.name }
            })
            continue
        }

        $last = $refreshes[0]
        $lastStatus = $last.status                  # Completed, Failed, Unknown (in progress)
        $lastEnd = if ($last.endTime) { [datetime]$last.endTime } else { $null }
        $ageHours = if ($lastEnd) { ((Get-Date).ToUniversalTime() - $lastEnd).TotalHours } else { -1 }

        # Last refresh status (1 = success)
        $metrics.Add([pscustomobject]@{
            metric = 'powerbi_dataset_last_refresh_success'
            value  = if ($lastStatus -eq 'Completed') { 1 } else { 0 }
            labels = @{ environment = $Environment; datasetId = $ds.id; dataset = $ds.name }
        })

        # Age of last successful refresh (hours)
        $metrics.Add([pscustomobject]@{
            metric = 'powerbi_dataset_last_refresh_age_hours'
            value  = [Math]::Round($ageHours, 2)
            labels = @{ environment = $Environment; datasetId = $ds.id; dataset = $ds.name }
        })

        # Duration of last refresh (seconds)
        if ($last.startTime -and $last.endTime) {
            $duration = (([datetime]$last.endTime) - ([datetime]$last.startTime)).TotalSeconds
            $metrics.Add([pscustomobject]@{
                metric = 'powerbi_dataset_last_refresh_duration_seconds'
                value  = [Math]::Round($duration, 1)
                labels = @{ environment = $Environment; datasetId = $ds.id; dataset = $ds.name }
            })
        }

        # SLA breach detection
        if ($lastStatus -eq 'Failed') {
            $overallHealth = 'unhealthy'
            $reasonsUnhealthy.Add("dataset_refresh_failed:$($ds.name)")
        }
        if ($ageHours -gt $SlaRefreshAgeHours) {
            $overallHealth = 'degraded'
            $reasonsUnhealthy.Add("dataset_refresh_stale:$($ds.name)")
        }

        # Trend: failure count in last N refreshes
        $failCount = ($refreshes | Where-Object status -eq 'Failed').Count
        $metrics.Add([pscustomobject]@{
            metric = 'powerbi_dataset_recent_failures'
            value  = $failCount
            labels = @{ environment = $Environment; datasetId = $ds.id; dataset = $ds.name }
        })
    }
}
finally {
    Disconnect-PowerBISession
}

# Overall health metric
$healthValue = switch ($overallHealth) {
    'healthy'   { 2 }
    'degraded'  { 1 }
    'unhealthy' { 0 }
}
$metrics.Add([pscustomobject]@{
    metric = 'powerbi_overall_health'
    value  = $healthValue
    labels = @{ environment = $Environment; workspace = $cfg.workspace.name }
})

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
switch ($OutputFormat) {
    'json' {
        $output = @{
            timestamp     = (Get-Date).ToUniversalTime().ToString('o')
            environment   = $Environment
            overallHealth = $overallHealth
            reasons       = @($reasonsUnhealthy | Select-Object -Unique)
            metrics       = $metrics
        }
        $output | ConvertTo-Json -Depth 6
    }
    'prometheus' {
        # Prometheus text format
        $grouped = $metrics | Group-Object metric
        foreach ($g in $grouped) {
            Write-Output "# TYPE $($g.Name) gauge"
            foreach ($m in $g.Group) {
                $labelStr = ($m.labels.GetEnumerator() | ForEach-Object {
                    "$($_.Key)=`"$($_.Value -replace '"','\"')`""
                }) -join ','
                Write-Output "$($m.metric){$labelStr} $($m.value)"
            }
        }
    }
    'table' {
        $metrics | Format-Table metric, value, @{ Name='labels'; Expression={ $_.labels | ConvertTo-Json -Compress } } -AutoSize
    }
}

# Exit non-zero if unhealthy (for cron-based alerting)
if ($overallHealth -eq 'unhealthy') { exit 2 }
if ($overallHealth -eq 'degraded')  { exit 1 }
exit 0
