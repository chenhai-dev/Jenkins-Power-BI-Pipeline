# pipelineJavaPowerBI_KH

Shared-library pipeline for deploying Power BI reports (`.rdl` paginated and
`.pbix` interactive) to Power BI Service workspaces backed by **Premium** or
**Premium-Per-User (PPU)** capacity.

## Quick start

In your app's `Jenkinsfile`:

```groovy
@Library('eng-jenkins-pipeline-lib@feature/powerbi-pipeline') _

pipelineJavaPowerBI_KH(
    targetEnv:    'DEV',
    appName:      'KH-D2C',
    reportFolder: 'reports'
)
```

## Arguments

| Argument            | Required | Default                                                  | Description |
|---------------------|----------|----------------------------------------------------------|-------------|
| `targetEnv`         | Yes      | —                                                        | `DEV` / `TEST` / `UAT` / `PROD` |
| `appName`           | Yes      | —                                                        | Application identifier, e.g. `KH-D2C`. Drives the credential prefix and config-resource lookup. |
| `reportFolder`      | No       | `reports`                                                | Repo-relative folder containing `.rdl` / `.pbix` files |
| `agentLabel`        | No       | `windows-powerbi`                                        | Jenkins agent label |
| `credentialPrefix`  | No       | `pbi-${appName}-${targetEnv}` (lowercase)                | Override if your team shares one SP across envs |
| `configResourcePath`| No       | `com/manulife/powerbi/config/${appName}-${targetEnv}.json` | Override to point at a custom config |
| `timeoutMinutes`    | No       | `45`                                                     | Pipeline-wide timeout (5–240) |
| `rebindDataset`     | No       | `true`                                                   | Rebind `.pbix` reports to env-specific datasets |
| `refreshDataset`    | No       | `false`                                                  | Trigger refresh after deploy |
| `dryRun`            | No       | `false`                                                  | Validate everything without publishing |
| `notifyOnSuccess`   | No       | `$DEFAULT_RECIPIENTS`                                    | Email recipients on PROD success |
| `notifyOnFailure`   | No       | `$DEFAULT_RECIPIENTS`                                    | Email recipients on any failure |

## Required Jenkins credentials

By default the library looks up these credential IDs (Secret Text type),
where the prefix is derived from `appName` and `targetEnv`:

```
pbi-<app>-<env>-tenant-id
pbi-<app>-<env>-client-id
pbi-<app>-<env>-client-secret
```

For `KH-D2C` deploying to `DEV`, that's:

```
pbi-kh-d2c-dev-tenant-id
pbi-kh-d2c-dev-client-id
pbi-kh-d2c-dev-client-secret
```

Override with `credentialPrefix:` if your team shares one SP across environments.

## Required workspace config

For each `(appName, targetEnv)` pair, a JSON config file must exist in this
shared library at:

```
resources/com/manulife/powerbi/config/<appName>-<targetEnv>.json
```

To onboard a new app, open a PR against this library adding the four config
files (DEV/TEST/UAT/PROD) for your app. Sample at `KH-D2C-DEV.json`.

> **Why config lives in the shared library, not the app repo:** Workspace IDs
> are environment infrastructure, not app code. Centralising them in the
> library keeps the inventory in one place where the platform team can audit
> SP membership, capacity assignments, and naming consistency. App teams own
> the `.rdl` / `.pbix` content; the platform team owns where they land.

## Layout

```
eng-jenkins-pipeline-lib/
├── vars/
│   └── pipelineJavaPowerBI_KH.groovy          # Public entry point (the "step")
├── src/com/manulife/powerbi/
│   ├── PowerBIDeploymentConfig.groovy         # Argument validation
│   └── PowerBIDeployer.groovy                 # Stage orchestration
├── resources/com/manulife/powerbi/
│   ├── scripts/                               # PowerShell — versioned with the lib
│   │   ├── Bootstrap-JenkinsAgent.ps1
│   │   ├── Connect-PowerBIServicePrincipal.ps1
│   │   ├── Validate-PowerBIReports.ps1
│   │   ├── Backup-PowerBIWorkspace.ps1
│   │   ├── Deploy-PowerBIReport.ps1
│   │   ├── Refresh-PowerBIDataset.ps1
│   │   └── Test-PowerBIDeployment.ps1
│   └── config/                                # Per-(app, env) workspace metadata
│       ├── KH-D2C-DEV.json
│       ├── KH-D2C-TEST.json
│       ├── KH-D2C-UAT.json
│       └── KH-D2C-PROD.json
├── test/groovy/com/manulife/powerbi/
│   └── PowerBIDeploymentConfigTest.groovy     # Unit tests
└── examples/
    └── Jenkinsfile.kh-d2c                     # Sample consuming Jenkinsfile
```

## Pipeline stages

1. **Prepare** — load env config from library resource, write to agent
2. **Validate Reports** — XML well-formedness, PBIX structure, size limit
3. **Authenticate** — service principal → Azure AD → Power BI REST API
4. **Pre-Deploy Snapshot** *(PROD only, non-dry-run)* — export current reports
5. **Deploy** — publish each report (`CreateOrOverwrite`), rebind, set params
6. **Refresh Datasets** *(when `refreshDataset: true`)* — queue refresh, poll
7. **Verify** — confirm every expected report exists in the workspace
8. **Always-cleanup** — disconnect SP session, scrub temp files

## Local agent setup

Each Windows agent labelled `windows-powerbi` needs a one-time bootstrap.
Either run manually or fold into your golden image:

```powershell
# As Administrator on the agent:
Invoke-WebRequest -Uri 'https://github.mfcgd.com/raw/mfc-innersource/eng-jenkins-pipeline-lib/feature/powerbi-pipeline/resources/com/manulife/powerbi/scripts/Bootstrap-JenkinsAgent.ps1' -OutFile bootstrap.ps1
.\bootstrap.ps1
```

Or use the version stored in this library if your agents pull resources at provisioning time.

## Contributing

* Update `PowerBIDeploymentConfigTest` for any new argument or validation rule
* Run `./gradlew test` before pushing
* Open a PR — the library follows the standard Manulife pipeline-lib review process
* Note: this branch is currently 4734 commits behind master. Rebase before merging.

## See also

* [docs/Power-BI-Deployment-Guide.docx](docs/Power-BI-Deployment-Guide.docx) — full setup & ops guide
* [examples/Jenkinsfile.kh-d2c](examples/Jenkinsfile.kh-d2c) — sample consuming pipeline
