# Production Deployment Runbook

Step-by-step procedure for executing a Power BI report deployment to **Production**. Follow in order; do not skip the validation steps.

**Estimated total time:** 30–60 min for a standard release. Emergency hotfix: 15–20 min.

---

## Roles

| Role | Responsibility |
|------|---------------|
| **Release Engineer** | Runs the pipeline, monitors progress, executes rollback if needed |
| **Approver** | CAB-appointed approver(s) — approve Prod gate in Azure DevOps / GitHub |
| **Business Owner** | Validates the deployed report(s) post-deploy |
| **On-Call** | Available on `#data-platform-oncall` throughout the window |

---

## Pre-deployment checklist (T-24h)

Complete **at least 24 hours before** the change window.

- [ ] Change request approved in ServiceNow (ID: `CHG*`)
- [ ] Release notes drafted and shared with stakeholders
- [ ] Deployment to Dev is green in CI
- [ ] Deployment to Test is green in CI
- [ ] Business owner has signed off on Test environment
- [ ] Backup of current Prod workspace completed (nightly backup < 24h old; verify blob exists)
- [ ] No conflicting changes scheduled in the same window (check change calendar)
- [ ] Capacity metrics reviewed: Prod capacity CPU < 60 % baseline
- [ ] Key Vault secret expiry dates checked: > 30 days remaining
- [ ] Rollback artifact identified (previous successful Prod run's artifact)

---

## Change window preparation (T-30m)

1. **Join the change call / Slack huddle**
   - Announce: "Starting Power BI Prod deployment CHG*"
   - Confirm approver online and ready

2. **Verify Prod capacity health**

   ```powershell
   ./scripts/monitoring/Get-PowerBIHealth.ps1 -Environment Prod -OutputFormat table
   ```

   Expected: `overallHealth: healthy`. If degraded/unhealthy, resolve before proceeding.

3. **Snapshot "before" state**
   - Open the target Power BI workspace in a browser. Screenshot the report list + last-modified timestamps. Attach to the change ticket.

4. **Verify rollback readiness**
   - Download the previous successful Prod artifact from the pipeline.
   - Note its build ID in the change ticket.

---

## Deployment execution

### Step 1 — Trigger the pipeline (T-0)

**Azure DevOps:**
1. Pipelines → `PowerBI-Deploy-*` → **Run pipeline**
2. Branch: `main` (or `release/<version>` for hotfix)
3. Confirm parameters, click **Run**

**GitHub Actions:**
1. Actions → `Deploy Power BI Reports` → **Run workflow**
2. Branch: `main` (or `release/<version>`)
3. Environment: leave default (promotes through Dev → Test → Prod)

### Step 2 — Watch Validate & Test stages

Expected: both complete green in ≈ 5 minutes.

If either fails:
- **Validate fails**: fix the code, push again. Do NOT proceed.
- **Test fails**: investigate before promoting to Prod. See `docs/TROUBLESHOOTING.md`.

### Step 3 — Approve Prod deployment

Expected: **pending approval** notification in Azure DevOps / GitHub UI, plus email.

**Approver checklist:**
- [ ] Change window is active
- [ ] Test deployment succeeded
- [ ] No active Sev1/Sev2 incidents on Data Platform
- [ ] Release Engineer confirmed ready

Approver clicks **Approve** / **Review deployments → Approve**.

### Step 4 — Monitor Prod deploy

Expected: runs for 5–15 min depending on report count.

Watch the pipeline log for:
- ✓ `Authentication successful`
- ✓ `Premium capacity check passed`
- ✓ `Report published successfully` (one line per report)
- ✓ `Post-deploy validation passed` (one per report)
- ✓ `All reports deployed successfully`

If any step emits `"level":"ERROR"` or `"level":"FATAL"`:
- **Immediately assess**: is it a single report or the whole deploy?
- **Do not retry blindly**. Consult `docs/TROUBLESHOOTING.md`.
- Escalate to on-call if unclear.

### Step 5 — Post-deploy smoke test (release engineer)

1. Open the workspace in Power BI Service.
2. For each deployed report:
   - Confirm it appears with expected name and updated timestamp
   - Open it — verify visuals render
   - For `.pbix`: trigger a manual refresh, wait for success
   - For `.rdl`: click **Export** → PDF, confirm it generates
3. Run health check again:

   ```powershell
   ./scripts/monitoring/Get-PowerBIHealth.ps1 -Environment Prod
   ```

   Expected: still `healthy`.

### Step 6 — Business owner validation

Hand over to business owner on the change call. They validate:
- Data looks correct
- Key visuals/KPIs match expected values
- Any embedded/shared report links still work

Business owner confirms **"Accepted"** on the change call. This is recorded in the change ticket.

### Step 7 — Close out

1. Update change ticket: status → **Implemented**
2. Post in `#data-platform-announce`: "Prod deployment CHG* complete. Reports: X. Validation: passed."
3. Attach pipeline run URL + deployment summary JSON to ticket
4. Close change call

---

## Rollback procedure

### When to roll back

Execute immediately if any of:
- Business owner rejects validation
- A report fails to open or render for > 5 min
- Refresh failures cascading across datasets
- Any Sev1 incident caused by the deployment

### Rollback steps

1. **Announce rollback** in `#data-platform-announce` and change call.

2. **Download the previous artifact** (identified in pre-deployment checklist).

3. **Execute rollback script:**

   ```powershell
   ./scripts/Rollback-PowerBIReport.ps1 `
       -Environment Prod `
       -RollbackArtifactPath <path-to-downloaded-artifact>/reports
   ```

4. **Verify rollback**
   - Check Power BI Service: report `modifiedDateTime` should roll back to the earlier timestamp
   - Run `Get-PowerBIHealth.ps1` — expect `healthy`
   - Business owner re-validates

5. **Document**
   - Update change ticket: status → **Backed out**
   - Open post-incident ticket within 24 h
   - Schedule post-mortem within 72 h

**Rollback RTO target: 30 minutes from go/no-go decision.**

---

## Emergency hotfix procedure

For critical issues requiring bypass of the standard Test gate:

1. Create branch `release/hotfix-<ticket-id>` from `main`
2. Apply fix, commit, push
3. Get CAB-lead approval via Slack (recorded in ticket)
4. Trigger pipeline manually on the hotfix branch
5. Both Test and Prod still run, but expedited approval (< 15 min SLA)
6. Post-hotfix: merge fix to `main`, schedule post-mortem

---

## Troubleshooting quick reference

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| Pipeline stuck waiting for approval | No approver online | Check `#data-platform-oncall`, page backup approver |
| `AADSTS7000215: Invalid client secret` | SP secret expired | Rotate per SETUP §9, then retry |
| `Premium capacity check passed` but reports won't render | Capacity paused/exhausted | Azure portal → capacity → Resume or scale up |
| `Import failed` on a `.rdl` | Unsupported data source / malformed XML | See `docs/TROUBLESHOOTING.md` → `.rdl specifically fails` |
| Refresh failing after deploy | Credentials not bound | Verify Key Vault secret matches actual SQL password; re-run pipeline |

Full index: `docs/TROUBLESHOOTING.md`

---

## Key contacts during change window

| Who | Channel |
|-----|---------|
| Release Engineer (rotating) | `#data-platform-oncall` |
| Data Platform on-call | PagerDuty `data-platform` |
| Power BI Tenant Admin | `powerbi-admins@example.com` |
| CAB lead | ServiceNow change ticket |

---

## Appendix: command reference

```powershell
# Health check
./scripts/monitoring/Get-PowerBIHealth.ps1 -Environment Prod

# Pre-deployment validation (run locally before push)
./scripts/Invoke-PreDeploymentValidation.ps1 `
    -ArtifactPath ./reports `
    -Environment Prod `
    -ConfigPath ./config/prod.yaml

# Dry run deploy
./scripts/Deploy-PowerBIReport.ps1 `
    -Environment Prod `
    -ArtifactPath ./reports `
    -DryRun

# Manual backup (on-demand, outside scheduled nightly)
./scripts/backup/Backup-PowerBIWorkspace.ps1 `
    -Environment Prod `
    -StorageAccount stpowerbiprod

# Rollback
./scripts/Rollback-PowerBIReport.ps1 `
    -Environment Prod `
    -RollbackArtifactPath ./downloaded-artifact/reports
```
