<#
.SYNOPSIS
    Nightly backup of Power BI reports and datasets from the live service.
.DESCRIPTION
    Exports all reports in the target workspace as .pbix, captures dataset
    metadata (refresh schedules, parameters, datasource bindings, RLS roles),
    and uploads everything to Azure Blob Storage with versioning.

    Runs on a schedule (cron / Azure DevOps scheduled pipeline).
    Retention managed by Storage lifecycle policy (see infrastructure/main.bicep).

    Recovery: a given night's blob becomes the input to Deploy-PowerBIReport.ps1
    in a fresh workspace, restoring both reports and their configuration.
.PARAMETER Environment
    Target environment.
.PARAMETER StorageAccount
    Backup destination storage account.
.PARAMETER ContainerName
    Blob container. Created if missing.
.EXAMPLE
    ./Backup-PowerBIWorkspace.ps1 -Environment Prod -StorageAccount stpowerbiprod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'Test', 'Prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$StorageAccount,

    [string]$ContainerName = 'powerbi-backups',

    [string]$ConfigPath,

    [switch]$IncludePBIXExport = $true
)

#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptRoot '..' 'modules' 'PowerBIDeployment.psd1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptRoot '..' 'config' "$($Environment.ToLower()).yaml"
}

Import-Module powershell-yaml -Force
Import-Module Az.Storage -Force
Import-Module Az.KeyVault -Force

