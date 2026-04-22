# Changelog

All notable changes to this project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

## [1.0.0] — Initial release

### Added

#### Deployment
- Core PowerShell module `PowerBIDeployment` with functions for service-principal auth, workspace management, `.pbix` and `.rdl` publish (dual-path: cmdlet for `.pbix`, REST multipart for `.rdl`), datasource credential binding, parameter updates, and smoke tests
- Main orchestration script `Deploy-PowerBIReport.ps1` with Dev/Test/Prod support, Key Vault secret fetching, Premium capacity verification, dry-run mode, and summary JSON output
- Rollback script `Rollback-PowerBIReport.ps1` using artifact redeployment
- Pre-deployment validation `Invoke-PreDeploymentValidation.ps1` with file sanity, secret scanning (Azure Storage keys, SAS tokens, AWS keys, JWTs, private keys, SQL connection strings), `.rdl` XML validation, `.pbix` model inspection, naming conventions, and config coverage checks

#### Pipelines
- Azure DevOps pipeline (`azure-pipelines.yml`) — validate → Dev → Test → Prod with approval gates
- GitHub Actions workflow (`github-actions.yml`) — OIDC federation, environment-based approvals
- Scheduled pipelines (ADO + GH) for nightly backup (02:00 UTC) and every-15-min health check

#### Infrastructure
- Bicep template (`infrastructure/main.bicep`) provisioning Key Vault (RBAC, private networking, purge protection for Prod), Log Analytics workspace (quota-capped, env-specific retention), Storage account (GRS Prod, versioning, lifecycle rules, hot→cool→archive tiering), diagnostic settings, action group, and Key Vault unauthorized-access alert
- Per-environment parameter files

#### Operations
- Nightly backup script exporting `.pbix` via `Export-PowerBIReport`, `.rdl` via REST, workspace manifest with datasets, refresh schedules, datasource bindings (structure only), and workspace ACL
- Health check script emitting metrics in JSON / Prometheus / table formats, covering workspace state, Premium capacity, dataset refresh success, refresh age (SLA), refresh duration, and recent failure count
- Exit-code semantics: healthy (0) / degraded (1) / unhealthy (2) for cron alerting

#### Testing
- Pester unit tests covering logging, file-type validation, config integrity, and secret-leakage regression
- Integration tests (gated on `PBI_TEST_*` env vars) covering auth, workspace access, `.pbix` + `.rdl` publish, idempotency, and error handling
- Minimal RDL fixture for integration tests

#### Developer experience
- Pre-commit hooks: generic hygiene, gitleaks, detect-secrets, PSScriptAnalyzer, Bicep lint, size guard, pre-deployment validation
- Gitleaks custom ruleset tailored for Power BI (embedded passwords, Azure SQL connection strings, PBI tokens, SP secrets)
- detect-secrets baseline
- VS Code workspace settings and extension recommendations
- CODEOWNERS with granular review assignments
- `.gitignore`

#### Documentation
- `README.md` — project overview
- `CONTRIBUTING.md` — workflow, code style, testing, commit convention
- `docs/SETUP.md` — prerequisites, SP registration, tenant settings, capacity, Key Vault, CI/CD wiring, secret rotation
- `docs/OPERATIONS.md` — deploying, promoting, rollback, refresh, capacity monitoring, on-call procedures
- `docs/ARCHITECTURE.md` — design decisions, data flow, security model, scalability, DR summary, known limitations
- `docs/TROUBLESHOOTING.md` — symptom → cause → fix for auth, workspace/capacity, publish, credentials, parameters, refresh, and pipeline platform issues
- `docs/SECURITY.md` — 10-section hardening checklist (identity, secrets, code, supply chain, network, data protection, audit, monitoring, regulatory, annual review)
- `docs/IMPLEMENTATION-CHECKLIST.md` — phased plan from zero to Prod go-live
- `docs/runbooks/PRODUCTION-DEPLOYMENT.md` — T-24h/T-30m/T-0 procedures, approver checklist, rollback, hotfix
- `docs/runbooks/DISASTER-RECOVERY.md` — five scenarios with RTO/RPO and step-by-step recovery

### Security

- Service principals scoped per environment (Dev/Test/Prod isolation)
- Prod SP granted workspace Member role, not Admin (least privilege)
- All secrets in Azure Key Vault with RBAC authorization, soft-delete, purge protection (Prod)
- OIDC federated credentials supported for GitHub Actions (no long-lived secrets)
- Structured JSON logging never accepts `SecureString`; regression-tested
- Custom gitleaks rules for Power BI-specific secret patterns
- Pre-deployment secret scanning of artifacts before they leave the developer machine
- KQL alert on Key Vault unauthorized access

### Notes

Nothing in this release uses preview Power BI APIs. All dependencies are pinned:
- PowerShell 7.2+
- `MicrosoftPowerBIMgmt` 1.2.1111+
- `Az.KeyVault`, `Az.Storage`, `powershell-yaml` latest stable
- Bicep latest stable
