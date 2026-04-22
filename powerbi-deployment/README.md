# Power BI Report Deployment Pipeline

Enterprise-grade CI/CD for deploying Power BI reports (`.pbix` and `.rdl` paginated) to Power BI Service workspaces backed by Premium / Premium-Per-User / Fabric capacity.

## Scope

A PowerShell-based deployment framework wired into Azure DevOps and GitHub Actions. It handles:

- Deployment of `.pbix` and `.rdl` through Dev → Test → Prod with approval gates
- Infrastructure provisioning via Bicep (Key Vault, Log Analytics, backup storage)
- Pre-deployment validation (secret scanning, size limits, schema checks, naming)
- Nightly backup of the live Power BI estate for DR
- Scheduled health monitoring with metrics in Prometheus / JSON format
- Rollback via redeployment of retained artifacts
- Full operational + security documentation

## Repository layout

```
powerbi-deployment/
├── modules/
│   ├── PowerBIDeployment.psd1              # Module manifest
│   └── PowerBIDeployment.psm1              # Core reusable functions
├── scripts/
│   ├── Deploy-PowerBIReport.ps1            # Main orchestrator
│   ├── Rollback-PowerBIReport.ps1          # Rollback via prior artifact
│   ├── Invoke-PreDeploymentValidation.ps1  # Pre-flight checks (secret scan, etc.)
│   ├── backup/
│   │   └── Backup-PowerBIWorkspace.ps1     # DR backup of live workspace
│   └── monitoring/
│       └── Get-PowerBIHealth.ps1           # Health metrics emitter
├── infrastructure/
│   ├── main.bicep                          # Bicep: KV, Log Analytics, Storage, alerts
│   ├── dev.bicepparam
│   ├── test.bicepparam
│   └── prod.bicepparam
├── pipelines/
│   ├── azure-pipelines.yml                 # Deploy pipeline (ADO)
│   ├── azure-pipelines-scheduled.yml       # Nightly backup + health check (ADO)
│   ├── github-actions.yml                  # Deploy workflow (GH)
│   ├── github-actions-scheduled.yml        # Scheduled workflow (GH)
│   ├── Jenkinsfile                         # Deploy pipeline (Jenkins)
│   └── Jenkinsfile.scheduled               # Scheduled pipeline (Jenkins)
├── config/
│   ├── dev.yaml
│   ├── test.yaml
│   └── prod.yaml
├── tests/
│   ├── PowerBIDeployment.Tests.ps1         # Unit tests
│   └── integration/
│       └── Integration.Tests.ps1           # Integration tests (real PBI workspace)
├── docs/
│   ├── SETUP.md                            # One-time infrastructure setup
│   ├── OPERATIONS.md                       # Day-to-day runbook
│   ├── ARCHITECTURE.md                     # Design decisions
│   ├── TROUBLESHOOTING.md                  # Common failures
│   ├── SECURITY.md                         # Security hardening checklist
│   └── runbooks/
│       ├── PRODUCTION-DEPLOYMENT.md        # Step-by-step Prod deploy
│       └── DISASTER-RECOVERY.md            # DR scenarios & procedures
└── README.md
```

## Key features

- **Both report types**: `.pbix` (standard) and `.rdl` (paginated) via the imports REST API
- **Premium capacity verification**: fails fast if workspace isn't Premium/PPU/Fabric
- **Service principal auth** with Azure Key Vault for secrets; OIDC federation for GitHub
- **Idempotent**: `CreateOrOverwrite` semantics; safe to re-run
- **Parameterized**: env-specific SQL servers / database names injected at deploy time
- **Datasource credential binding**: automatically sets basic-auth creds post-publish
- **Gated promotion**: approval required before Test and Prod
- **Pre-deployment validation**: catches embedded secrets, oversized files, bad naming, and missing config before deploy
- **Nightly backups**: full workspace metadata + `.pbix`/`.rdl` export to versioned blob storage
- **Continuous health monitoring**: metrics in JSON/Prometheus format with SLA checks
- **Rollback**: redeploy of a prior retained artifact (30-day retention)
- **Observability**: structured JSON logs, correlation IDs, deployment summary JSON, Log Analytics integration

## Quickstart

### First-time setup

```bash
# 1. Provision infrastructure (per environment)
az deployment group create \
    --resource-group rg-analytics-prod \
    --template-file infrastructure/main.bicep \
    --parameters infrastructure/prod.bicepparam

# 2. Follow docs/SETUP.md for SP registration, tenant settings, KV secrets

# 3. Commit a .pbix/.rdl to reports/ and push
```

### Local deployment (dev)

```powershell
# Validate without deploying
./scripts/Deploy-PowerBIReport.ps1 `
    -Environment Dev `
    -ArtifactPath ./reports `
    -DryRun

# Full deploy
./scripts/Deploy-PowerBIReport.ps1 `
    -Environment Dev `
    -ArtifactPath ./reports
```

### Pre-flight check before committing

```powershell
./scripts/Invoke-PreDeploymentValidation.ps1 `
    -ArtifactPath ./reports `
    -Environment Prod `
    -ConfigPath ./config/prod.yaml
```

### Health check

```powershell
./scripts/monitoring/Get-PowerBIHealth.ps1 -Environment Prod -OutputFormat table
```

## Documentation map

| Doc | Purpose |
|-----|---------|
| [`docs/SETUP.md`](docs/SETUP.md) | One-time infrastructure setup |
| [`docs/JENKINS-SETUP.md`](docs/JENKINS-SETUP.md) | Jenkins-specific setup (alternative to ADO/GH) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | Day-to-day operational runbook |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Design decisions and rationale |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Security hardening checklist |
| [`docs/runbooks/PRODUCTION-DEPLOYMENT.md`](docs/runbooks/PRODUCTION-DEPLOYMENT.md) | Step-by-step Prod release |
| [`docs/runbooks/DISASTER-RECOVERY.md`](docs/runbooks/DISASTER-RECOVERY.md) | DR procedures for each failure mode |

## Support

- On-call: `#data-platform-oncall` Slack channel (PagerDuty `data-platform`)
- Owner: Data Platform / DevOps
- SLAs:
  - Prod deployment: executes within 15 min of approval
  - Rollback RTO: 30 min
  - Full-workspace DR RTO: 2 h
  - Backup RPO: 24 h

## Contributing

- Branch from `main`; PRs require 2 approvals from CODEOWNERS
- All changes must pass PSScriptAnalyzer, Pester unit tests, and pre-deployment validation
- Integration tests run against a dedicated Dev workspace and require the `PBI_TEST_*` env vars
- Secrets never committed; pre-commit hook with gitleaks recommended locally
