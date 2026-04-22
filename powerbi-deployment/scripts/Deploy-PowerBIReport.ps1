<#
.SYNOPSIS
    Deploy-PowerBIReport.ps1 - Main orchestration script for Power BI report deployment.
.DESCRIPTION
    Deploys one or more Power BI reports (.pbix / .rdl) to a target environment
    (Dev / Test / Prod). Fetches secrets from Azure Key Vault, validates Premium
    capacity, publishes reports, binds data source credentials, and runs smoke tests.

    Designed to run in Azure DevOps / GitHub Actions / Jenkins agents.
.PARAMETER Environment
    Target environment: Dev, Test, or Prod.
.PARAMETER ConfigPath
    Path to deployment config YAML/JSON (defaults to ./config/<env>.yaml).
.PARAMETER ArtifactPath
    Directory containing the .pbix / .rdl files to deploy.
.PARAMETER ReportFilter
    Optional wildcard filter to deploy only specific reports.
.PARAMETER DryRun
    If set, performs validation only - no actual deployment.
.EXAMPLE
    ./Deploy-PowerBIReport.ps1 -Environment Prod -ArtifactPath ./artifacts
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'Test', 'Prod')]
    [string]$Environment,

    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$ArtifactPath,

    [string]$ReportFilter = '*',

    [switch]$DryRun,

    [switch]$SkipRefresh
)

#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulePath = Join-Path $ScriptRoot '..' 'modules' 'PowerBIDeployment.psd1'

Import-Module $ModulePath -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptRoot '..' 'config' "$($Environment.ToLower()).yaml"
}

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

# YAML parsing - requires powershell-yaml module
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Install-Module -Name 'powershell-yaml' -Force -Scope CurrentUser -AcceptLicense
}
Import-Module 'powershell-yaml' -Force

$rawYaml = Get-Content -Path $ConfigPath -Raw
$config = ConvertFrom-Yaml -Yaml $rawYaml

Write-DeploymentLog -Message 'Deployment started' -Level INFO -Properties @{
    environment = $Environment
    configPath  = $ConfigPath
    artifactPath = $ArtifactPath
    dryRun      = [bool]$DryRun
}

# -----------------------------------------------------------------------------
# Fetch secrets from Key Vault
# -----------------------------------------------------------------------------
function Get-SecretFromKeyVault {
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$SecretName
    )

    if (-not (Get-Module -ListAvailable -Name 'Az.KeyVault')) {
        Install-Module -Name 'Az.KeyVault' -Force -Scope CurrentUser -AcceptLicense
    }
    Import-Module 'Az.KeyVault' -Force

    # Assumes Az context is already established by the pipeline
    # (AzureCLI@2 task / azure/login GH action)
    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText -ErrorAction Stop
    return (ConvertTo-SecureString -String $secret -AsPlainText -Force)
}

Write-DeploymentLog -Message 'Fetching secrets from Key Vault' -Level INFO

$tenantId       = $config.auth.tenantId
$clientId       = $config.auth.clientId
$clientSecret   = Get-SecretFromKeyVault -VaultName $config.keyVault.name -SecretName $config.auth.clientSecretName

# Data source credentials (optional)
$dsUsername = $null
$dsPassword = $null
if ($config.dataSource -and $config.dataSource.credentialType -eq 'Basic') {
    $dsUsername = Get-SecretFromKeyVault -VaultName $config.keyVault.name -SecretName $config.dataSource.usernameSecretName
    $dsPassword = Get-SecretFromKeyVault -VaultName $config.keyVault.name -SecretName $config.dataSource.passwordSecretName
}

