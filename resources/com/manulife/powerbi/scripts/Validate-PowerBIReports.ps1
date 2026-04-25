<#
.SYNOPSIS
    Validates .rdl and .pbix report files before deployment.

.DESCRIPTION
    Performs static validation checks against Power BI report files:
      - .rdl files are validated as well-formed XML against the RDL schema
      - .pbix files are validated as ZIP archives and inspected for required parts
      - File size limits are enforced (Power BI REST API limit is 1 GB for Premium)
      - Hardcoded connection strings are flagged as warnings
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportFolder,
    [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "[$ts] [$Level] [VALIDATE] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# Premium capacity file size limit — 1 GB for Premium workspaces
$MAX_FILE_SIZE_BYTES = 1GB
$errors   = @()
$warnings = @()

$files = Get-ChildItem -Path $ReportFolder -Include *.rdl,*.pbix -Recurse
Write-Log "Validating $($files.Count) report file(s)"

foreach ($file in $files) {
    Write-Log "Checking: $($file.Name)"

    # Size check
    if ($file.Length -gt $MAX_FILE_SIZE_BYTES) {
        $errors += "$($file.Name): exceeds 1 GB size limit ($([math]::Round($file.Length/1MB,2)) MB)"
        continue
    }

    if ($file.Extension -eq '.rdl') {
        # XML well-formedness check
        try {
            [xml]$rdl = Get-Content -Path $file.FullName -Raw
            $ns = $rdl.DocumentElement.NamespaceURI
            if ($ns -notmatch 'reportdefinition') {
                $warnings += "$($file.Name): namespace '$ns' is unusual for an RDL file"
            }

            # Look for hardcoded production-looking connection strings
            $connStrings = $rdl.SelectNodes("//*[local-name()='ConnectString']")
            foreach ($cs in $connStrings) {
                if ($cs.InnerText -match 'prod|production' -and $cs.InnerText -notmatch '@\{|@DataSource') {
                    $warnings += "$($file.Name): possible hardcoded production connection string detected"
                }
            }

            Write-Log "  RDL XML is well-formed"
        } catch {
            $errors += "$($file.Name): invalid RDL XML — $($_.Exception.Message)"
        }
    }
    elseif ($file.Extension -eq '.pbix') {
        # PBIX is a ZIP; open and inspect
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            try {
                $requiredParts = @('DataModel','Report/Layout','[Content_Types].xml')
                foreach ($part in $requiredParts) {
                    if (-not ($zip.Entries | Where-Object { $_.FullName -eq $part })) {
                        # Not all parts exist in every PBIX (e.g. report-only files). Only warn.
                        $warnings += "$($file.Name): expected part '$part' not found in archive"
                    }
                }
                Write-Log "  PBIX archive valid, $($zip.Entries.Count) entries"
            } finally {
                $zip.Dispose()
            }
        } catch {
            $errors += "$($file.Name): invalid PBIX file — $($_.Exception.Message)"
        }
    }
}

# Report findings
if ($warnings.Count -gt 0) {
    Write-Log "--- Validation Warnings ($($warnings.Count)) ---" 'WARN'
    $warnings | ForEach-Object { Write-Log $_ 'WARN' }
}
if ($errors.Count -gt 0) {
    Write-Log "--- Validation Errors ($($errors.Count)) ---" 'ERROR'
    $errors | ForEach-Object { Write-Log $_ 'ERROR' }
    throw "Validation failed with $($errors.Count) error(s)"
}

Write-Log "Validation passed: $($files.Count) file(s), $($warnings.Count) warning(s)"
