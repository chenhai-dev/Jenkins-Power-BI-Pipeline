# Operations Runbook

Day-to-day operational procedures for the Power BI deployment pipeline.

## 1. Deploying a new report

### 1.1 Standard flow (developer)

1. Author the report in Power BI Desktop (`.pbix`) or Power BI Report Builder (`.rdl`).
2. Parameterize data-source connections where possible (so the same file works across Dev/Test/Prod via `Update-ReportDataset`).
3. Commit the file to `reports/` on a feature branch.
4. Update the relevant `config/*.yaml` entries:
   ```yaml
   reports:
     - fileName: "MyNewReport.pbix"
       displayName: "My New Report"
       parameters:
         SqlServerName: "sql-prod.database.windows.net"
         DatabaseName: "MyDB"
   ```
5. Open PR against `main`. Pipeline runs validation only on PR.
6. Merge to `main` → auto-deploy to Dev → manual approval → Test → manual approval → Prod.

### 1.2 Manual / on-demand deployment

**Azure DevOps:** Pipelines → select pipeline → **Run pipeline** → choose branch.

**GitHub Actions:** Actions tab → select workflow → **Run workflow** → choose environment input.

## 2. Promoting an existing report

Identical to new deployment — the pipeline uses `CreateOrOverwrite` so re-publishing from the same `.pbix` simply updates the target workspace. **The dataset is preserved in place**, which means row-level-security assignments and refresh schedules survive promotion.

> ⚠️ If the new version changes the dataset schema, any downstream dataflows or composite models that reference it will need to be refreshed.

## 3. Rolling back

Power BI Service has no native version history. Rollback = redeploy the previous artifact.

### 3.1 Locate prior artifact

**Azure DevOps:** Pipelines → last successful run → **Artifacts** → download `powerbi-reports`.

**GitHub Actions:** Actions → last green run → **Artifacts** → download `powerbi-reports`.

### 3.2 Execute rollback

```powershell
./scripts/Rollback-PowerBIReport.ps1 `
    -Environment Prod `
    -RollbackArtifactPath ./downloaded-previous-build/powerbi-reports
```

Or, for a single report only:

```powershell
./scripts/Rollback-PowerBIReport.ps1 `
    -Environment Prod `
    -RollbackArtifactPath ./downloaded-previous-build/powerbi-reports `
    -ReportName "SalesDashboard"
```

**Target RTO: 30 minutes** from go/no-go decision.

## 4. Refresh management

Deployment triggers an async refresh after publishing (unless `-SkipRefresh` is passed). The refresh itself can take minutes to hours.

### 4.1 Check refresh status

Power BI Service → workspace → dataset → **Refresh history**, or via REST:

```powershell
Connect-PowerBIServiceAccount -ServicePrincipal -TenantId $t -Credential $c
Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$dsId/refreshes" -Method Get
```

### 4.2 Failure notification

Datasets are published with `notifyOption=MailOnFailure`. Alerts go to the dataset owner (the service principal) — **the SP does not have a mailbox**, so configure the `refresh.notificationEmails` in `config/prod.yaml` AND set **Take over** on the dataset to transfer ownership to a monitored mailbox or distribution list, after first deploy.

## 5. Capacity monitoring

Install the **Microsoft Power BI Premium Capacity Utilization and Metrics** app from AppSource. Key alerts:

| Metric | Threshold | Action |
|--------|-----------|--------|
| CPU % (30-min rolling) | > 80 % sustained | Scale up or offload reports to other capacity |
| Memory consumption | > 90 % | Evict underused datasets |
| Paginated report renders failed | any | Check `.rdl` complexity, dataset size |
| Throttling events | any | Immediate capacity review |

## 6. On-call response

### 6.1 Pipeline failure

1. Check the pipeline run logs — errors are structured JSON, filter by `"level":"ERROR"` or `"level":"FATAL"`.
2. Note the `correlationId` — use it to trace across Power BI audit logs.
3. Consult `docs/TROUBLESHOOTING.md`.

### 6.2 Report broken in Prod

1. Decide: fix forward or roll back?
   - **Hotfix trivial**: cherry-pick to `release/` branch, push, expedited Prod deploy.
   - **Non-trivial / user impact**: rollback (§3).
2. File post-incident review within 48 hours.

### 6.3 Capacity exhausted

Symptoms: report load slow / times out; refreshes queued indefinitely.

Short-term: scale up via Azure portal (Power BI capacity → **Scale**). P1 → P2 in ~60 seconds.
Medium-term: identify heavy datasets via Capacity metrics app; move to separate capacity or optimize.

## 7. Routine maintenance

| Task | Frequency | Owner |
|------|-----------|-------|
| SP secret rotation | Annual | DevOps |
| PS module version bump | Quarterly | DevOps |
| Pester test review | Quarterly | DevOps |
| Capacity review | Monthly | Data Platform |
| Workspace access audit | Quarterly | Security |
| Key Vault access review | Quarterly | Security |
| Unused report cleanup | Biannual | Business owners |

## 8. Change management

Prod deployments are a **standard change** under the change management policy:

- Auto-approved if it passes Dev and Test with green tests
- Deployed only during change window (configured as business-hours check in Azure DevOps environment)
- Captured automatically in ServiceNow via webhook (configure in Azure DevOps → Service hooks)

**Emergency change** (hotfix bypassing Test):
- Requires CAB lead approval recorded in ServiceNow
- Use a `release/hotfix-*` branch
- Post-incident review mandatory

## 9. Observability

### 9.1 Log locations

- Pipeline logs: Azure DevOps run UI / GitHub Actions run UI (retained 30 days)
- Structured JSON in stdout: shipped to Log Analytics via the agent's diagnostic extension
- Deployment summary: `reports/deployment-summary.json` kept as pipeline artifact

### 9.2 Useful queries (KQL in Log Analytics)

```kql
// All failed deployments in last 7 days
ContainerLog_CL
| where TimeGenerated > ago(7d)
| where parse_json(LogEntry).level == "ERROR"
| project TimeGenerated, correlationId=parse_json(LogEntry).correlationId, message=parse_json(LogEntry).message
```

```kql
// Mean deploy duration by environment
// (requires writing start/end markers - already emitted by Write-DeploymentLog)
```

## 10. Contacts

| Role | Group | Escalation path |
|------|-------|-----------------|
| Primary on-call | `#data-platform-oncall` | PagerDuty `data-platform` |
| Power BI tenant admin | `powerbi-admins@example.com` | — |
| Azure AD / SP | `identity-team@example.com` | — |
| Key Vault | `cloudsec@example.com` | — |
