package com.manulife.powerbi

/**
 * Validates and normalizes input arguments to pipelineJavaPowerBI_KH.
 *
 * Fails fast (before allocating an agent) on missing / invalid inputs so
 * consuming app teams get a clear error in the Jenkins console rather than
 * an obscure PowerShell stack trace 30 seconds later.
 */
class PowerBIDeploymentConfig implements Serializable {

    private static final long serialVersionUID = 1L

    // ---- Required ----
    String targetEnv          // DEV | TEST | UAT | PROD
    String appName            // e.g. 'KH-D2C' — used in log/email subjects + credential namespace

    // ---- Optional with defaults ----
    String reportFolder       = 'reports'
    String agentLabel         = 'windows-powerbi'
    String credentialPrefix   = null      // defaults to "pbi-${appName.toLowerCase()}-${targetEnv.toLowerCase()}"
    String configResourcePath = null      // defaults to "com/manulife/powerbi/config/${appName}-${targetEnv}.json"
    Integer timeoutMinutes    = 45
    Boolean rebindDataset     = true
    Boolean refreshDataset    = false
    Boolean dryRun            = false

    // ---- Notification recipients ----
    String notifyOnSuccess    = '$DEFAULT_RECIPIENTS'
    String notifyOnFailure    = '$DEFAULT_RECIPIENTS'

    // ---- Workspace metadata (resolved from config JSON at runtime, not at construction time) ----
    String workspaceId        = null   // populated by PowerBIDeployer after loading the config

    PowerBIDeploymentConfig(Map args) {
        // Use Map.with-style assignment but explicitly so unknown keys raise
        def known = [
            'targetEnv', 'appName', 'reportFolder', 'agentLabel',
            'credentialPrefix', 'configResourcePath', 'timeoutMinutes',
            'rebindDataset', 'refreshDataset', 'dryRun',
            'notifyOnSuccess', 'notifyOnFailure'
        ] as Set

        def unknown = args.keySet() - known
        if (unknown) {
            throw new IllegalArgumentException(
                "Unknown pipelineJavaPowerBI_KH argument(s): ${unknown.join(', ')}. " +
                "Known arguments: ${known.sort().join(', ')}"
            )
        }

        args.each { k, v -> this[k] = v }
    }

    void validate() {
        def errors = []

        // Required
        if (!targetEnv) {
            errors << "targetEnv is required"
        } else if (!(targetEnv in ['DEV', 'TEST', 'UAT', 'PROD'])) {
            errors << "targetEnv must be one of DEV/TEST/UAT/PROD, got '${targetEnv}'"
        }

        if (!appName) {
            errors << "appName is required (e.g. 'KH-D2C')"
        } else if (!(appName ==~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/)) {
            errors << "appName must be alphanumeric/dash/underscore, got '${appName}'"
        }

        // Reasonable bounds
        if (timeoutMinutes < 5 || timeoutMinutes > 240) {
            errors << "timeoutMinutes must be between 5 and 240, got ${timeoutMinutes}"
        }

        if (errors) {
            throw new IllegalArgumentException(
                "Invalid arguments to pipelineJavaPowerBI_KH:\n  - " + errors.join("\n  - ")
            )
        }

        // Apply derived defaults after validation passes
        if (!credentialPrefix) {
            credentialPrefix = "pbi-${appName.toLowerCase()}-${targetEnv.toLowerCase()}"
        }
        if (!configResourcePath) {
            configResourcePath = "com/manulife/powerbi/config/${appName}-${targetEnv}.json"
        }
    }

    @Override
    String toString() {
        "PowerBIDeploymentConfig(app=${appName}, env=${targetEnv}, " +
        "reports=${reportFolder}, dryRun=${dryRun}, refresh=${refreshDataset})"
    }
}
