<#
.SYNOPSIS
    One-time bootstrap for a Jenkins Windows build agent that will deploy Power BI reports.

.DESCRIPTION
    Installs the prerequisites needed by the deployment pipeline:
      - PowerShell 7 (for a modern execution environment)
      - MicrosoftPowerBIMgmt module (Power BI REST cmdlets)
      - Az.Accounts module (Azure AD helper utilities)
      - NuGet package provider (required for Install-Module)

    Run this once per agent, as Administrator.

.EXAMPLE
    .\Bootstrap-JenkinsAgent.ps1
#>
[CmdletBinding()]
param(
    [Parameter()][string]$PowerBIModuleVersion = '1.2.1111'
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw 'This script must be run as Administrator'
}

Write-Host '=== Jenkins Agent Bootstrap for Power BI Deployment ===' -ForegroundColor Cyan

# 1. NuGet provider (required for Install-Module)
Write-Host 'Installing NuGet package provider...'
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null

# 2. Trust PSGallery to avoid interactive prompts
Write-Host 'Configuring PSGallery as trusted...'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# 3. MicrosoftPowerBIMgmt
Write-Host "Installing MicrosoftPowerBIMgmt (>= $PowerBIModuleVersion)..."
Install-Module -Name MicrosoftPowerBIMgmt `
    -MinimumVersion $PowerBIModuleVersion `
    -Scope AllUsers `
    -Force `
    -AllowClobber

# 4. Az.Accounts
Write-Host 'Installing Az.Accounts...'
Install-Module -Name Az.Accounts -Scope AllUsers -Force -AllowClobber

# 5. Verify
Write-Host 'Verifying installations...' -ForegroundColor Cyan
$modules = @('MicrosoftPowerBIMgmt', 'Az.Accounts')
foreach ($m in $modules) {
    $installed = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) {
        Write-Host "  OK  $m $($installed.Version)"
    } else {
        Write-Host "  FAIL  $m not found" -ForegroundColor Red
    }
}

# 6. Ensure TLS 1.2 is enabled (required by PSGallery and Power BI REST API)
Write-Host 'Ensuring .NET TLS 1.2 is enabled system-wide...'
[Microsoft.Win32.Registry]::SetValue(
    'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'SchUseStrongCrypto', 1, 'DWord')
[Microsoft.Win32.Registry]::SetValue(
    'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319',
    'SchUseStrongCrypto', 1, 'DWord')

Write-Host '=== Bootstrap complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. In Jenkins, label this agent with: windows-powerbi'
Write-Host '  2. Store these credentials in Jenkins (kind: Secret Text):'
Write-Host '       - pbi-azure-tenant-id'
Write-Host '       - pbi-service-principal-client-id'
Write-Host '       - pbi-service-principal-client-secret'
Write-Host '  3. Validate with a DRY_RUN build of the pipeline'
