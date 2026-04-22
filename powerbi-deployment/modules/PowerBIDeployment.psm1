<#
.SYNOPSIS
    Power BI Deployment Module - Enterprise Grade
.DESCRIPTION
    PowerShell module providing reusable functions for deploying Power BI reports
    (.pbix and .rdl paginated reports) to Power BI Service with Premium capacity.
.NOTES
    Author: DevOps Team
    Requires: PowerShell 7.2+, MicrosoftPowerBIMgmt module
    Authentication: Service Principal (recommended for CI/CD)
#>

#Requires -Version 7.2
#Requires -Modules @{ ModuleName='MicrosoftPowerBIMgmt'; ModuleVersion='1.2.1111' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Logging

$script:LogLevel = 'INFO'
$script:CorrelationId = [guid]::NewGuid().ToString()

function Write-DeploymentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [hashtable]$Properties = @{}
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $logEntry = [ordered]@{
        timestamp     = $timestamp
        level         = $Level
        correlationId = $script:CorrelationId
        message       = $Message
    }

    foreach ($key in $Properties.Keys) {
        $logEntry[$key] = $Properties[$key]
    }

    # Structured JSON output for log aggregation (Splunk, ELK, Azure Monitor)
    $json = $logEntry | ConvertTo-Json -Compress -Depth 5

    switch ($Level) {
        'ERROR' { Write-Host $json -ForegroundColor Red }
        'FATAL' { Write-Host $json -ForegroundColor Red -BackgroundColor Black }
        'WARN'  { Write-Host $json -ForegroundColor Yellow }
        'DEBUG' { Write-Host $json -ForegroundColor Gray }
        default { Write-Host $json -ForegroundColor Green }
    }
}

#endregion

#region Authentication

function Connect-PowerBIWithServicePrincipal {
    <#
    .SYNOPSIS
        Authenticates to Power BI Service using a Service Principal.
    .DESCRIPTION
        Uses client credentials flow. Secrets should be fetched from a vault
        (Azure Key Vault, HashiCorp Vault) immediately before calling this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [securestring]$ClientSecret,

        [int]$MaxRetries = 3
    )

    Write-DeploymentLog -Message 'Authenticating to Power BI Service' -Level INFO -Properties @{
        tenantId = $TenantId
        clientId = $ClientId
    }

    $credential = [pscredential]::new($ClientId, $ClientSecret)

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $connection = Connect-PowerBIServiceAccount `
                -ServicePrincipal `
                -Credential $credential `
                -TenantId $TenantId `
                -ErrorAction Stop

            Write-DeploymentLog -Message 'Authentication successful' -Level INFO -Properties @{
                upn     = $connection.UserName
                environment = $connection.Environment
            }
            return $connection
        }
        catch {
            Write-DeploymentLog -Message "Authentication attempt $attempt failed" -Level WARN -Properties @{
                error = $_.Exception.Message
            }
            if ($attempt -ge $MaxRetries) {
                Write-DeploymentLog -Message 'All authentication attempts exhausted' -Level FATAL
                throw
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
}

function Disconnect-PowerBISession {
    [CmdletBinding()]
    param()
    try {
        Disconnect-PowerBIServiceAccount -ErrorAction SilentlyContinue | Out-Null
        Write-DeploymentLog -Message 'Disconnected from Power BI Service' -Level INFO
    }
    catch {
        Write-DeploymentLog -Message 'Disconnect warning (non-fatal)' -Level WARN -Properties @{ error = $_.Exception.Message }
    }
}

#endregion

#region Workspace Management

function Get-OrCreateWorkspace {
    <#
    .SYNOPSIS
        Gets an existing workspace or creates a new one, assigns Premium capacity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceName,

        [string]$CapacityId,

        [switch]$CreateIfMissing
    )

    Write-DeploymentLog -Message "Looking up workspace: $WorkspaceName" -Level INFO

    $workspace = Get-PowerBIWorkspace -Name $WorkspaceName -Scope Organization -ErrorAction SilentlyContinue |
                 Where-Object { $_.State -eq 'Active' } |
                 Select-Object -First 1

    if (-not $workspace) {
        if (-not $CreateIfMissing) {
            throw "Workspace '$WorkspaceName' not found and -CreateIfMissing not specified."
        }

        Write-DeploymentLog -Message "Creating workspace: $WorkspaceName" -Level INFO
        $workspace = New-PowerBIWorkspace -Name $WorkspaceName

        if ($CapacityId) {
            Write-DeploymentLog -Message "Assigning workspace to Premium capacity" -Level INFO -Properties @{
                workspaceId = $workspace.Id
                capacityId  = $CapacityId
            }
            $body = @{ capacityId = $CapacityId } | ConvertTo-Json
            Invoke-PowerBIRestMethod `
                -Url "groups/$($workspace.Id)/AssignToCapacity" `
                -Method Post `
                -Body $body | Out-Null
        }
    }
    else {
        Write-DeploymentLog -Message "Workspace found" -Level INFO -Properties @{
            workspaceId   = $workspace.Id
            isOnDedicated = $workspace.IsOnDedicatedCapacity
        }

        # Verify capacity assignment if required
        if ($CapacityId -and $workspace.CapacityId -ne $CapacityId) {
            Write-DeploymentLog -Message 'Reassigning workspace to required capacity' -Level WARN
            $body = @{ capacityId = $CapacityId } | ConvertTo-Json
            Invoke-PowerBIRestMethod `
                -Url "groups/$($workspace.Id)/AssignToCapacity" `
                -Method Post `
                -Body $body | Out-Null
        }
    }

    return $workspace
}

