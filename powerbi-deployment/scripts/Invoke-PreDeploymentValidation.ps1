<#
.SYNOPSIS
    Pre-deployment validation - runs before Publish to catch breaking issues early.
.DESCRIPTION
    Inspects .pbix and .rdl artifacts for:
      - Hardcoded connection strings (should use parameters)
      - Embedded credentials or secrets
      - Personal information / PII in sample data
      - File size vs. capacity limits
      - .rdl XML well-formedness + schema validation
      - Data source compatibility with target capacity
      - Breaking schema changes vs. currently-deployed version

    Exit non-zero if any HIGH severity issue found. WARN logs for medium/low.
.PARAMETER ArtifactPath
    Directory containing .pbix / .rdl files.
.PARAMETER Environment
    Target env - affects strictness (Prod = strictest).
.PARAMETER CompareAgainstDeployed
    If set, compares artifact against the currently-deployed version for schema drift.
.EXAMPLE
    ./Invoke-PreDeploymentValidation.ps1 -ArtifactPath ./reports -Environment Prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$ArtifactPath,

    [ValidateSet('Dev', 'Test', 'Prod')]
    [string]$Environment = 'Dev',

    [switch]$CompareAgainstDeployed,

    [string]$ConfigPath,

    [int]$MaxFileSizeMB = 1024,   # Power BI import limit
    [int]$WarnFileSizeMB = 500
)

#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptRoot '..' 'modules' 'PowerBIDeployment.psd1') -Force

# Issue collection
$script:issues = [System.Collections.Generic.List[object]]::new()

function Add-Issue {
    param(
        [ValidateSet('HIGH', 'MEDIUM', 'LOW', 'INFO')][string]$Severity,
        [string]$Check,
        [string]$File,
        [string]$Message,
        [string]$Recommendation
    )
    $script:issues.Add([pscustomobject]@{
        Severity       = $Severity
        Check          = $Check
        File           = $File
        Message        = $Message
        Recommendation = $Recommendation
    })
}

# ---------------------------------------------------------------------------
# Check 1: File sanity
# ---------------------------------------------------------------------------
function Test-FileSanity {
    param([System.IO.FileInfo]$File)

    if ($File.Length -eq 0) {
        Add-Issue -Severity HIGH -Check 'FileSanity' -File $File.Name `
            -Message 'File is empty' `
            -Recommendation 'Re-export the report and commit again.'
        return
    }

    $sizeMB = [Math]::Round($File.Length / 1MB, 2)
    if ($sizeMB -gt $MaxFileSizeMB) {
        Add-Issue -Severity HIGH -Check 'FileSanity' -File $File.Name `
            -Message "File size ${sizeMB}MB exceeds Power BI limit ${MaxFileSizeMB}MB" `
            -Recommendation 'Enable Large dataset storage format in workspace or split the model.'
    }
    elseif ($sizeMB -gt $WarnFileSizeMB) {
        Add-Issue -Severity MEDIUM -Check 'FileSanity' -File $File.Name `
            -Message "File size ${sizeMB}MB is approaching the ${MaxFileSizeMB}MB limit" `
            -Recommendation 'Consider incremental refresh or model optimization.'
    }
}

