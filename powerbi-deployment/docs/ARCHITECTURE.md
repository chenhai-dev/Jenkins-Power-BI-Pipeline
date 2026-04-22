# Architecture

## 1. Overview

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────────┐
│  Developer      │─ push ─▶│  Git Repository  │─trigger▶│  CI/CD Pipeline     │
│  (Power BI      │         │  (Azure Repos /  │         │  (Azure DevOps /    │
│   Desktop /     │         │   GitHub)        │         │   GitHub Actions)   │
│   Report        │         └──────────────────┘         └──────────┬──────────┘
│   Builder)      │                                                  │
└─────────────────┘                                                  │
                                                                     │ OIDC / SP auth
                                                                     ▼
                                              ┌──────────────────────────────────┐
                                              │  Azure Key Vault (per env)       │
                                              │  • SP client secret              │
                                              │  • Datasource credentials        │
                                              └─────────────┬────────────────────┘
                                                            │ fetched at runtime
                                                            ▼
                                              ┌──────────────────────────────────┐
                                              │  Deploy-PowerBIReport.ps1        │
                                              │  • Connect SP                    │
                                              │  • Verify Premium capacity       │
                                              │  • Publish report                │
                                              │  • Bind datasource creds         │
                                              │  • Update parameters             │
                                              │  • Trigger refresh               │
                                              │  • Smoke test                    │
                                              └─────────────┬────────────────────┘
                                                            │ REST API
                                                            ▼
                                        ┌───────────────────────────────────────────┐
                                        │  Power BI Service                         │
                                        │  ┌──────────────────────────────────┐    │
                                        │  │  Workspace (on Premium capacity) │    │
                                        │  │  • Reports (.pbix / .rdl)        │    │
                                        │  │  • Datasets                       │    │
                                        │  └──────────────────────────────────┘    │
                                        └───────────────────────────────────────────┘