function Test-PremiumCapacity {
    <#
    .SYNOPSIS
        Verifies the workspace is on a Premium / PPU / Fabric capacity.
        Paginated reports (.rdl) require Premium.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId
    )

    $ws = Get-PowerBIWorkspace -Id $WorkspaceId -Scope Organization

    if (-not $ws.IsOnDedicatedCapacity) {
        throw "Workspace '$($ws.Name)' is NOT on a dedicated (Premium/PPU/Fabric) capacity. Paginated reports (.rdl) require Premium."
    }

    Write-DeploymentLog -Message 'Premium capacity check passed' -Level INFO -Properties @{
        workspaceId = $WorkspaceId
        capacityId  = $ws.CapacityId
    }
    return $true
}

#endregion

#region Report Deployment

function Publish-PowerBIReport {
    <#
    .SYNOPSIS
        Publishes a .pbix or .rdl report to a Power BI workspace.
    .DESCRIPTION
        Handles both paginated (.rdl) and standard (.pbix) reports.
        Uses CreateOrOverwrite semantics by default. Idempotent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [string]$ReportName,

        [ValidateSet('CreateOrOverwrite', 'Abort', 'Ignore', 'Overwrite')]
        [string]$ConflictAction = 'CreateOrOverwrite',

        [int]$TimeoutSeconds = 600
    )

    $file = Get-Item -Path $FilePath
    $extension = $file.Extension.ToLowerInvariant()

    if ($extension -notin '.pbix', '.rdl') {
        throw "Unsupported file type: $extension. Only .pbix and .rdl are supported."
    }

    if (-not $ReportName) {
        $ReportName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    }

    $fileSizeMB = [Math]::Round($file.Length / 1MB, 2)

    Write-DeploymentLog -Message 'Starting report publish' -Level INFO -Properties @{
        fileName    = $file.Name
        reportName  = $ReportName
        workspaceId = $WorkspaceId
        fileType    = $extension
        fileSizeMB  = $fileSizeMB
    }

    if ($PSCmdlet.ShouldProcess($ReportName, 'Publish to Power BI Service')) {

        if ($extension -eq '.rdl') {
            # Paginated reports use a different API endpoint (imports with nameConflict parameter)
            $result = Publish-PaginatedReport `
                -FilePath $file.FullName `
                -WorkspaceId $WorkspaceId `
                -ReportName $ReportName `
                -ConflictAction $ConflictAction `
                -TimeoutSeconds $TimeoutSeconds
        }
        else {
            # Standard .pbix using built-in cmdlet
            $result = New-PowerBIReport `
                -Path $file.FullName `
                -Name $ReportName `
                -WorkspaceId $WorkspaceId `
                -ConflictAction $ConflictAction `
                -Timeout $TimeoutSeconds
        }

        Write-DeploymentLog -Message 'Report published successfully' -Level INFO -Properties @{
            reportId   = $result.Id
            reportName = $ReportName
        }

        return $result
    }
}

