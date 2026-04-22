#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pre-commit hook: run PSScriptAnalyzer against staged PS files.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'Installing PSScriptAnalyzer...'
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
}
Import-Module PSScriptAnalyzer

$issues = Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error, Warning `
    -ExcludeRule @(
        # Opt-outs with reasons:
        'PSAvoidUsingWriteHost'          # Used intentionally for pipeline stdout
        'PSUseShouldProcessForStateChangingFunctions'  # Already applied where relevant
    )

if ($issues) {
    $issues | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap
    $errorCount = ($issues | Where-Object Severity -eq 'Error').Count
    if ($errorCount -gt 0) {
        Write-Error "$errorCount error-level issue(s) must be fixed."
        exit 1
    }
    else {
        Write-Host "$($issues.Count) warning(s) — review before merging." -ForegroundColor Yellow
    }
}

Write-Host '✓ PSScriptAnalyzer passed' -ForegroundColor Green
exit 0