```

## 2. Design decisions

### 2.1 Why PowerShell, not Python / TF / Bicep?

The `MicrosoftPowerBIMgmt` module is the only first-party SDK Microsoft ships for Power BI administration. Python and other languages must call the REST API directly, which is workable but duplicates effort. PowerShell 7 is cross-platform, so Linux-based agents run fine.

### 2.2 Why separate `.pbix` and `.rdl` publish paths?

`New-PowerBIReport` accepts `.pbix` directly but **does not support `.rdl`**. Paginated reports require the raw `imports` REST API with multipart/form-data upload, implemented in `Publish-PaginatedReport`. This is why the module detects the file extension and branches.

### 2.3 Why service principal, not user delegation?

- No human in the loop for automated deploys
- No MFA interruption
- Auditable actor per environment (separate SP per env for blast-radius isolation)
- Works with non-interactive agents
- Supported by Power BI for dataset refresh, workspace management, and publish (since ~2021 for most APIs; earlier for some)

**Limitations accepted:** SPs cannot own some artifact types (e.g. dataflows in Pro-only workspaces). Our Premium workspaces make this a non-issue.

### 2.4 Why Premium (not Pro)?

Mandatory:
- Paginated reports (`.rdl`) require Premium capacity
- Service principal publish/refresh at scale requires Premium
- Enterprise features: deployment pipelines, XMLA endpoints, large model storage

### 2.5 Why YAML config, not JSON?

Operators edit these files. YAML supports comments and is easier to review in PRs. The `powershell-yaml` module handles parsing.

### 2.6 Why re-deploy for rollback, not API-level revert?

Power BI has no native version history accessible via API. The authoritative source of truth is Git + build artifacts. Retaining pipeline artifacts for 30 days gives a 30-day rollback window.

### 2.7 Idempotency

Every deploy uses `CreateOrOverwrite`. Running the same pipeline twice yields the same end state. This allows:
- Safe retries on transient failures
- Deterministic environment reproduction
- Rollback via redeploy

### 2.8 Environments are isolated

Separate Azure subscriptions, Key Vaults, service principals, workspaces, and capacities per environment. A Dev compromise cannot cascade to Prod.

## 3. Data flow: single deployment

1. Pipeline triggered by push / PR merge / manual run
2. **Validate stage** (pooled runner):
   - Lint PS scripts (PSScriptAnalyzer)
   - Run Pester tests
   - Validate report files (non-zero, < 1 GB, `.rdl` parses as XML)
   - Upload pipeline artifact
3. **Deploy stage** (per environment):
   - Authenticate to Azure (OIDC federation or SP secret)
   - Fetch secrets from Key Vault via `Az.KeyVault`
   - `Connect-PowerBIServiceAccount` as the SP
   - Get-or-create workspace; assign to capacity
   - Assert `IsOnDedicatedCapacity == true` (fail fast if not)
   - For each report file:
     - `.pbix` → `New-PowerBIReport` with `-ConflictAction CreateOrOverwrite`
     - `.rdl` → multipart POST to `/groups/{wsId}/imports`, poll until `Succeeded`
   - For `.pbix` datasets: bind credentials, apply parameter overrides, optionally refresh
   - Run smoke test (GET the report back)
   - Emit per-report result to `deployment-summary.json`
4. **Fail-fast behavior**: any single report failure aborts that environment's stage. Later environments are skipped by `dependsOn`.

## 4. Security model

### 4.1 Secrets

- **Never** written to logs. `Write-DeploymentLog` is the only logger, and it does not accept `SecureString` parameters.
- Fetched from Key Vault via `Get-AzKeyVaultSecret` into `SecureString`, passed to cmdlets that require `PSCredential`.
- Pipeline-masked by both Azure DevOps and GitHub Actions when sourced from their respective secret stores.

### 4.2 Least privilege

| Identity | Permissions |
|----------|-------------|
| Dev SP | Workspace Admin (Dev only); Key Vault Secrets User (Dev KV only) |
| Test SP | Workspace Member (Test only); KV Secrets User (Test KV only) |
| Prod SP | Workspace Member (Prod only); KV Secrets User (Prod KV only) |

Prod SP is deliberately **Member, not Admin** — it can publish and refresh but cannot change workspace permissions, preventing lateral movement from a leaked secret.

### 4.3 Network

- Key Vaults: private endpoint or trusted-services-only firewall
- Pipeline agents: consider self-hosted in a private VNet if your threat model requires outbound traffic inspection

### 4.4 Audit

- Power BI Audit Log (Microsoft Purview / Security & Compliance) captures all publish/refresh actions by actor UPN (the SP)
- Pipeline logs include `correlationId` to correlate pipeline runs with audit events
- Retention: per compliance policy (typically 90 days PBI audit, 365 days pipeline logs)

## 5. Scalability

- Deployments scale linearly with report count; each `.pbix` import averages 10–30 seconds
- `.rdl` imports are fast (seconds) since they're XML, but the first render after deploy warms slowly
- For tenants with hundreds of reports, consider parallelizing `foreach` with `ForEach-Object -Parallel -ThrottleLimit 5` — note Power BI rate-limits at ~120 requests/minute per user/SP.

## 6. Disaster recovery

- **Source code**: Git — geo-replicated by provider
- **Build artifacts**: retained 30 days in pipeline store
- **Power BI metadata**: backed up via `Export-PowerBIReport` on a nightly schedule (see `scripts/` directory — not implemented in this bootstrap, but planned)
- **RTO**: 30 min (re-run pipeline against known-good artifact)
- **RPO**: 24 h (last nightly metadata export)

## 7. Known limitations

| Limitation | Impact | Mitigation |
|------------|--------|-----------|
| No native PBI rollback | Must redeploy prior artifact | Build artifact retention 30 days |
| SP can't own mailboxes | Refresh failure emails drop | Set `Take over` post-deploy + `notifyOption` + out-of-band alerting on refresh API |
| `Update-ReportDatasourceCredentials` supports only Basic/Key | OAuth2 datasources need manual setup on first deploy | Document in report onboarding; OAuth helper function planned |
| Concurrent deploys to same workspace race | Last writer wins | `concurrency` group in pipeline config prevents this per-branch |
| `.rdl` import has no `skipReport` option | Re-publish always overwrites | Acceptable for this design |