function Publish-PaginatedReport {
    <#
    .SYNOPSIS
        Publishes an .rdl paginated report via the Power BI REST API import endpoint.
    .DESCRIPTION
        New-PowerBIReport does not handle .rdl files. Must use the imports API directly.
        Polls import status until the report appears.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ReportName,
        [string]$ConflictAction = 'CreateOrOverwrite',
        [int]$TimeoutSeconds = 600
    )

    $url = "groups/$WorkspaceId/imports?datasetDisplayName=$([uri]::EscapeDataString($ReportName)).rdl&nameConflict=$ConflictAction"

    Write-DeploymentLog -Message 'Uploading paginated report via REST API' -Level DEBUG -Properties @{
        url = $url
    }

    # Build multipart/form-data payload
    $boundary = [guid]::NewGuid().ToString()
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $encoding = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $fileContent = $encoding.GetString($fileBytes)

    $bodyLines = @(
        "--$boundary"
        "Content-Disposition: form-data; name=`"file`"; filename=`"$ReportName.rdl`""
        "Content-Type: application/octet-stream"
        ""
        $fileContent
        "--$boundary--"
        ""
    ) -join "`r`n"

    $contentType = "multipart/form-data; boundary=$boundary"

    $importResponse = Invoke-PowerBIRestMethod `
        -Url $url `
        -Method Post `
        -Body $bodyLines `
        -ContentType $contentType

    $import = $importResponse | ConvertFrom-Json
    $importId = $import.id

    Write-DeploymentLog -Message 'Import job created, polling status' -Level INFO -Properties @{
        importId = $importId
    }

    # Poll for completion
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollInterval = 5
    do {
        Start-Sleep -Seconds $pollInterval
        $statusJson = Invoke-PowerBIRestMethod -Url "groups/$WorkspaceId/imports/$importId" -Method Get
        $status = $statusJson | ConvertFrom-Json

        Write-DeploymentLog -Message "Import status: $($status.importState)" -Level DEBUG -Properties @{
            importId    = $importId
            elapsedSec  = [int]$stopwatch.Elapsed.TotalSeconds
        }

        if ($status.importState -eq 'Succeeded') {
            $reportId = $status.reports[0].id
            return [pscustomobject]@{
                Id          = $reportId
                Name        = $ReportName
                ImportId    = $importId
                WorkspaceId = $WorkspaceId
            }
        }
        elseif ($status.importState -eq 'Failed') {
            throw "Import failed: $($status | ConvertTo-Json -Depth 5)"
        }

    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    throw "Import timed out after $TimeoutSeconds seconds (importId=$importId)"
}

#endregion

#region Dataset / Datasource Management

