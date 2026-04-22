# Disaster Recovery Runbook

Procedures for recovering the Power BI estate from various failure scenarios.

## DR scope & objectives

| Scenario | RTO | RPO | Strategy |
|----------|-----|-----|----------|
| Single report corrupted/deleted | 30 min | 24 h | Rollback via previous artifact |
| Full workspace lost | 2 h | 24 h | Restore from nightly backup blob |
| Premium capacity region outage | 4 h | 24 h | Assign workspace to capacity in secondary region |
| Tenant-level disaster | 8 h | 24 h | Cross-tenant recovery (manual) |
| Service principal credential compromise | 1 h | N/A | Rotate secret, audit, redeploy |

## Prerequisites verified quarterly

- Nightly backups running and retained per lifecycle policy (see `scripts/backup/Backup-PowerBIWorkspace.ps1`)
- Secondary region capacity provisioned OR standby SKU available
- Runbook tested via quarterly DR drill in Dev
- Key Vault soft-delete + purge protection enabled (verified via Azure Policy)
- Source code and artifacts in geo-replicated storage (Git + GRS storage account)

---

## Scenario 1: Single report corrupted or deleted

**Signal:** Users report a specific report is missing or broken; others are fine.

1. Confirm scope - only one report affected:
   ```powershell
   ./scripts/monitoring/Get-PowerBIHealth.ps1 -Environment Prod
   ```

