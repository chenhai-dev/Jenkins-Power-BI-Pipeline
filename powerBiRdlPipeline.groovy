import org.manulife.powerbi.PipelineConfig

/**
 * Shared Library step: powerBiRdlPipeline()
 *
 * Usage in consumer Jenkinsfile:
 *   @Library('powerbi-shared-lib') _
 *   powerBiRdlPipeline()
 */
def call() {
    pipeline {
        agent {
            docker {
                image "artifactory.ap.manulife.com/docker/ubuntu-ci-image:1.11.0"
                args  '-u devops:docker --privileged -v /app/maven/.m2:/home/devops/.m2 -v /var/run/docker.sock:/var/run/docker.sock'
            }
        }

        options {
            timestamps()
            buildDiscarder(logRotator(numToKeepStr: '30'))
            timeout(time: 60, unit: 'MINUTES')
        }

        environment {
            POWERBI_MARKET = 'KH-D2C'
        }

        parameters {
            // ── Deployment target ──────────────────────────────────────────
            string(
                name:         'PowerBI_Apps',
                defaultValue: '',
                description:  'Application code (e.g. CAS, LIFE). Used to locate the RDL folder: <MARKET>-<APP>/<ENV>/'
            )
            string(
                name:         'PowerBI_Env',
                defaultValue: '',
                description:  'Power BI environment / workspace sub-folder (e.g. KH_REP_SIT02_EDB)'
            )
            string(
                name:         'Group_ID_Env',
                defaultValue: '',
                description:  'Power BI Workspace (Group) ID — GUID from the workspace URL'
            )

            // ── ODBC datasource binding ─────────────────────────────────────
            string(
                name:         'Find_String',
                defaultValue: '',
                description:  'ODBC connection string to find inside the RDL file XML'
            )
            string(
                name:         'Replace_String',
                defaultValue: '',
                description:  'ODBC connection string to write in its place (also used for Power BI datasource binding)'
            )

            // ── Source control ──────────────────────────────────────────────
            string(
                name:         'PowerBI_Repo_URL',
                defaultValue: '',
                description:  'SSH URL of the Git repository containing the RDL files'
            )
            string(
                name:         'Git_Branch',
                defaultValue: '',
                description:  'Branch or tag to deploy (e.g. release/2.0 or refs/tags/v1.0)'
            )

            // ── Security ────────────────────────────────────────────────────
            string(
                name:         'SPN_Credential_ID',
                defaultValue: 'AZ_SPN_KH_PAS_NONPROD',
                description:  'Jenkins credential ID for the Azure SPN (username=client_id, password=client_secret). Tenant ID credential must be named <ID>_TENANT_ID'
            )

            // ── Behaviour ───────────────────────────────────────────────────
            booleanParam(
                name:         'ALLOW_REPLACE_EXISTING_RDL',
                defaultValue: false,
                description:  'Allow overwriting existing reports. The report ID may change after overwrite.'
            )
            booleanParam(
                name:         'DRY_RUN',
                defaultValue: false,
                description:  'Validate pipeline setup and RDL discovery without uploading any files to Power BI.'
            )

            // ── Notification ────────────────────────────────────────────────
            string(
                name:         'Mail_Builder',
                defaultValue: '',
                description:  'Comma-separated list of email addresses to notify after deployment'
            )
        }

        stages {

            stage('Initialization') {
                steps {
                    script {
                        // Derive market from the first folder segment of the job name
                        def jobParts = (env.JOB_NAME ?: '').tokenize('/')
                        env.POWERBI_MARKET = jobParts ? jobParts[0] : env.POWERBI_MARKET

                        // Build and validate config — fails fast with clear error if params are blank
                        def cfg = PipelineConfig.fromParams(params, env)
                        cfg.validate()

                        env.CFG_CHECKOUT_DIR = cfg.checkoutDir

                        currentBuild.displayName = cfg.getBuildDisplayName(env.BUILD_NUMBER)

                        echo cfg.toDisplayString()
                    }
                }
            }

            stage('Checkout Repo') {
                steps {
                    script {
                        def gitRef     = params.Git_Branch.trim()
                        def branchSpec = gitRef.startsWith('refs/') ? gitRef : "*/${gitRef}"

                        checkout([
                            $class: 'GitSCM',
                            branches: [[name: branchSpec]],
                            userRemoteConfigs: [[
                                url:           params.PowerBI_Repo_URL,
                                credentialsId: 'DevSecOps_SCM_SSH_CLONE_PRIVATE_KEY'
                            ]],
                            extensions: [
                                [$class: 'CleanBeforeCheckout'],
                                [$class: 'RelativeTargetDirectory', relativeTargetDir: env.CFG_CHECKOUT_DIR]
                            ]
                        ])
                    }
                }
            }

            stage('Deploy Power BI RDL') {
                steps {
                    script {
                        def cfg = PipelineConfig.fromParams(params, env)

                        withCredentials([
                            usernamePassword(
                                credentialsId:    cfg.spnCredentialId,
                                usernameVariable: 'PBI_APP_ID',
                                passwordVariable: 'PBI_APP_SECRET'
                            ),
                            string(
                                credentialsId: cfg.tenantCredentialId,
                                variable:      'PBI_TENANT_ID'
                            )
                        ]) {
                            def deployScript = libraryResource 'scripts/deploy-rdl.ps1'

                            withEnv(cfg.toEnvVars()) {
                                pwsh(label: 'Deploy RDL Reports', script: deployScript)
                            }
                        }
                    }
                }

                post {
                    always {
                        echo '-------- Power BI RDL deployment stage end --------'
                    }
                }
            }

        }

        post {
            always {
                script {
                    currentBuild.description = "[${params.PowerBI_Apps}] ${params.PowerBI_Env} → ${currentBuild.currentResult}"
                }

                archiveArtifacts(
                    artifacts:         'report-id-comparison-summary.csv,report-id-comparison-summary.json',
                    allowEmptyArchive: true,
                    fingerprint:       true
                )

                script {
                    def dryRunBadge = params.DRY_RUN
                        ? '<span style="color:#e67e00;font-weight:bold">[DRY RUN — no files were uploaded]</span><br/><br/>'
                        : ''

                    emailext(
                        to:      params.Mail_Builder,
                        subject: "[PowerBI RDL] ${env.JOB_NAME} #${env.BUILD_NUMBER} — ${currentBuild.currentResult}",
                        body: """\
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;font-size:14px;color:#333">

  <h2 style="color:${currentBuild.currentResult == 'SUCCESS' ? '#1a7a1a' : '#c0392b'}">
    Power BI RDL Deployment — ${currentBuild.currentResult}
  </h2>

  ${dryRunBadge}

  <table style="border-collapse:collapse;width:100%;max-width:640px">
    <tr><td style="padding:4px 8px;font-weight:bold;width:160px">Job</td>
        <td style="padding:4px 8px">${env.JOB_NAME}</td></tr>
    <tr style="background:#f5f5f5">
        <td style="padding:4px 8px;font-weight:bold">Build</td>
        <td style="padding:4px 8px"><a href="${env.BUILD_URL}">#${env.BUILD_NUMBER}</a></td></tr>
    <tr><td style="padding:4px 8px;font-weight:bold">Market</td>
        <td style="padding:4px 8px">${env.POWERBI_MARKET}</td></tr>
    <tr style="background:#f5f5f5">
        <td style="padding:4px 8px;font-weight:bold">App</td>
        <td style="padding:4px 8px">${params.PowerBI_Apps}</td></tr>
    <tr><td style="padding:4px 8px;font-weight:bold">Environment</td>
        <td style="padding:4px 8px">${params.PowerBI_Env}</td></tr>
    <tr style="background:#f5f5f5">
        <td style="padding:4px 8px;font-weight:bold">Workspace ID</td>
        <td style="padding:4px 8px">${params.Group_ID_Env}</td></tr>
    <tr><td style="padding:4px 8px;font-weight:bold">Branch</td>
        <td style="padding:4px 8px">${params.Git_Branch}</td></tr>
    <tr style="background:#f5f5f5">
        <td style="padding:4px 8px;font-weight:bold">Allow Replace</td>
        <td style="padding:4px 8px">${params.ALLOW_REPLACE_EXISTING_RDL}</td></tr>
  </table>

  <br/>
  <p>The full deployment log is attached. The <b>report-id-comparison-summary.csv</b> artifact
     lists every RDL file with its before/after report ID and status.</p>

  <p style="color:#888;font-size:12px">This is an automated message — do not reply.</p>
</body>
</html>""",
                        mimeType:           'text/html',
                        attachLog:          true,
                        attachmentsPattern: 'report-id-comparison-summary.csv,report-id-comparison-summary.json'
                    )
                }
            }
        }
    }
}
