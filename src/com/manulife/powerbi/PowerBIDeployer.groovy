package com.manulife.powerbi

/**
 * Stage implementation for pipelineJavaPowerBI_KH.
 *
 * Each public method corresponds to one pipeline stage. The constructor
 * receives a reference to the calling pipeline script so that we can use
 * pipeline steps (powershell, libraryResource, writeFile, error, echo, etc.)
 * from inside this CPS-friendly class.
 *
 * Design notes:
 *   - PowerShell scripts are loaded as library resources (versioned with the
 *     shared library) and written to the agent workspace before invocation.
 *   - We never echo secrets. credentials() bindings are masked by Jenkins.
 *   - Every method is idempotent so a re-run produces the same outcome.
 */
class PowerBIDeployer implements Serializable {

    private static final long serialVersionUID = 1L

    private final def script           // pipeline 'this'
    private final PowerBIDeploymentConfig cfg
    private static final String SCRIPT_BASE = 'com/manulife/powerbi/scripts'

    PowerBIDeployer(def script, PowerBIDeploymentConfig cfg) {
        this.script = script
        this.cfg = cfg
    }

    // -----------------------------------------------------------------------
    // Stage: Prepare workspace, load env config from resources, write to disk
    // -----------------------------------------------------------------------
    void prepareWorkspace() {
        script.echo "Power BI Deployment — ${cfg}"
        script.echo "Credential prefix: ${cfg.credentialPrefix}"
        script.echo "Config resource  : ${cfg.configResourcePath}"

        script.powershell '''
            New-Item -ItemType Directory -Force -Path "$env:BUILD_ARTIFACTS_DIR" | Out-Null
            "Build #$env:BUILD_NUMBER for $env:JOB_NAME" | Tee-Object -FilePath $env:DEPLOY_LOG
        '''

        // Load env-specific config JSON from library resources, write to agent
        String configJson
        try {
            configJson = script.libraryResource(cfg.configResourcePath)
        } catch (Exception e) {
            script.error """
                Could not load config resource: ${cfg.configResourcePath}

                Each (appName, targetEnv) pair needs a JSON file at:
                  resources/${cfg.configResourcePath}

                Cause: ${e.message}
            """.stripIndent()
        }

        script.writeFile(file: 'artifacts/config-' + script.env.BUILD_NUMBER + '.json', text: configJson)

        // Capture workspaceId for downstream stages and notifications
        def parsed = script.readJSON(text: configJson)
        cfg.workspaceId = parsed.workspaceId
        if (!cfg.workspaceId) {
            script.error "Config file ${cfg.configResourcePath} is missing required 'workspaceId' field"
        }
        script.echo "Resolved workspaceId: ${cfg.workspaceId}"
    }

    // -----------------------------------------------------------------------
    // Stage: Static validation of .rdl / .pbix files
    // -----------------------------------------------------------------------
    void validateReports() {
        runPowerShellResource('Validate-PowerBIReports.ps1', [
            ReportFolder: cfg.reportFolder,
            LogPath:      script.env.DEPLOY_LOG
        ])
    }

    // -----------------------------------------------------------------------
    // Stage: SP authentication
    // -----------------------------------------------------------------------
    void authenticate() {
        // We pass credentials as positional args via the powershell step's env binding,
        // not as command-line arguments — keeps them out of process listing on the agent.
        String script_text = script.libraryResource("${SCRIPT_BASE}/Connect-PowerBIServicePrincipal.ps1")
        String localPath = "scripts/Connect-PowerBIServicePrincipal.ps1"
        script.writeFile(file: localPath, text: script_text)

        script.powershell """
            \$ErrorActionPreference = 'Stop'
            & ".\\${localPath}" `
                -TenantId     \$env:AZURE_TENANT_ID `
                -ClientId     \$env:PBI_CLIENT_ID `
                -ClientSecret \$env:PBI_CLIENT_SECRET
        """
    }

    // -----------------------------------------------------------------------
    // Stage: Pre-deploy snapshot (PROD only)
    // -----------------------------------------------------------------------
    void snapshot() {
        runPowerShellResource('Backup-PowerBIWorkspace.ps1', [
            WorkspaceId:  cfg.workspaceId,
            OutputFolder: "${script.env.BUILD_ARTIFACTS_DIR}\\backup",
            LogPath:      script.env.DEPLOY_LOG
        ])
    }

    // -----------------------------------------------------------------------
    // Stage: Publish reports
    // -----------------------------------------------------------------------
    void deploy() {
        runPowerShellResource('Deploy-PowerBIReport.ps1', [
            ReportFolder:   cfg.reportFolder,
            ConfigFile:     script.env.CONFIG_FILE,
            RebindDataset:  cfg.rebindDataset.toString(),
            DryRun:         cfg.dryRun.toString(),
            LogPath:        script.env.DEPLOY_LOG
        ])
    }

    // -----------------------------------------------------------------------
    // Stage: Trigger and poll dataset refresh
    // -----------------------------------------------------------------------
    void refreshDatasets() {
        runPowerShellResource('Refresh-PowerBIDataset.ps1', [
            ConfigFile:        script.env.CONFIG_FILE,
            LogPath:           script.env.DEPLOY_LOG,
            WaitForCompletion: 'true',
            TimeoutMinutes:    '30'
        ])
    }

    // -----------------------------------------------------------------------
    // Stage: Post-deploy verification
    // -----------------------------------------------------------------------
    void verify() {
        runPowerShellResource('Test-PowerBIDeployment.ps1', [
            ConfigFile:   script.env.CONFIG_FILE,
            ReportFolder: cfg.reportFolder,
            LogPath:      script.env.DEPLOY_LOG
        ])
    }

    // -----------------------------------------------------------------------
    // Always-run cleanup
    // -----------------------------------------------------------------------
    void cleanup() {
        // Don't error inside cleanup — this runs in the post.always block
        try {
            script.powershell '''
                try {
                    Disconnect-PowerBIServiceAccount -ErrorAction SilentlyContinue
                    Write-Host "Disconnected from Power BI Service"
                } catch {
                    Write-Host "No active session to disconnect"
                }
            '''
        } catch (Exception e) {
            script.echo "WARN: cleanup failed: ${e.message}"
        }
    }

    // -----------------------------------------------------------------------
    // Helper: load a PS1 resource and execute it with named parameters.
    //
    // We materialize the script onto the agent rather than piping it via
    // -Command so that PowerShell error line numbers remain meaningful and
    // the script appears in the workspace for post-mortem inspection.
    // -----------------------------------------------------------------------
    private void runPowerShellResource(String scriptName, Map params) {
        String content = script.libraryResource("${SCRIPT_BASE}/${scriptName}")
        String localPath = "scripts/${scriptName}"
        script.writeFile(file: localPath, text: content)

        // Build named-parameter string (-Key Value -Key Value ...).
        // PowerShell quoting: single-quote everything to avoid $ expansion of values.
        // If a value contains a single quote, escape by doubling it.
        StringBuilder sb = new StringBuilder()
        params.each { entry ->
            String safe = entry.value.toString().replace("'", "''")
            sb.append("-").append(entry.key).append(" '").append(safe).append("' ")
        }
        String paramString = sb.toString().trim()

        script.powershell """
            \$ErrorActionPreference = 'Stop'
            & ".\\${localPath}" ${paramString}
        """
    }
}