2. Follow [`PRODUCTION-DEPLOYMENT.md` rollback procedure](./PRODUCTION-DEPLOYMENT.md#rollback-procedure):
   ```powershell
   ./scripts/Rollback-PowerBIReport.ps1 `
       -Environment Prod `
       -RollbackArtifactPath <prior-artifact-path> `
       -ReportName "AffectedReportName"
   ```

3. Validate, close incident.

---

## Scenario 2: Full workspace lost

**Signal:** Workspace missing from Power BI Service, or all reports inaccessible.

### 2.1 Confirm incident

```powershell
# Connect with a tenant-admin account (NOT pipeline SP - its scope is limited)
Connect-PowerBIServiceAccount

Get-PowerBIWorkspace -Name "Enterprise-Analytics-PROD" -Scope Organization -Include Deleted
```

If `State = Deleted`: try restore within 90-day soft-delete window:

```powershell
# As tenant admin
Invoke-PowerBIRestMethod `
    -Url "admin/groups/$wsId/restore" `
    -Method Post `
    -Body (@{ name = "Enterprise-Analytics-PROD"; emailAddress = "data-platform@example.com" } | ConvertTo-Json)
```

If not recoverable via soft-delete, proceed with backup restore.

### 2.2 Restore from backup

1. **Identify the latest backup blob:**
   ```powershell
   $ctx = New-AzStorageContext -StorageAccountName stpowerbiprod -UseConnectedAccount
   Get-AzStorageBlob -Container powerbi-backups -Context $ctx -Prefix "Prod/" |
       Sort-Object LastModified -Descending |
       Select-Object -First 5 Name, LastModified, Length
   ```

2. **Download it:**
   ```powershell
   $latestBackup = Get-AzStorageBlob -Container powerbi-backups -Context $ctx -Prefix "Prod/" |
                   Sort-Object LastModified -Descending |
                   Select-Object -First 1

   $localZip = "C:\dr-restore\$($latestBackup.Name -replace '/','_')"
   Get-AzStorageBlobContent -Blob $latestBackup.Name -Container powerbi-backups -Destination $localZip -Context $ctx

   Expand-Archive -Path $localZip -DestinationPath "C:\dr-restore\extracted"
   ```

3. **Create a new workspace (with same name if old one purged, else new name):**
   Update `config/prod.yaml`:
   ```yaml
   workspace:
     name: "Enterprise-Analytics-PROD"   # Or new name
     capacityId: "..."
     createIfMissing: true                # Temporary - revert after restore
   ```

4. **Redeploy all reports:**
   ```powershell
   ./scripts/Deploy-PowerBIReport.ps1 `
       -Environment Prod `
       -ArtifactPath C:\dr-restore\extracted
   ```

5. **Restore dataset settings from manifest:**
   ```powershell
   $manifest = Get-Content "C:\dr-restore\extracted\manifest.json" | ConvertFrom-Json

   # Re-apply refresh schedules (example)
   foreach ($ds in $manifest.datasets) {
       if ($ds.refreshSchedule) {
           # Find dataset in new workspace by name, then PATCH /refreshSchedule
           # ...
       }
   }
   ```

6. **Restore workspace access from manifest `access` section** - re-add users/groups with same roles.

7. **Revert `createIfMissing` in `config/prod.yaml` to `false`.** Commit.

8. **Post-restore validation:**
   - Run health check
   - Business owner validates critical reports

---

## Scenario 3: Premium capacity region outage

**Signal:** Azure status page shows regional outage affecting Power BI Premium in the primary region. Workspace unavailable.

### 3.1 Options

**Option A — wait for regional recovery** (most cases, < 4 h).
Notify stakeholders; monitor Azure status.

**Option B — failover to secondary region** (if outage > RTO):

1. Pre-requisite: secondary-region capacity already provisioned (standby SKU acceptable; resume on demand).

2. Reassign workspace to secondary capacity:
   ```powershell
   Connect-PowerBIServiceAccount  # Tenant admin
   $body = @{ capacityId = $secondaryCapacityId } | ConvertTo-Json
   Invoke-PowerBIRestMethod `
       -Url "groups/$wsId/AssignToCapacity" `
       -Method Post `
       -Body $body
   ```

3. Datasets need refresh on new capacity — trigger manually.

4. Update `config/prod.yaml` with `capacityId` of secondary. Commit. Future deploys target the new capacity.

5. After primary recovers, either stay on secondary or fail back (reverse step 2).

---

## Scenario 4: Tenant-level disaster

**Signal:** Entire Azure AD tenant compromised / deleted / unavailable.

This is beyond the scope of automated recovery. Engage:
- Microsoft premier support (severity A)
- Organization's IT disaster recovery team
- Security / incident response

Our artifacts are recoverable because:
- Source code is in Git (geo-replicated by provider)
- Backup blobs are in GRS storage (replicated to secondary region)
- Secrets regenerated post-incident per security policy

Once a recovered tenant is available:
1. Re-provision service principals (Setup §3)
2. Re-provision Key Vault and restore secrets (Setup §4)
3. Re-deploy infrastructure via Bicep (`infrastructure/main.bicep`)
4. Run full recovery from backup (Scenario 2)

---

## Scenario 5: Service principal credential compromise

**Signal:** Unexpected activity in Power BI audit log under the SP account, or notification from security team.

### 5.1 Immediate containment (within 15 min)

1. **Revoke the SP credential:**
   ```bash
   # Get the key ID of the compromised credential
   az ad app credential list --id <clientId>

   # Delete it
   az ad app credential delete --id <clientId> --key-id <compromisedKeyId>
   ```

2. **Revoke any Azure sign-in sessions:**
   ```bash
   az ad user revoke-sign-in-sessions --id <servicePrincipalObjectId>
   ```

3. **Remove SP from workspace if exfiltration suspected:**
   Power BI Service → workspace → Manage access → remove SP.

### 5.2 Investigation

- Pull audit log for the SP for the last 90 days (Power BI admin portal → Audit logs)
- Review all workspaces the SP had access to — determine what could have been exfiltrated
- Check Key Vault audit log: where was the secret read from, which IPs?
- Engage security team; file incident per policy

### 5.3 Recovery

1. Create new SP client secret per SETUP §3.2
2. Update Key Vault with new secret (new version; old version disabled)
3. Re-add SP to workspace with appropriate role
4. Test pipeline in Dev, then promote
5. Document in incident ticket; post-mortem within 72 h

---

## DR testing schedule

| Test | Frequency | Performed by |
|------|-----------|-------------|
| Scenario 1 (single report rollback) | Monthly in Dev | DevOps |
| Scenario 2 (full workspace restore) | Quarterly in Dev | DevOps + Data Platform |
| Scenario 3 (capacity failover) | Biannual | DevOps + Cloud Platform |
| Scenario 5 (SP rotation) | Annual as part of secret rotation | DevOps + Security |

Document each drill in the DR test log with: scope, observed RTO, observed RPO, issues found, remediation actions.
