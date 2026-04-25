<#
.SYNOPSIS
    Authenticate to Power BI Service using an Azure AD Service Principal.

.DESCRIPTION
    Performs OAuth2 client_credentials flow against Azure AD and establishes a
    session with Power BI Service via the MicrosoftPowerBIMgmt module.

    The service principal MUST:
      1. Be a member of an Azure AD security group
      2. Have that security group granted "can use service principals" rights
         in the Power BI Admin Portal (Tenant Settings > Developer Settings)
      3. Be added as a Member or Admin of the target workspace(s)
      4. The target workspace must be backed by Premium / Premium-Per-User capacity

.PARAMETER TenantId
    Azure AD tenant GUID.

.PARAMETER ClientId
    Application (client) ID of the service principal.

.PARAMETER ClientSecret
    Client secret for the service principal.

.NOTES
    Author : DevOps / Data Platform
    Requires : MicrosoftPowerBIMgmt 1.2.1111+, PowerShell 5.1 or 7+
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [Parameter(Mandatory = $true)][string]$ClientSecret
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import module (install with: Install-Module MicrosoftPowerBIMgmt -Scope AllUsers)
Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

try {
    Write-Host "Authenticating service principal [$ClientId] against tenant [$TenantId]..."

    $securePassword = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($ClientId, $securePassword)

    # ServicePrincipal flag triggers client_credentials grant against Power BI REST API
    $connection = Connect-PowerBIServiceAccount `
        -ServicePrincipal `
        -Credential $credential `
        -TenantId $TenantId `
        -Environment Public

    if (-not $connection) {
        throw "Connect-PowerBIServiceAccount returned null — authentication failed"
    }

    Write-Host "Successfully authenticated as: $($connection.UserName)"
    Write-Host "Tenant: $($connection.TenantId)"
    Write-Host "Environment: $($connection.Environment)"

    # Sanity check — call a lightweight REST endpoint to prove the token works
    try {
        $null = Invoke-PowerBIRestMethod -Url 'groups?$top=1' -Method Get
        Write-Host "Token validation OK — API call succeeded"
    } catch {
        throw "Authentication succeeded but API call failed. Check that the SP has API access enabled in the tenant admin portal. Error: $_"
    }
}
catch {
    Write-Error "Power BI authentication failed: $($_.Exception.Message)"
    throw
}
