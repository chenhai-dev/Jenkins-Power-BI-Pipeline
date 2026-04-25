<#
.SYNOPSIS
    Triggers refreshes on datasets declared in the environment config.

.DESCRIPTION
    For each dataset listed in the config's "datasetsToRefresh" array:
      1. Queues a refresh via the Power BI REST API
      2. Optionally polls for completion with a timeout
      3. Surfaces refresh errors as the exit reason

    Premium workspaces support up to 48 refreshes per day per dataset
    (Pro workspaces are limited to 8 — hence this pipeline targets Premium).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter()][string]$WaitForCompletion = 'true',
    [Parameter()][int]$TimeoutMinutes = 30,
    [Parameter()][int]$PollIntervalSeconds = 20
)

$WaitForCompletionBool = [System.Convert]::ToBoolean($WaitForCompletion)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$ts] [$Level] [REFRESH] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

if (-not $config.PSObject.Properties.Name.Contains('datasetsToRefresh') -or $config.datasetsToRefresh.Count -eq 0) {
    Write-Log "No datasets configured for refresh — skipping"
    return
}

$workspaceId = $config.workspaceId
$results = @()

foreach ($dsId in $config.datasetsToRefresh) {
    Write-Log "Queuing refresh for dataset $dsId"
    try {
        # Trigger — empty body uses defaults; notifyOption controls email behaviour
        $body = @{ notifyOption = 'MailOnFailure' } | ConvertTo-Json
        Invoke-PowerBIRestMethod `
            -Url "groups/$workspaceId/datasets/$dsId/refreshes" `
            -Method Post `
            -Body $body | Out-Null
        Write-Log "Refresh queued OK for $dsId"
    } catch {
        Write-Log "Failed to queue refresh for $dsId : $_" 'ERROR'
        $results += [PSCustomObject]@{ datasetId = $dsId; status = 'QueueFailed'; error = "$_" }
        continue
    }

    if (-not $WaitForCompletionBool) {
        $results += [PSCustomObject]@{ datasetId = $dsId; status = 'Queued' }
        continue
    }

    # Poll for completion
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $finalStatus = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $history = Invoke-PowerBIRestMethod `
                -Url "groups/$workspaceId/datasets/$dsId/refreshes?`$top=1" `
                -Method Get | ConvertFrom-Json

            $latest = $history.value | Select-Object -First 1
            if (-not $latest) { continue }

            Write-Log "Dataset $dsId status: $($latest.status)"

            if ($latest.status -eq 'Completed') {
                $finalStatus = 'Completed'
                break
            } elseif ($latest.status -eq 'Failed') {
                $finalStatus = 'Failed'
                Write-Log "Refresh FAILED for $dsId : $($latest.serviceExceptionJson)" 'ERROR'
                break
            }
            # 'Unknown' = still running; keep polling
        } catch {
            Write-Log "Error polling refresh history: $_" 'WARN'
        }
    }

    if (-not $finalStatus) {
        $finalStatus = 'TimedOut'
        Write-Log "Refresh did not complete within ${TimeoutMinutes} minutes" 'ERROR'
    }

    $results += [PSCustomObject]@{ datasetId = $dsId; status = $finalStatus }
}

# Summarise
$failed = @($results | Where-Object { $_.status -in @('Failed', 'QueueFailed', 'TimedOut') })
Write-Log "Refresh summary: $($results.Count) total, $($failed.Count) failed"

if ($failed.Count -gt 0) {
    throw "$($failed.Count) dataset refresh(es) failed or timed out"
}
