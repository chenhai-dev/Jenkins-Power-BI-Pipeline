pipeline {
	agent {

	}

	options {
		timestamps()
	}

	environment {

	}

	parameters {

	}

	stages {

		stage('Initialization') {
			steps {
				script {
					def jobParts = (env.JOB_NAME ?: '').tokenize('/')
					env.POWERBI_MARKET = jobParts ? jobParts[0] : env.POWERBI_MARKET
					env.TARGET_ENV = jobParts.size() >= 2 ? jobParts[1] : ''
					currentBuild.displayName = "#${env.BUILD_NUMBER}_${env.POWERBI_MARKET}_${params.PowerBI_Apps}"

					echo "Job Name   : ${env.JOB_NAME}"
					echo "Market     : ${env.POWERBI_MARKET}"
					echo "Target Env : ${env.TARGET_ENV}"
				}
			}
		}

		stage('Checkout Repo') {
			steps {
				script {
					def gitRef = params.Git_Branch.trim()
					def branchSpec = gitRef.startsWith('refs/') ? gitRef : "*/${gitRef}"
					def targetDir = "${env.POWERBI_MARKET}-${params.PowerBI_Apps}/${params.PowerBI_Env}"

					checkout([
						$class: 'GitSCM',
						branches: [[name: branchSpec]],
						userRemoteConfigs: [[
							url:           params.PowerBI_Repo_URL,
							credentialsId: 'DevSecOps_SCM_SSH_CLONE_PRIVATE_KEY'
						]],
						extensions: [
							[$class: 'CleanBeforeCheckout'],
							[$class: 'RelativeTargetDirectory', relativeTargetDir: targetDir]
						]
					])
				}
			}
		}

		stage('Deploy Power BI RDL') {
			steps {
				withCredentials([
					usernamePassword(
						credentialsId:    'AZ_SPN_KH_PAS_NONPROD',
						usernameVariable: 'PBI_APP_ID',
						passwordVariable: 'PBI_APP_SECRET'
					),
					string(
						credentialsId: 'AZ_SPN_KH_PAS_NONPROD_TENANT_ID',
						variable:      'PBI_TENANT_ID'
					)
				]) {
					pwsh(
						label: 'Deploy RDL Reports',
						script: """
\$ErrorActionPreference = 'Stop'

#--------------------------------
# Config from Jenkins
#--------------------------------
\$cfg = @{
    Market        = '${env.POWERBI_MARKET}'
    App           = '${params.PowerBI_Apps}'
    Env           = '${params.PowerBI_Env}'
    GroupId       = '${params.Group_ID_Env}'
    FindString    = '${params.Find_String}'
    ReplaceString = '${params.Replace_String}'
    AllowReplace  = '${params.ALLOW_REPLACE_EXISTING_RDL.toString().toLowerCase()}'
}

#--------------------------------
# Helper Functions
#--------------------------------
function Write-Section([string]\$title) {
    Write-Host ""
    Write-Host "========== \$title =========="
}

function Get-AccessToken {
    \$tokenUri = "https://login.microsoftonline.com/\$env:PBI_TENANT_ID/oauth2/v2.0/token"
    \$body = @{
        client_id     = \$env:PBI_APP_ID
        client_secret = \$env:PBI_APP_SECRET
        scope         = 'https://analysis.windows.net/powerbi/api/.default'
        grant_type    = 'client_credentials'
    }

    \$token = Invoke-RestMethod -Method Post -Uri \$tokenUri -Body \$body -ContentType 'application/x-www-form-urlencoded'
    if ([string]::IsNullOrWhiteSpace(\$token.access_token)) {
        throw "Failed to get Azure AD token."
    }

    return @{
        Authorization = 'Bearer ' + \$token.access_token
    }
}

function Get-WorkspaceReports([string]\$groupId, [hashtable]\$headers) {
    \$url = "https://api.powerbi.com/v1.0/myorg/groups/\$groupId/reports"
    \$res = Invoke-RestMethod -Method Get -Uri \$url -Headers \$headers
    if (\$null -eq \$res -or \$null -eq \$res.value) { return @() }
    return @(\$res.value)
}

function Find-ExistingReport([object[]]\$reports, [string]\$fileName) {
    \$baseName = [System.IO.Path]::GetFileNameWithoutExtension(\$fileName)
    return \$reports |
        Where-Object {
            \$_.name -eq \$baseName -or
            \$_.name -eq \$fileName
        } |
        Select-Object -First 1
}

function Get-ImportUrl([string]\$groupId, [string]\$fileName, [string]\$mode) {
    \$displayName = [System.Uri]::EscapeDataString([System.IO.Path]::GetFileNameWithoutExtension(\$fileName))
    return "https://api.powerbi.com/v1.0/myorg/groups/\$groupId/imports?datasetDisplayName=\$displayName&nameConflict=\$mode"
}

function Write-RestError([string]\$context, \$err) {
    Write-Host "ERROR CONTEXT: \$context"

    if (\$err.Exception -and \$err.Exception.Message) {
        Write-Host "ERROR: Exception Message:"
        Write-Host \$err.Exception.Message
    }

    if (\$err.ErrorDetails -and \$err.ErrorDetails.Message) {
        Write-Host "ERROR: ErrorDetails.Message:"
        Write-Host \$err.ErrorDetails.Message
    }

    # Try HTTP status code if available
    try {
        if (\$err.Exception.Response -and \$err.Exception.Response.StatusCode) {
            Write-Host "ERROR: HTTP Status Code: \$([int]\$err.Exception.Response.StatusCode)"
        }
    }
    catch {
        Write-Host "ERROR: Unable to read HTTP status code from exception response."
    }

    # Try HttpResponseMessage-style content (PowerShell 7)
    try {
        if (\$err.Exception.Response -and \$err.Exception.Response.Content) {
            \$rawBody = \$err.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not [string]::IsNullOrWhiteSpace(\$rawBody)) {
                Write-Host "ERROR: Raw Response Body (HttpResponseMessage):"
                Write-Host \$rawBody
            }
        }
    }
    catch {
        Write-Host "ERROR: Unable to read HttpResponseMessage content."
    }

    # Try WebException-style response stream
    try {
        if (\$err.Exception.Response -and \$err.Exception.Response.GetResponseStream) {
            \$stream = \$err.Exception.Response.GetResponseStream()
            if (\$stream) {
                \$reader = New-Object System.IO.StreamReader(\$stream)
                \$body   = \$reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace(\$body)) {
                    Write-Host "ERROR: Raw Response Body (ResponseStream):"
                    Write-Host \$body
                }
            }
        }
    }
    catch {
        Write-Host "ERROR: Unable to read response stream body."
    }

    try {
        if (\$err.ScriptStackTrace) {
            Write-Host "ERROR: ScriptStackTrace:"
            Write-Host \$err.ScriptStackTrace
        }
    }
    catch {
        Write-Host "ERROR: Unable to read ScriptStackTrace."
    }
}

function Wait-ImportDone([string]\$groupId, [string]\$importId, [hashtable]\$headers) {
    \$url = "https://api.powerbi.com/v1.0/myorg/groups/\$groupId/imports/\$importId"
    for (\$i = 1; \$i -le 60; \$i++) {
        try {
            \$res = Invoke-RestMethod -Method Get -Uri \$url -Headers \$headers
            Write-Host "Poll \$i"
            Write-Host "Import ID: \$importId"
            Write-Host "State     : \$(\$res.importState)"

            if (\$res.importState -eq 'Succeeded') { return \$res }

            if (\$res.importState -eq 'Failed') {
                \$code = if (\$res.error -and \$res.error.code) { \$res.error.code } else { 'Unknown' }
                throw ('Import failed. Import ID: ' + \$importId + [Environment]::NewLine + 'ErrorCode: ' + \$code)
            }
        }
        catch {
            Write-Host "ERROR: Polling import failed."
            Write-Host "ERROR: Import ID : \$importId"
            Write-Host "ERROR: Poll URL  : \$url"
            Write-RestError "Wait-ImportDone for Import ID \$importId" \$_
            throw
        }

        Start-Sleep -Seconds 5
    }

    throw "Import timeout. Import ID: \$importId"
}

function Import-RdlFile([string]\$groupId, [string]\$fileName, [string]\$fullPath, [string]\$mode, [hashtable]\$headers) {
    \$importUrl = Get-ImportUrl -groupId \$groupId -fileName \$fileName -mode \$mode
    Write-Host "Import URL  : \$importUrl"
    Write-Host "Import Mode : \$mode"
    Write-Host "Import File : \$fullPath"

    try {
        \$importPost = Invoke-RestMethod -Method Post -Uri \$importUrl -Headers \$headers -Form @{ value = Get-Item -LiteralPath \$fullPath }

        if (-not \$importPost.id) {
            throw "Import did not return Import ID for file: \$fileName"
        }

        return [string]\$importPost.id
    }
    catch {
        Write-Host "ERROR: Import failed for file: \$fileName"
        Write-Host "ERROR: URL : \$importUrl"
        Write-RestError "Import-RdlFile for \$fileName" \$_
        throw
    }
}

function Get-ReportDatasources([string]\$groupId, [string]\$reportId, [hashtable]\$headers) {
    \$url = "https://api.powerbi.com/v1.0/myorg/groups/\$groupId/reports/\$reportId/datasources"
    \$res = Invoke-RestMethod -Method Get -Uri \$url -Headers \$headers
    if (\$null -eq \$res -or \$null -eq \$res.value) { return @() }
    return @(\$res.value)
}

function Update-ReportDatasources([string]\$groupId, [string]\$reportId, [string]\$replaceString, [hashtable]\$headers) {
    \$datasources = Get-ReportDatasources -groupId \$groupId -reportId \$reportId -headers \$headers

    if (-not \$datasources -or \$datasources.Count -eq 0) {
        Write-Host "No datasources found for report ID: \$reportId"
        return
    }

    Write-Host "Found \$(\$datasources.Count) datasource(s) — updating connection string to: \$replaceString"

    \$updateDetails = @(foreach (\$ds in \$datasources) {
        Write-Host "  Datasource: \$(\$ds.name) | Type: \$(\$ds.datasourceType) | Current: \$(\$ds.connectionDetails.connectionString)"
        @{
            datasourceName     = \$ds.name
            connectionDetails  = @{ connectionString = \$replaceString }
            datasourceSelector = @{
                datasourceType    = \$ds.datasourceType
                connectionDetails = @{ connectionString = \$ds.connectionDetails.connectionString }
            }
        }
    })

    \$body = @{ updateDetails = \$updateDetails } | ConvertTo-Json -Depth 10
    \$url  = "https://api.powerbi.com/v1.0/myorg/groups/\$groupId/reports/\$reportId/Default.UpdateDatasources"

    try {
        Invoke-RestMethod -Method Post -Uri \$url -Headers \$headers -Body \$body -ContentType 'application/json'
        Write-Host "Datasource updated successfully for report ID: \$reportId"
    }
    catch {
        Write-RestError "Update-ReportDatasources for report ID \$reportId" \$_
        throw
    }
}

function Apply-OdbcConnectionReplace([string]\$fullPath, [string]\$findString, [string]\$replaceString) {
    if ([string]::IsNullOrWhiteSpace(\$findString)) {
        Write-Host "ODBC Find_String is empty. No ODBC connection replacement applied for: \$fullPath"
        return \$false
    }

    \$content = Get-Content -LiteralPath \$fullPath -Raw
    \$updated = \$content.Replace(\$findString, \$replaceString)

    if (\$updated -ne \$content) {
        Set-Content -LiteralPath \$fullPath -Value \$updated -Encoding utf8
        Write-Host "ODBC connection string updated in RDL: \$fullPath"
        return \$true
    }

    Write-Host "No ODBC connection string change needed in RDL: \$fullPath"
    return \$false
}

#--------------------------------
# Resolve local RDL path
#--------------------------------
Write-Section 'Runtime Info'
\$PSVersionTable | Out-String | Write-Host

\$basePath = Join-Path \$env:WORKSPACE ("\$(\$cfg.Market)-\$(\$cfg.App)")
\$rdlPath  = Join-Path \$basePath \$cfg.Env

Write-Host "Market        : \$(\$cfg.Market)"
Write-Host "App           : \$(\$cfg.App)"
Write-Host "Environment   : \$(\$cfg.Env)"
Write-Host "Workspace ID  : \$(\$cfg.GroupId)"
Write-Host "Workspace Path: \$env:WORKSPACE"
Write-Host "RDL Path      : \$rdlPath"

if (-not (Test-Path -LiteralPath \$rdlPath)) {
    throw "RDL path not found: \$rdlPath"
}

\$rdlFiles = Get-ChildItem -LiteralPath \$rdlPath -Filter '*.rdl' -File
if (-not \$rdlFiles -or \$rdlFiles.Count -eq 0) {
    throw "No .rdl files found in: \$rdlPath"
}

#--------------------------------
# Auth
#--------------------------------
Write-Section 'Authentication'
\$headers = Get-AccessToken
Write-Host 'Successfully acquired access token.'

#--------------------------------
# Show RDL files with existing report info
#--------------------------------
\$workspaceReports = Get-WorkspaceReports -groupId \$cfg.GroupId -headers \$headers

\$rdlFileReportView = foreach (\$file in \$rdlFiles) {
    \$existing = Find-ExistingReport -reports \$workspaceReports -fileName \$file.Name

    [PSCustomObject]@{
        Name               = \$file.Name
        Length             = \$file.Length
        LastWriteTime      = \$file.LastWriteTime
        ExistingReportName = if (\$existing) { \$existing.name } else { '' }
        ExistingReportId   = if (\$existing) { \$existing.id }   else { '' }
    }
}

Write-Section 'RDL Files'
\$rdlFileReportView |
    Format-Table Name, Length, LastWriteTime, ExistingReportName, ExistingReportId -AutoSize |
    Out-String |
    Write-Host

#--------------------------------
# Deploy each RDL and compare report ID before vs after
#--------------------------------
Write-Section 'Deployment Start'
\$deploymentResults = @()

foreach (\$file in \$rdlFiles) {
    \$fileName         = \$file.Name
    \$reportLookupName = [System.IO.Path]::GetFileNameWithoutExtension(\$file.Name)
    \$fullPath         = \$file.FullName

    Write-Host ""
    Write-Host "------ Processing: \$fileName ------"
    Write-Host "Lookup Report Name: \$reportLookupName"

    # Refresh reports before each deployment
    \$reportsBefore   = Get-WorkspaceReports -groupId \$cfg.GroupId -headers \$headers
    \$existing        = Find-ExistingReport -reports \$reportsBefore -fileName \$fileName

    \$beforeReportId   = if (\$existing) { [string]\$existing.id }   else { '' }
    \$beforeReportName = if (\$existing) { [string]\$existing.name } else { '' }
    \$afterReportId    = ''
    \$afterReportName  = ''
    \$idCompareStatus  = ''

    if (\$existing) {
        Write-Host "Existing report found"
        Write-Host "Name          : \$fileName"
        Write-Host "Matched Name  : \$(\$existing.name)"
        Write-Host "Target Report ID: \$(\$existing.id)"

        if (\$cfg.AllowReplace -eq 'true') {
            Write-Host "ALLOW_REPLACE_EXISTING_RDL=true"
            Write-Host "Applying ODBC Find/Replace to local RDL before overwrite import."
            Write-Host "WARNING: Existing report will be overwritten by import and report ID may change."

            Apply-OdbcConnectionReplace -fullPath \$fullPath -findString \$cfg.FindString -replaceString \$cfg.ReplaceString

            \$importId = Import-RdlFile -groupId \$cfg.GroupId -fileName \$fileName -fullPath \$fullPath -mode 'Overwrite' -headers \$headers
            Write-Host "Overwrite Import ID: \$importId"

            if (\$importId -notmatch '^[0-9a-fA-F-]{36}\$') {
                throw "Invalid overwrite Import ID returned: \$importId"
            }

            \$importResult = Wait-ImportDone -groupId \$cfg.GroupId -importId \$importId -headers \$headers
            if (-not \$importResult.reports -or \$importResult.reports.Count -eq 0) {
                throw "Overwrite import did not return report metadata for file: \$fileName"
            }

            \$report          = \$importResult.reports | Select-Object -First 1
            \$afterReportId   = [string]\$report.id
            \$afterReportName = [string]\$report.name

            if ([string]::IsNullOrWhiteSpace(\$beforeReportId)) {
                \$idCompareStatus = 'NO_EXISTING_REPORT_FOUND_BEFORE_DEPLOY'
            }
            elseif (\$beforeReportId -eq \$afterReportId) {
                \$idCompareStatus = 'UNCHANGED'
            }
            else {
                \$idCompareStatus = 'CHANGED'
            }

            Write-Host "Updating datasource connection after overwrite import..."
            Update-ReportDatasources -groupId \$cfg.GroupId -reportId \$afterReportId -replaceString \$cfg.ReplaceString -headers \$headers

            Write-Host "Overwrite completed."
            Write-Host "Final Report Name  : \$afterReportName"
            Write-Host "Final Report ID    : \$afterReportId"
            Write-Host "Before Report Name : \$beforeReportName"
            Write-Host "Before Report ID   : \$beforeReportId"
            Write-Host "ID Compare Result  : \$idCompareStatus"
        }
        else {
            throw "Existing report uses ODBC datasource. Keeping the same report ID is not supported through overwrite import. Set ALLOW_REPLACE_EXISTING_RDL=true to enable overwrite."
        }
    }
    else {
        Write-Host "New report detected"
        Write-Host "Applying ODBC Find/Replace to local RDL before first import."

        Apply-OdbcConnectionReplace -fullPath \$fullPath -findString \$cfg.FindString -replaceString \$cfg.ReplaceString

        \$importId = Import-RdlFile -groupId \$cfg.GroupId -fileName \$fileName -fullPath \$fullPath -mode 'Abort' -headers \$headers
        Write-Host "Import ID: \$importId"

        if (\$importId -notmatch '^[0-9a-fA-F-]{36}\$') {
            throw "Invalid Import ID returned: \$importId"
        }

        \$importResult = Wait-ImportDone -groupId \$cfg.GroupId -importId \$importId -headers \$headers
        if (-not \$importResult.reports -or \$importResult.reports.Count -eq 0) {
            throw "Import did not return report metadata for new file: \$fileName"
        }

        \$newReport       = \$importResult.reports | Select-Object -First 1
        \$afterReportId   = [string]\$newReport.id
        \$afterReportName = [string]\$newReport.name

        if ([string]::IsNullOrWhiteSpace(\$beforeReportId)) {
            \$idCompareStatus = 'NEW_REPORT_CREATED'
        }
        elseif (\$beforeReportId -eq \$afterReportId) {
            \$idCompareStatus = 'UNCHANGED'
        }
        else {
            \$idCompareStatus = 'CHANGED'
        }

        Write-Host "Updating datasource connection after new import..."
        Update-ReportDatasources -groupId \$cfg.GroupId -reportId \$afterReportId -replaceString \$cfg.ReplaceString -headers \$headers

        Write-Host "New Report Name    : \$afterReportName"
        Write-Host "New Report ID      : \$afterReportId"
        Write-Host "Before Report Name : \$beforeReportName"
        Write-Host "Before Report ID   : \$beforeReportId"
        Write-Host "ID Compare Result  : \$idCompareStatus"
    }

    \$deploymentResults += [PSCustomObject]@{
        FileName         = \$fileName
        BeforeReportName = \$beforeReportName
        BeforeReportId   = \$beforeReportId
        AfterReportName  = \$afterReportName
        AfterReportId    = \$afterReportId
        IdCompareStatus  = \$idCompareStatus
    }
}

Write-Section 'Report ID Comparison Summary'
\$deploymentResults |
    Format-Table FileName, BeforeReportName, BeforeReportId, AfterReportName, AfterReportId, IdCompareStatus -AutoSize |
    Out-String |
    Write-Host

#--------------------------------
# Export summary files
#--------------------------------
\$csvPath  = Join-Path \$env:WORKSPACE 'report-id-comparison-summary.csv'
\$jsonPath = Join-Path \$env:WORKSPACE 'report-id-comparison-summary.json'

\$deploymentResults |
    Select-Object FileName, BeforeReportName, BeforeReportId, AfterReportName, AfterReportId, IdCompareStatus |
    Export-Csv -LiteralPath \$csvPath -NoTypeInformation -Encoding UTF8

\$deploymentResults |
    Select-Object FileName, BeforeReportName, BeforeReportId, AfterReportName, AfterReportId, IdCompareStatus |
    ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath \$jsonPath -Encoding UTF8

Write-Host "CSV summary exported : \$csvPath"
Write-Host "JSON summary exported: \$jsonPath"

Write-Section 'Deployment Complete'
Write-Host 'All RDL files processed successfully.'
"""
					)
				}
			}

			echo '-------- Power BI paginated reports deployment end --------'
		}

	}

	post {
		always {
			script {
				emailext(
					to:      params.Mail_Builder,
					subject: "[PowerBI Build] ${env.JOB_NAME} - #${env.BUILD_NUMBER} - ${currentBuild.currentResult}",
					body:    """<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>${env.JOB_NAME}-${env.BUILD_NUMBER} Build Log</title>
</head>
<body>
    <p>Hi team, this is an automated Power BI deployment notification.</p>
    <hr/>
    <ul>
        <li><b>Project:</b> ${env.JOB_NAME}</li>
        <li><b>Build #:</b> ${env.BUILD_NUMBER}</li>
        <li><b>Status:</b> ${currentBuild.currentResult}</li>
        <li><b>URL:</b> <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></li>
    </ul>
</body>
</html>""",
					mimeType:            'text/html',
					attachLog:           true,
					attachmentsPattern:  'report-id-comparison-summary.csv,report-id-comparison-summary.json'
				)
			}
		}
	}
}
