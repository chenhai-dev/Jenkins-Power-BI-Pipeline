// vars/pipelineJavaPowerBI_KH.groovy
//
// Shared library entry point for deploying Power BI reports (.rdl, .pbix)
// to Power BI Service Premium / PPU workspaces.
//
// Usage from a consuming Jenkinsfile:
//
//   @Library('eng-jenkins-pipeline-lib@feature/powerbi-pipeline') _
//
//   pipelineJavaPowerBI_KH(
//       targetEnv:    params.TARGET_ENV ?: 'DEV',
//       reportFolder: 'reports',
//       appName:      'KH-D2C',
//       dryRun:       params.DRY_RUN ?: false
//   )
//
// All parameters are validated by PowerBIDeploymentConfig.groovy (src/).
// All deployment logic is delegated to PowerShell scripts loaded from resources/.
// The Groovy layer stays thin — orchestration, credential binding, error
// surfacing, notifications. No business logic in here.

import com.manulife.powerbi.PowerBIDeploymentConfig
import com.manulife.powerbi.PowerBIDeployer

def call(Map args = [:]) {

    // -----------------------------------------------------------------------
    // 1. Validate inputs (fast-fail before allocating an agent)
    // -----------------------------------------------------------------------
    PowerBIDeploymentConfig cfg = new PowerBIDeploymentConfig(args)
    cfg.validate()

    // -----------------------------------------------------------------------
    // 2. Pipeline shell
    // -----------------------------------------------------------------------
    pipeline {
        agent {
            label cfg.agentLabel  // default: 'windows-powerbi'
        }

        options {
            timeout(time: cfg.timeoutMinutes, unit: 'MINUTES')
            timestamps()
            ansiColor('xterm')
            buildDiscarder(logRotator(
                numToKeepStr: '30',
                artifactNumToKeepStr: '10'
            ))
            disableConcurrentBuilds()
        }

        environment {
            // Bind credentials from Jenkins credential store
            AZURE_TENANT_ID   = credentials("${cfg.credentialPrefix}-tenant-id")
            PBI_CLIENT_ID     = credentials("${cfg.credentialPrefix}-client-id")
            PBI_CLIENT_SECRET = credentials("${cfg.credentialPrefix}-client-secret")

            // Pipeline-scoped paths
            BUILD_ARTIFACTS_DIR = "${WORKSPACE}\\artifacts"
            DEPLOY_LOG          = "${WORKSPACE}\\artifacts\\deploy-${BUILD_NUMBER}.log"
            CONFIG_FILE         = "${WORKSPACE}\\artifacts\\config-${BUILD_NUMBER}.json"
        }

        stages {

            stage('Prepare') {
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).prepareWorkspace()
                    }
                }
            }

            stage('Validate Reports') {
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).validateReports()
                    }
                }
            }

            stage('Authenticate') {
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).authenticate()
                    }
                }
            }

            stage('Pre-Deploy Snapshot') {
                when {
                    expression { cfg.targetEnv == 'PROD' && !cfg.dryRun }
                }
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).snapshot()
                    }
                }
                post {
                    success {
                        archiveArtifacts(
                            artifacts: 'artifacts/backup/**/*',
                            allowEmptyArchive: true,
                            fingerprint: true
                        )
                    }
                }
            }

            stage('Deploy') {
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).deploy()
                    }
                }
            }

            stage('Refresh Datasets') {
                when {
                    expression { cfg.refreshDataset && !cfg.dryRun }
                }
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).refreshDatasets()
                    }
                }
            }

            stage('Verify') {
                when {
                    expression { !cfg.dryRun }
                }
                steps {
                    script {
                        new PowerBIDeployer(this, cfg).verify()
                    }
                }
            }
        }

        post {
            always {
                script {
                    // Always disconnect — never leave a token in agent memory
                    new PowerBIDeployer(this, cfg).cleanup()
                }
                archiveArtifacts(
                    artifacts: 'artifacts/**/*.log,artifacts/**/*.json',
                    allowEmptyArchive: true
                )
            }

            success {
                script {
                    if (cfg.targetEnv == 'PROD' && !cfg.dryRun) {
                        emailext(
                            subject: "Power BI Deploy SUCCESS — ${cfg.appName} → ${cfg.targetEnv} — Build #${BUILD_NUMBER}",
                            body: """
                                Power BI deployment to ${cfg.targetEnv} completed successfully.

                                App        : ${cfg.appName}
                                Workspace  : ${cfg.workspaceId}
                                Build      : ${BUILD_URL}
                                Git commit : ${env.GIT_COMMIT ?: 'n/a'}
                            """.stripIndent(),
                            to: cfg.notifyOnSuccess,
                            recipientProviders: [culprits(), requestor()]
                        )
                    }
                }
            }

            failure {
                emailext(
                    subject: "Power BI Deploy FAILURE — ${cfg.appName} → ${cfg.targetEnv} — Build #${BUILD_NUMBER}",
                    body: """
                        Power BI deployment to ${cfg.targetEnv} FAILED.

                        App     : ${cfg.appName}
                        Build   : ${BUILD_URL}
                        Console : ${BUILD_URL}console
                    """.stripIndent(),
                    to: cfg.notifyOnFailure,
                    recipientProviders: [culprits(), requestor(), brokenBuildSuspects()],
                    attachLog: true
                )
            }

            cleanup {
                // Scrub any sensitive temp files
                powershell '''
                    Get-ChildItem -Path $env:WORKSPACE -Include *.pbix.bak,*.tmp -Recurse -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                '''
            }
        }
    }
}