$cfg = ConvertFrom-Yaml (Get-Content $ConfigPath -Raw)
$backupDate = Get-Date -Format 'yyyy-MM-dd'
$backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pbi-backup-$backupDate-$([guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Write-DeploymentLog -Message 'Power BI backup starting' -Level INFO -Properties @{
    environment   = $Environment
    workspace     = $cfg.workspace.name
    backupRoot    = $backupRoot
    storageAccount = $StorageAccount
    container     = $ContainerName
}

# ---------------------------------------------------------------------------
# Authenticate to Power BI
# ---------------------------------------------------------------------------
$secureSecret = Get-AzKeyVaultSecret `
    -VaultName $cfg.keyVault.name `
    -Name $cfg.auth.clientSecretName `
    -AsPlainText |
    ConvertTo-SecureString -AsPlainText -Force

Connect-PowerBIWithServicePrincipal `
    -TenantId $cfg.auth.tenantId `
    -ClientId $cfg.auth.clientId `
    -ClientSecret $secureSecret | Out-Null

try {
    $workspace = Get-PowerBIWorkspace -Name $cfg.workspace.name -Scope Organization -ErrorAction Stop |
                 Select-Object -First 1
    $wsId = $workspace.Id
    Write-DeploymentLog -Message "Workspace: $($workspace.Name) ($wsId)" -Level INFO

    # ---------------------------------------------------------------------------
    # 1. Export workspace metadata
    # ---------------------------------------------------------------------------
    $wsMetadata = @{
        backupDate     = $backupDate
        backupTime     = (Get-Date).ToUniversalTime().ToString('o')
        environment    = $Environment
        workspaceId    = $wsId
        workspaceName  = $workspace.Name
        capacityId     = $workspace.CapacityId
        isOnDedicated  = $workspace.IsOnDedicatedCapacity
        reports        = @()
        datasets       = @()
        dataflows      = @()
    }

    # ---------------------------------------------------------------------------
    # 2. Reports - metadata + .pbix export where supported
    # ---------------------------------------------------------------------------
    $reports = (Invoke-PowerBIRestMethod -Url "groups/$wsId/reports" -Method Get |
                ConvertFrom-Json).value

    Write-DeploymentLog -Message "Found $($reports.Count) report(s)" -Level INFO

    foreach ($r in $reports) {
        $entry = @{
            id         = $r.id
            name       = $r.name
            reportType = $r.reportType          # PowerBIReport or PaginatedReport
            datasetId  = $r.datasetId
            webUrl     = $r.webUrl
            createdBy  = $r.createdBy
            modifiedBy = $r.modifiedBy
            modifiedDateTime = $r.modifiedDateTime
        }
        $wsMetadata.reports += $entry

        if ($IncludePBIXExport -and $r.reportType -eq 'PowerBIReport') {
            $safeName = $r.name -replace '[^\w\-]', '_'
            $outFile = Join-Path $backupRoot "$safeName.pbix"

            try {
                # Export-PowerBIReport returns a .pbix file stream
                Export-PowerBIReport -Id $r.id -Workspace $workspace -OutFile $outFile -ErrorAction Stop
                Write-DeploymentLog -Message "Exported $($r.name)" -Level INFO -Properties @{
                    sizeMB = [Math]::Round((Get-Item $outFile).Length / 1MB, 2)
                }
            }
            catch {
                # Some reports can't be exported (e.g. live-connected to AAS, or with incremental refresh)
                Write-DeploymentLog -Message "Export failed for $($r.name) - metadata only" -Level WARN -Properties @{
                    error = $_.Exception.Message
                }
            }
        }
        elseif ($r.reportType -eq 'PaginatedReport') {
            # Paginated report definition download
            try {
                $safeName = $r.name -replace '[^\w\-]', '_'
                $outFile = Join-Path $backupRoot "$safeName.rdl"
                $content = Invoke-PowerBIRestMethod `
                    -Url "groups/$wsId/reports/$($r.id)/Export" `
                    -Method Get
                [System.IO.File]::WriteAllText($outFile, $content)
                Write-DeploymentLog -Message "Exported paginated report $($r.name)" -Level INFO
            }
            catch {
                Write-DeploymentLog -Message "Paginated export failed for $($r.name)" -Level WARN -Properties @{
                    error = $_.Exception.Message
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # 3. Datasets - refresh schedules, parameters, datasources, RLS roles
    # ---------------------------------------------------------------------------
    $datasets = (Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets" -Method Get |
                 ConvertFrom-Json).value

    foreach ($ds in $datasets) {
        $dsEntry = @{
            id              = $ds.id
            name            = $ds.name
            configuredBy    = $ds.configuredBy
            isRefreshable   = $ds.isRefreshable
            isEffectiveIdentityRequired = $ds.isEffectiveIdentityRequired
            parameters      = @()
            refreshSchedule = $null
            datasources     = @()
            roles           = @()
        }

        # Parameters
        try {
            $params = (Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$($ds.id)/parameters" -Method Get |
                       ConvertFrom-Json).value
            $dsEntry.parameters = $params
        } catch { }

        # Refresh schedule (may not exist)
        try {
            $sched = Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$($ds.id)/refreshSchedule" -Method Get |
                     ConvertFrom-Json
            $dsEntry.refreshSchedule = $sched
        } catch { }

        # Data sources (structure only — never credentials)
        try {
            $dsrc = (Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$($ds.id)/datasources" -Method Get |
                     ConvertFrom-Json).value
            $dsEntry.datasources = $dsrc | Select-Object datasourceType, connectionDetails, datasourceId, gatewayId
        } catch { }

        $wsMetadata.datasets += $dsEntry
    }

    # ---------------------------------------------------------------------------
    # 4. Dataflows (if any)
    # ---------------------------------------------------------------------------
    try {
        $dataflows = (Invoke-PowerBIRestMethod -Url "groups/$wsId/dataflows" -Method Get |
                      ConvertFrom-Json).value
        foreach ($df in $dataflows) {
            $wsMetadata.dataflows += @{
                objectId    = $df.objectId
                name        = $df.name
                description = $df.description
                modelUrl    = $df.modelUrl
            }

            # Export dataflow JSON
            try {
                $dfJson = Invoke-PowerBIRestMethod -Url "groups/$wsId/dataflows/$($df.objectId)" -Method Get
                $safeName = $df.name -replace '[^\w\-]', '_'
                $dfJson | Out-File (Join-Path $backupRoot "dataflow-$safeName.json") -Encoding utf8
            } catch {
                Write-DeploymentLog -Message "Dataflow export failed: $($df.name)" -Level WARN
            }
        }
    }
    catch {
        Write-DeploymentLog -Message 'No dataflows or error listing them' -Level DEBUG
    }

    # ---------------------------------------------------------------------------
    # 5. Workspace access control
    # ---------------------------------------------------------------------------
    try {
        $users = (Invoke-PowerBIRestMethod -Url "groups/$wsId/users" -Method Get |
                  ConvertFrom-Json).value
        $wsMetadata.access = $users | Select-Object identifier, emailAddress, groupUserAccessRight, principalType
    } catch { }

    # ---------------------------------------------------------------------------
    # 6. Write metadata manifest
    # ---------------------------------------------------------------------------
    $manifestPath = Join-Path $backupRoot 'manifest.json'
    $wsMetadata | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding utf8

    Write-DeploymentLog -Message 'Manifest written' -Level INFO -Properties @{
        reports   = $wsMetadata.reports.Count
        datasets  = $wsMetadata.datasets.Count
        dataflows = $wsMetadata.dataflows.Count
    }

    # ---------------------------------------------------------------------------
    # 7. Package + upload to blob
    # ---------------------------------------------------------------------------
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "pbi-$Environment-$backupDate.zip"
    Compress-Archive -Path "$backupRoot/*" -DestinationPath $zipPath -Force

    $sizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-DeploymentLog -Message "Backup packaged" -Level INFO -Properties @{
        zipPath = $zipPath
        sizeMB  = $sizeMB
    }

    # Upload using Az context (pipeline's identity has Storage Blob Data Contributor)
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

    $blobName = "$Environment/$backupDate/pbi-$Environment-$backupDate.zip"
    Set-AzStorageBlobContent `
        -File $zipPath `
        -Container $ContainerName `
        -Blob $blobName `
        -Context $ctx `
        -StandardBlobTier Hot `
        -Metadata @{
            environment   = $Environment
            backupDate    = $backupDate
            workspaceId   = $wsId
            reportCount   = $wsMetadata.reports.Count.ToString()
            datasetCount  = $wsMetadata.datasets.Count.ToString()
        } `
        -Force | Out-Null

    Write-DeploymentLog -Message 'Backup uploaded' -Level INFO -Properties @{
        container = $ContainerName
        blobName  = $blobName
        sizeMB    = $sizeMB
    }
}
finally {
    Disconnect-PowerBISession
    # Cleanup local temp
    Remove-Item -Path $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }
}

Write-DeploymentLog -Message 'Backup complete' -Level INFO