# -----------------------------------------------------------------------------
# Connect
# -----------------------------------------------------------------------------
try {
    Connect-PowerBIWithServicePrincipal `
        -TenantId $tenantId `
        -ClientId $clientId `
        -ClientSecret $clientSecret | Out-Null

    # -------------------------------------------------------------------------
    # Workspace
    # -------------------------------------------------------------------------
    $workspace = Get-OrCreateWorkspace `
        -WorkspaceName $config.workspace.name `
        -CapacityId $config.workspace.capacityId `
        -CreateIfMissing:$config.workspace.createIfMissing

    Test-PremiumCapacity -WorkspaceId $workspace.Id | Out-Null

    # -------------------------------------------------------------------------
    # Discover artifacts
    # -------------------------------------------------------------------------
    $reports = Get-ChildItem -Path $ArtifactPath -Include '*.pbix', '*.rdl' -Recurse -File |
               Where-Object { $_.BaseName -like $ReportFilter }

    if ($reports.Count -eq 0) {
        throw "No .pbix or .rdl files found in $ArtifactPath matching filter '$ReportFilter'"
    }

    Write-DeploymentLog -Message "Found $($reports.Count) report(s) to deploy" -Level INFO

    # -------------------------------------------------------------------------
    # Dry-run short-circuit
    # -------------------------------------------------------------------------
    if ($DryRun) {
        Write-DeploymentLog -Message 'DryRun mode - skipping actual deployment' -Level WARN
        $reports | ForEach-Object {
            Write-DeploymentLog -Message "Would deploy: $($_.Name)" -Level INFO -Properties @{
                file = $_.FullName
            }
        }
        return
    }

    # -------------------------------------------------------------------------
    # Deploy each report
    # -------------------------------------------------------------------------
    $results = [System.Collections.Generic.List[object]]::new()
    $failedReports = [System.Collections.Generic.List[string]]::new()

    foreach ($report in $reports) {
        try {
            $reportConfig = $config.reports | Where-Object { $_.fileName -eq $report.Name } | Select-Object -First 1
            $reportName = if ($reportConfig -and $reportConfig.displayName) { $reportConfig.displayName } else { $report.BaseName }

            $published = Publish-PowerBIReport `
                -FilePath $report.FullName `
                -WorkspaceId $workspace.Id `
                -ReportName $reportName `
                -ConflictAction 'CreateOrOverwrite'

            # Update datasource credentials (only for .pbix with a dataset)
            if ($report.Extension -eq '.pbix' -and $dsUsername -and $dsPassword) {
                # Get dataset ID - newly-published PBIX creates a dataset with matching name
                Start-Sleep -Seconds 10  # allow dataset registration
                $datasetsResponse = (Invoke-PowerBIRestMethod `
                    -Url "groups/$($workspace.Id)/datasets" `
                    -Method Get) | ConvertFrom-Json
                $dataset = $datasetsResponse.value | Where-Object { $_.name -eq $reportName } | Select-Object -First 1

                if ($dataset) {
                    Update-ReportDatasourceCredentials `
                        -DatasetId $dataset.id `
                        -WorkspaceId $workspace.Id `
                        -CredentialType 'Basic' `
                        -Username $dsUsername `
                        -Password $dsPassword

                    # Apply parameter overrides per environment
                    if ($reportConfig -and $reportConfig.parameters) {
                        $params = @{}
                        foreach ($p in $reportConfig.parameters.GetEnumerator()) { $params[$p.Key] = $p.Value }
                        Update-ReportDataset `
                            -DatasetId $dataset.id `
                            -WorkspaceId $workspace.Id `
                            -Parameters $params `
                            -TriggerRefresh:(-not $SkipRefresh)
                    }
                    elseif (-not $SkipRefresh) {
                        Update-ReportDataset `
                            -DatasetId $dataset.id `
                            -WorkspaceId $workspace.Id `
                            -TriggerRefresh
                    }
                }
            }

            # Smoke test
            $passed = Test-ReportDeployment -ReportId $published.Id -WorkspaceId $workspace.Id
            if (-not $passed) {
                throw "Post-deploy validation failed for $reportName"
            }

            $results.Add([pscustomobject]@{
                File        = $report.Name
                ReportName  = $reportName
                ReportId    = $published.Id
                Status      = 'Success'
            })
        }
        catch {
            Write-DeploymentLog -Message "Deployment FAILED for $($report.Name)" -Level ERROR -Properties @{
                error = $_.Exception.Message
                stack = $_.ScriptStackTrace
            }
            $failedReports.Add($report.Name)
            $results.Add([pscustomobject]@{
                File       = $report.Name
                ReportName = $report.BaseName
                Status     = 'Failed'
                Error      = $_.Exception.Message
            })
        }
    }

    # -------------------------------------------------------------------------
    # Summary & exit code
    # -------------------------------------------------------------------------
    $summaryPath = Join-Path $ArtifactPath 'deployment-summary.json'
    $results | ConvertTo-Json -Depth 5 | Out-File $summaryPath -Encoding utf8

    Write-DeploymentLog -Message 'Deployment summary' -Level INFO -Properties @{
        total   = $results.Count
        success = ($results | Where-Object Status -eq 'Success').Count
        failed  = $failedReports.Count
        summaryFile = $summaryPath
    }

    if ($failedReports.Count -gt 0) {
        throw "Deployment completed with $($failedReports.Count) failure(s): $($failedReports -join ', ')"
    }

    Write-DeploymentLog -Message 'All reports deployed successfully' -Level INFO
}
finally {
    Disconnect-PowerBISession
}