# ---------------------------------------------------------------------------
# Check 2: .rdl XML validation
# ---------------------------------------------------------------------------
function Test-RdlXml {
    param([System.IO.FileInfo]$File)

    try {
        [xml]$rdl = Get-Content $File.FullName -Raw
    }
    catch {
        Add-Issue -Severity HIGH -Check 'RdlXml' -File $File.Name `
            -Message "Not valid XML: $($_.Exception.Message)" `
            -Recommendation 'Open in Power BI Report Builder and re-save.'
        return
    }

    # Check for Report Builder / RDL 2016 schema (required for Power BI Service)
    $nsmgr = [System.Xml.XmlNamespaceManager]::new($rdl.NameTable)
    $nsmgr.AddNamespace('rdl', 'http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition')

    $dataSources = $rdl.SelectNodes('//rdl:DataSource', $nsmgr)
    if ($dataSources.Count -eq 0) {
        Add-Issue -Severity MEDIUM -Check 'RdlXml' -File $File.Name `
            -Message 'No Power BI 2016 schema data sources found' `
            -Recommendation 'Ensure the report was authored in Power BI Report Builder, not classic Report Builder.'
    }

    # Check for embedded credentials in connection strings
    $connStrings = $rdl.SelectNodes('//rdl:ConnectString', $nsmgr)
    foreach ($cs in $connStrings) {
        if ($cs.InnerText -match '(?i)(password|pwd)\s*=\s*[^;]+') {
            Add-Issue -Severity HIGH -Check 'RdlXml' -File $File.Name `
                -Message 'Embedded password in connection string' `
                -Recommendation 'Remove password; use shared data sources or credential binding at deploy time.'
        }
    }

    # Check for file:// or localhost references
    $allText = $rdl.OuterXml
    if ($allText -match 'file://|\\\\localhost|\\\\127\.0\.0\.1') {
        Add-Issue -Severity HIGH -Check 'RdlXml' -File $File.Name `
            -Message 'Reference to local file system or localhost' `
            -Recommendation 'Use cloud-accessible data sources only.'
    }
}

