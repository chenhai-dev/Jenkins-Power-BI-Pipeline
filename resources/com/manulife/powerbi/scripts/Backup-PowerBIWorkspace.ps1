<#
.SYNOPSIS
    Exports all reports in a workspace for rollback purposes.

.DESCRIPTION
    Before a production deployment, downloads a .pbix copy of every report
    currently in the target workspace. This provides a rollback point.

    Notes:
      - Paginated reports (.rdl) cannot be exported via the REST API as .rdl,
        only as rendered output. For RDL rollback, rely on source control (git).
      - Export-PowerBIReport requires the workspace to be on Premium/PPU capacity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [Parameter(Mandatory = $true)][string]$OutputFolder,
    [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$ts] [$Level] [BACKUP] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
Write-Log "Backing up workspace $WorkspaceId to $OutputFolder"

$reports = Get-PowerBIReport -WorkspaceId $WorkspaceId
Write-Log "Found $($reports.Count) report(s) in workspace"

$manifest = @()
foreach ($report in $reports) {
    $safeName = $report.Name -replace '[\\\/:*?"<>|]', '_'
    $outPath  = Join-Path $OutputFolder "$safeName.pbix"

    try {
        Write-Log "Exporting: $($report.Name)"
        Export-PowerBIReport -Id $report.Id -WorkspaceId $WorkspaceId -OutFile $outPath
        $manifest += [PSCustomObject]@{
            reportId   = $report.Id
            name       = $report.Name
            datasetId  = $report.DatasetId
            backupFile = $outPath
            exportedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    } catch {
        Write-Log "Export failed for '$($report.Name)' — $($_.Exception.Message). Some reports (e.g., paginated RDL) cannot be exported via API." 'WARN'
    }
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputFolder 'backup-manifest.json')
Write-Log "Backup complete: $($manifest.Count) report(s) exported"
