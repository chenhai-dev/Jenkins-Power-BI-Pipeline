<#
.SYNOPSIS
    Post-deployment smoke test to verify reports are accessible.

.DESCRIPTION
    After deployment, confirms that every report in the source folder can be
    found in the target workspace and reports basic metadata (last modified
    timestamp, dataset binding). Fails the build if any report is missing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    [Parameter(Mandatory = $true)][string]$ReportFolder,
    [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$ts] [$Level] [VERIFY] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$workspaceId = $config.workspaceId

$localReports = Get-ChildItem -Path $ReportFolder -Include *.rdl,*.pbix -Recurse |
                ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }

$remoteReports = Get-PowerBIReport -WorkspaceId $workspaceId
$remoteNames = $remoteReports | Select-Object -ExpandProperty Name

$missing = @()
foreach ($expected in $localReports) {
    if ($remoteNames -notcontains $expected) {
        $missing += $expected
        Write-Log "MISSING in workspace: $expected" 'ERROR'
    } else {
        $match = $remoteReports | Where-Object { $_.Name -eq $expected } | Select-Object -First 1
        Write-Log "Found: $expected (id=$($match.Id), dataset=$($match.DatasetId))"
    }
}

if ($missing.Count -gt 0) {
    throw "$($missing.Count) expected report(s) missing after deployment: $($missing -join ', ')"
}

Write-Log "Post-deployment verification passed — all $($localReports.Count) report(s) present"
