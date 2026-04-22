<#
.SYNOPSIS
    Rollback a Power BI report deployment to a previous version.
.DESCRIPTION
    Power BI Service does not provide native version history for reports.
    This script restores a previous .pbix/.rdl artifact (retrieved from the
    build artifact store) by re-publishing it with CreateOrOverwrite.

    Recommended workflow:
    1. Each deployment produces a build artifact retained for 30+ days.
    2. To rollback, identify the prior successful build's artifact ID.
    3. Run this script pointing at that artifact directory.
.PARAMETER Environment
    Target environment.
.PARAMETER RollbackArtifactPath
    Path to the previous-version artifact directory (downloaded from CI/CD).
.PARAMETER ReportName
    Specific report to roll back. If omitted, rolls back ALL reports in artifact.
.EXAMPLE
    ./Rollback-PowerBIReport.ps1 -Environment Prod -RollbackArtifactPath ./previous-build
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'Test', 'Prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$RollbackArtifactPath,

    [string]$ReportName
)

#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$filter = if ($ReportName) { $ReportName } else { '*' }

Write-Host "⚠️  ROLLBACK OPERATION"
Write-Host "  Environment: $Environment"
Write-Host "  Artifact:    $RollbackArtifactPath"
Write-Host "  Filter:      $filter"
Write-Host ""

if (-not $PSCmdlet.ShouldContinue('Proceed with rollback?', 'Confirm rollback')) {
    Write-Host 'Cancelled.'
    return
}

# Rollback is just a redeploy of a prior artifact set
& (Join-Path $ScriptRoot 'Deploy-PowerBIReport.ps1') `
    -Environment $Environment `
    -ArtifactPath $RollbackArtifactPath `
    -ReportFilter $filter

Write-Host "`n✓ Rollback completed. Verify reports in Power BI Service."