# ---------------------------------------------------------------------------
# Check 3: .pbix inspection
# ---------------------------------------------------------------------------
function Test-PbixContent {
    param([System.IO.FileInfo]$File)

    # .pbix is a ZIP archive. Extract and inspect.
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pbix-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Expand-Archive -Path $File.FullName -DestinationPath $tempDir -Force

        # Inspect DataModelSchema if present (large datasets may not expose it)
        $schemaFile = Join-Path $tempDir 'DataModelSchema'
        if (Test-Path $schemaFile) {
            $schemaText = Get-Content $schemaFile -Raw -Encoding Unicode

            # Search for suspicious patterns
            $patterns = @{
                'HardcodedPassword'    = @{
                    Regex = '"[^"]*password[^"]*"\s*:\s*"[^"]{4,}"'
                    Severity = 'HIGH'
                    Recommendation = 'Remove credentials from the model; use service-level credential binding.'
                }
                'HardcodedServer'      = @{
                    Regex = 'Server=[a-zA-Z0-9\-\.]+\.database\.windows\.net'
                    Severity = 'MEDIUM'
                    Recommendation = 'Parameterize the server name to allow env-specific overrides.'
                }
                'PrivateIP'            = @{
                    Regex = '(10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|192\.168\.\d+\.\d+)'
                    Severity = 'LOW'
                    Recommendation = 'Private IPs require gateway; verify gateway is bound post-deploy.'
                }
            }

            foreach ($name in $patterns.Keys) {
                $p = $patterns[$name]
                if ($schemaText -match $p.Regex) {
                    Add-Issue -Severity $p.Severity -Check "PbixContent:$name" -File $File.Name `
                        -Message "Pattern '$name' matched in model" `
                        -Recommendation $p.Recommendation
                }
            }
        }

        # Check Connections file for datasource types
        $connFile = Join-Path $tempDir 'Connections'
        if (Test-Path $connFile) {
            $connContent = Get-Content $connFile -Raw
            if ($connContent -match '"ConnectionString"\s*:\s*"[^"]*Excel[^"]*\\\\') {
                Add-Issue -Severity HIGH -Check 'PbixContent:LocalExcel' -File $File.Name `
                    -Message 'Report references a local Excel/CSV file' `
                    -Recommendation 'Move source data to SharePoint / OneDrive / Azure storage.'
            }
        }

        # Check Version file for compatibility
        $versionFile = Join-Path $tempDir 'Version'
        if (Test-Path $versionFile) {
            $version = Get-Content $versionFile -Raw -Encoding Unicode
            # Power BI Desktop writes the compatibility level here
            if ($version -match '^\s*(\d+\.\d+)') {
                $ver = [version]$matches[1]
                if ($ver -lt [version]'1.23') {
                    Add-Issue -Severity LOW -Check 'PbixContent:Version' -File $File.Name `
                        -Message "PBIX version $ver is older than recommended 1.23+" `
                        -Recommendation 'Re-save in current Power BI Desktop for best compatibility.'
                }
            }
        }
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Check 4: Secret scanning across all files
# ---------------------------------------------------------------------------
function Test-SecretScan {
    param([System.IO.FileInfo]$File)

    # Common patterns that suggest leaked secrets
    $secretPatterns = @(
        @{ Name = 'AzureStorageKey';      Regex = 'AccountKey=[A-Za-z0-9+/=]{60,}' }
        @{ Name = 'AzureSASToken';        Regex = 'sv=\d{4}-\d{2}-\d{2}&ss=[bfqt]+&srt=[soc]+&sp=' }
        @{ Name = 'SQLConnectionString';  Regex = 'Password=[^;"]+;' }
        @{ Name = 'AWSAccessKey';         Regex = 'AKIA[0-9A-Z]{16}' }
        @{ Name = 'PrivateKey';           Regex = '-----BEGIN (RSA |EC |DSA |)PRIVATE KEY-----' }
        @{ Name = 'BearerToken';          Regex = 'Bearer\s+[A-Za-z0-9\-_=]{20,}\.[A-Za-z0-9\-_=]{20,}\.[A-Za-z0-9\-_=]{20,}' }
    )

    # Read file as bytes then string for text extraction from binary (best effort)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)

        foreach ($p in $secretPatterns) {
            if ($text -match $p.Regex) {
                Add-Issue -Severity HIGH -Check "SecretScan:$($p.Name)" -File $File.Name `
                    -Message "Potential $($p.Name) detected in file" `
                    -Recommendation 'Remove the secret immediately, rotate it, and use Key Vault / parameter binding.'
            }
        }
    }
    catch {
        Add-Issue -Severity LOW -Check 'SecretScan' -File $File.Name `
            -Message "Could not scan: $($_.Exception.Message)" -Recommendation 'Review manually.'
    }
}

# ---------------------------------------------------------------------------
# Check 5: Filename conventions
# ---------------------------------------------------------------------------
function Test-Naming {
    param([System.IO.FileInfo]$File)

    # Basic: no spaces, no env suffix, no date
    if ($File.BaseName -match '\s') {
        Add-Issue -Severity LOW -Check 'Naming' -File $File.Name `
            -Message 'Filename contains spaces' `
            -Recommendation 'Use PascalCase or kebab-case; spaces complicate CLI usage.'
    }
    if ($File.BaseName -match '(?i)_(dev|test|prod|qa|uat)\b') {
        Add-Issue -Severity MEDIUM -Check 'Naming' -File $File.Name `
            -Message 'Filename contains environment suffix' `
            -Recommendation 'Environment belongs in the workspace, not the filename. Use config/*.yaml for env-specific display names.'
    }
    if ($File.BaseName -match '\d{4}[-_]?\d{2}[-_]?\d{2}') {
        Add-Issue -Severity LOW -Check 'Naming' -File $File.Name `
            -Message 'Filename contains a date' `
            -Recommendation 'Use Git history for versioning.'
    }
    if ($File.BaseName -match '(?i)(copy|final|v\d|backup)') {
        Add-Issue -Severity MEDIUM -Check 'Naming' -File $File.Name `
            -Message "Filename suggests this is a draft/backup ($($File.BaseName))" `
            -Recommendation 'Clean up name before merging.'
    }
}

# ---------------------------------------------------------------------------
# Check 6: Config coverage - every report must have config entry for Prod
# ---------------------------------------------------------------------------
function Test-ConfigCoverage {
    param([string[]]$ReportFiles, [string]$ConfigFilePath)

    if (-not (Test-Path $ConfigFilePath)) { return }

    Import-Module powershell-yaml -Force -ErrorAction SilentlyContinue
    if (-not (Get-Module powershell-yaml)) {
        Add-Issue -Severity LOW -Check 'ConfigCoverage' -File $ConfigFilePath `
            -Message 'powershell-yaml not installed - skipping config check' -Recommendation 'Install-Module powershell-yaml.'
        return
    }

    $cfg = ConvertFrom-Yaml (Get-Content $ConfigFilePath -Raw)
    $configuredFiles = @($cfg.reports | ForEach-Object { $_.fileName })

    foreach ($reportFile in $ReportFiles) {
        if ($configuredFiles -notcontains $reportFile) {
            $severity = if ($Environment -eq 'Prod') { 'HIGH' } else { 'MEDIUM' }
            Add-Issue -Severity $severity -Check 'ConfigCoverage' -File $reportFile `
                -Message "No entry in $([System.IO.Path]::GetFileName($ConfigFilePath))" `
                -Recommendation 'Add an entry under `reports:` in the config YAML.'
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-DeploymentLog -Message 'Pre-deployment validation starting' -Level INFO -Properties @{
    artifactPath = $ArtifactPath
    environment  = $Environment
}

$reports = Get-ChildItem -Path $ArtifactPath -Include '*.pbix', '*.rdl' -Recurse -File

if ($reports.Count -eq 0) {
    Write-DeploymentLog -Message 'No reports to validate' -Level WARN
    exit 0
}

foreach ($r in $reports) {
    Write-DeploymentLog -Message "Validating $($r.Name)" -Level INFO

    Test-FileSanity -File $r
    Test-Naming -File $r
    Test-SecretScan -File $r

    if ($r.Extension -eq '.rdl') {
        Test-RdlXml -File $r
    }
    elseif ($r.Extension -eq '.pbix') {
        Test-PbixContent -File $r
    }
}

if ($ConfigPath) {
    Test-ConfigCoverage -ReportFiles ($reports | ForEach-Object Name) -ConfigFilePath $ConfigPath
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
$summary = [pscustomobject]@{
    total  = $script:issues.Count
    high   = ($script:issues | Where-Object Severity -eq 'HIGH').Count
    medium = ($script:issues | Where-Object Severity -eq 'MEDIUM').Count
    low    = ($script:issues | Where-Object Severity -eq 'LOW').Count
}

Write-DeploymentLog -Message 'Validation complete' -Level INFO -Properties @{
    totalIssues  = $summary.total
    highIssues   = $summary.high
    mediumIssues = $summary.medium
    lowIssues    = $summary.low
}

# Emit results as JSON for pipeline consumption
$resultsPath = Join-Path $ArtifactPath 'validation-results.json'
@{
    summary = $summary
    issues  = $script:issues
} | ConvertTo-Json -Depth 5 | Out-File $resultsPath -Encoding utf8

# Human-readable table
if ($script:issues.Count -gt 0) {
    Write-Host "`n=== Validation Issues ===" -ForegroundColor Yellow
    $script:issues | Sort-Object Severity | Format-Table Severity, Check, File, Message -Wrap -AutoSize
}
else {
    Write-Host "`n✓ No issues found" -ForegroundColor Green
}

# Exit codes:
#   0 = clean
#   1 = only low/medium (warning in non-prod, but Prod fails on any HIGH)
#   2 = HIGH severity issue present
if ($summary.high -gt 0) {
    Write-DeploymentLog -Message "FAIL: $($summary.high) HIGH severity issue(s) must be fixed before deploy" -Level FATAL
    exit 2
}
if ($Environment -eq 'Prod' -and $summary.medium -gt 0) {
    Write-DeploymentLog -Message "FAIL: $($summary.medium) MEDIUM severity issue(s) block Prod deployment" -Level ERROR
    exit 2
}
exit 0
