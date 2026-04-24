package org.manulife.powerbi

/**
 * Holds, validates, and exposes all Power BI RDL pipeline parameters.
 *
 * Implements Serializable so Jenkins Pipeline CPS can safely checkpoint
 * an instance across stage boundaries.
 */
class PipelineConfig implements Serializable {

    private static final long serialVersionUID = 1L

    // Deployment target
    String market
    String app
    String env
    String groupId

    // ODBC datasource binding
    String findString
    String replaceString

    // Source control
    String repoUrl
    String branch

    // Security
    String spnCredentialId

    // Behaviour
    boolean allowReplace
    boolean dryRun

    // Notification
    String mailBuilder

    // -----------------------------------------------------------------------
    // Factory
    // -----------------------------------------------------------------------

    /**
     * Build a PipelineConfig from Jenkins pipeline params + env.
     *
     * Call inside a script{} block:
     *   def cfg = PipelineConfig.fromParams(params, env)
     */
    static PipelineConfig fromParams(def params, def jenkinsEnv) {
        def cfg          = new PipelineConfig()
        cfg.market       = jenkinsEnv.POWERBI_MARKET ?: 'UNKNOWN'
        cfg.app          = params.PowerBI_Apps?.trim()      ?: ''
        cfg.env          = params.PowerBI_Env?.trim()       ?: ''
        cfg.groupId      = params.Group_ID_Env?.trim()      ?: ''
        cfg.findString   = params.Find_String?.trim()       ?: ''
        cfg.replaceString= params.Replace_String?.trim()    ?: ''
        cfg.repoUrl      = params.PowerBI_Repo_URL?.trim()  ?: ''
        cfg.branch       = params.Git_Branch?.trim()        ?: ''
        cfg.spnCredentialId = params.SPN_Credential_ID?.trim() ?: 'AZ_SPN_KH_PAS_NONPROD'
        cfg.allowReplace = params.ALLOW_REPLACE_EXISTING_RDL as boolean
        cfg.dryRun       = params.DRY_RUN as boolean
        cfg.mailBuilder  = params.Mail_Builder?.trim()      ?: ''
        return cfg
    }

    // -----------------------------------------------------------------------
    // Validation
    // -----------------------------------------------------------------------

    /**
     * Throws IllegalArgumentException listing every blank required field.
     * Call early in Initialization to surface problems before any checkout.
     */
    void validate() {
        def required = [
            'PowerBI_Apps'     : app,
            'PowerBI_Env'      : env,
            'Group_ID_Env'     : groupId,
            'PowerBI_Repo_URL' : repoUrl,
            'Git_Branch'       : branch,
            'SPN_Credential_ID': spnCredentialId
        ]
        def blank = required.findAll { k, v -> !v }.keySet()
        if (blank) {
            throw new IllegalArgumentException(
                "Required pipeline parameters are blank: ${blank.join(', ')}"
            )
        }
    }

    // -----------------------------------------------------------------------
    // Derived values
    // -----------------------------------------------------------------------

    /** Jenkins credential ID for the Tenant ID secret text. */
    String getTenantCredentialId() {
        return "${spnCredentialId}_TENANT_ID"
    }

    /** Checkout target directory relative to WORKSPACE. */
    String getCheckoutDir() {
        return "${market}-${app}/${env}"
    }

    /** Build display name for the Jenkins build list. */
    String getBuildDisplayName(String buildNumber) {
        return "#${buildNumber} | ${market} | ${app} | ${env}"
    }

    /** Environment variable list passed to the PowerShell deployment script. */
    List<String> toEnvVars() {
        return [
            "PBI_APP=${app}",
            "PBI_ENV=${env}",
            "PBI_GROUP_ID=${groupId}",
            "PBI_FIND_STRING=${findString}",
            "PBI_REPLACE_STRING=${replaceString}",
            "PBI_ALLOW_REPLACE=${allowReplace.toString().toLowerCase()}",
            "PBI_DRY_RUN=${dryRun.toString().toLowerCase()}"
        ]
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    /** Safe log — omits any secret values. */
    String toDisplayString() {
        return """\
Market        : ${market}
App           : ${app}
Environment   : ${env}
Workspace ID  : ${groupId}
Repo URL      : ${repoUrl}
Branch        : ${branch}
SPN Cred ID   : ${spnCredentialId}
Allow Replace : ${allowReplace}
Dry Run       : ${dryRun}
Mail Builder  : ${mailBuilder}"""
    }
}