function Update-ReportDatasourceCredentials {
    <#
    .SYNOPSIS
        Updates datasource credentials for a published report's dataset.
    .DESCRIPTION
        Required after publish when using service principal - datasets are created
        with no credentials and must have them bound before refresh can succeed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetId,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][ValidateSet('Basic', 'OAuth2', 'Key', 'Windows', 'Anonymous')]
        [string]$CredentialType,
        [securestring]$Username,
        [securestring]$Password,
        [ValidateSet('None', 'Encrypted')]
        [string]$EncryptedConnection = 'Encrypted',
        [ValidateSet('Public', 'Organizational', 'Private')]
        [string]$PrivacyLevel = 'Organizational'
    )

    Write-DeploymentLog -Message 'Updating dataset datasource credentials' -Level INFO -Properties @{
        datasetId      = $DatasetId
        credentialType = $CredentialType
    }

    $datasources = (Invoke-PowerBIRestMethod `
        -Url "groups/$WorkspaceId/datasets/$DatasetId/datasources" `
        -Method Get) | ConvertFrom-Json

    foreach ($ds in $datasources.value) {
        $gatewayId = $ds.gatewayId
        $datasourceId = $ds.datasourceId

        if ($CredentialType -eq 'Basic') {
            $plainUser = [System.Net.NetworkCredential]::new('', $Username).Password
            $plainPass = [System.Net.NetworkCredential]::new('', $Password).Password
            $credentialsJson = @{
                credentialData = @(
                    @{ name = 'username'; value = $plainUser }
                    @{ name = 'password'; value = $plainPass }
                )
            } | ConvertTo-Json -Compress
        }
        elseif ($CredentialType -eq 'Key') {
            $plainKey = [System.Net.NetworkCredential]::new('', $Password).Password
            $credentialsJson = @{
                credentialData = @(
                    @{ name = 'key'; value = $plainKey }
                )
            } | ConvertTo-Json -Compress
        }
        else {
            throw "CredentialType '$CredentialType' not yet implemented in this helper."
        }

        $body = @{
            credentialDetails = @{
                credentialType       = $CredentialType
                credentials          = $credentialsJson
                encryptedConnection  = $EncryptedConnection
                encryptionAlgorithm  = 'None'
                privacyLevel         = $PrivacyLevel
            }
        } | ConvertTo-Json -Depth 5

        Invoke-PowerBIRestMethod `
            -Url "gateways/$gatewayId/datasources/$datasourceId" `
            -Method Patch `
            -Body $body | Out-Null

        Write-DeploymentLog -Message 'Datasource credentials updated' -Level INFO -Properties @{
            gatewayId    = $gatewayId
            datasourceId = $datasourceId
        }
    }
}

function Update-ReportDataset {
    <#
    .SYNOPSIS
        Rebinds or refreshes dataset parameters post-deployment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetId,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [hashtable]$Parameters,
        [switch]$TriggerRefresh
    )

    if ($Parameters -and $Parameters.Count -gt 0) {
        Write-DeploymentLog -Message 'Updating dataset parameters' -Level INFO -Properties @{
            datasetId      = $DatasetId
            parameterCount = $Parameters.Count
        }

        $updateDetails = @()
        foreach ($key in $Parameters.Keys) {
            $updateDetails += @{ name = $key; newValue = [string]$Parameters[$key] }
        }
        $body = @{ updateDetails = $updateDetails } | ConvertTo-Json -Depth 5

        Invoke-PowerBIRestMethod `
            -Url "groups/$WorkspaceId/datasets/$DatasetId/Default.UpdateParameters" `
            -Method Post `
            -Body $body | Out-Null
    }

    if ($TriggerRefresh) {
        Write-DeploymentLog -Message 'Triggering dataset refresh' -Level INFO -Properties @{
            datasetId = $DatasetId
        }
        Invoke-PowerBIRestMethod `
            -Url "groups/$WorkspaceId/datasets/$DatasetId/refreshes" `
            -Method Post `
            -Body '{"notifyOption":"MailOnFailure"}' | Out-Null
    }
}

#endregion

#region Validation & Post-Deploy

function Test-ReportDeployment {
    <#
    .SYNOPSIS
        Smoke test: confirms report is accessible and queryable post-deploy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportId,
        [Parameter(Mandatory)][string]$WorkspaceId
    )

    try {
        $report = (Invoke-PowerBIRestMethod `
            -Url "groups/$WorkspaceId/reports/$ReportId" `
            -Method Get) | ConvertFrom-Json

        Write-DeploymentLog -Message 'Post-deploy validation passed' -Level INFO -Properties @{
            reportId   = $report.id
            reportName = $report.name
            webUrl     = $report.webUrl
            reportType = $report.reportType
        }
        return $true
    }
    catch {
        Write-DeploymentLog -Message 'Post-deploy validation FAILED' -Level ERROR -Properties @{
            reportId = $ReportId
            error    = $_.Exception.Message
        }
        return $false
    }
}

#endregion

Export-ModuleMember -Function @(
    'Write-DeploymentLog'
    'Connect-PowerBIWithServicePrincipal'
    'Disconnect-PowerBISession'
    'Get-OrCreateWorkspace'
    'Test-PremiumCapacity'
    'Publish-PowerBIReport'
    'Publish-PaginatedReport'
    'Update-ReportDatasourceCredentials'
    'Update-ReportDataset'
    'Test-ReportDeployment'
)
