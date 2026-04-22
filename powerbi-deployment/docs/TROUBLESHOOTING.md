# Troubleshooting Guide

Symptoms → probable cause → fix. Ordered roughly by frequency.

## Authentication failures

### `AADSTS7000215: Invalid client secret provided`

The secret in Key Vault has expired or been rotated without updating the pipeline's expected secret name.

```bash
az keyvault secret show --vault-name kv-powerbi-prod --name sp-powerbi-deploy-prod-secret
# Check "expires" attribute
```

**Fix:** Rotate per `SETUP.md` §9. Always keep the old secret active until the new one is verified.

### `AADSTS700016: Application not found in the directory`

Wrong `clientId` in `config/*.yaml`, or the SP was deleted.

```bash
az ad sp show --id <clientId>
```

### `Access denied. Service principal is not allowed to use Power BI APIs`

Tenant setting not configured, or the SP is not in the allowed security group.

**Fix:** Per `SETUP.md` §2.1. Changes can take up to 15 minutes to propagate. Also check that the security group membership replicated — run `az ad group member list --group sg-powerbi-deployment-sp`.

## Workspace / capacity issues

### `Workspace is NOT on a dedicated (Premium/PPU/Fabric) capacity`

Thrown by `Test-PremiumCapacity`. Workspace is on shared Pro capacity, which cannot host paginated reports.

**Fix:** Assign to a Premium/PPU/Fabric capacity. Either:
- Power BI Service → workspace settings → **Premium** tab → select capacity
- Or via script: `Invoke-PowerBIRestMethod -Url "groups/$wsId/AssignToCapacity" -Method Post -Body (@{capacityId=$capId}|ConvertTo-Json)`

The SP needs **capacity assignment permissions** — check capacity admin settings.

### `CapacityNotActive`

The capacity is paused (common for F-SKUs to save cost).

**Fix:** Azure portal → Fabric capacity → **Resume**. Pipeline can wait:

```powershell
# Add to Deploy script if needed
while ((Get-AzFabricCapacity -Name $name -RG $rg).State -ne 'Active') {
    Start-Sleep 10
}
```

### `PowerBINotLicensedException` on the SP

SP isn't in the allowed-SP security group, or hasn't been granted a Power BI Pro / PPU license. SPs publishing to a Premium workspace don't need user-level Pro, but they must be in the tenant allow-list.

## Publish / import failures

### `ImportFailed` with no error detail

Poll the import endpoint for details:

```powershell
Invoke-PowerBIRestMethod -Url "groups/$wsId/imports/$importId" -Method Get
```

Common causes:
- **`.pbix` was saved in a newer Desktop version than the service supports** — rare; only during month-one of new Desktop releases. Fix: save in Desktop with **File → Options → Preview features** unchecked.
- **Dataset contains a connector not enabled for that capacity** (e.g. certain cloud connectors). Check workspace capacity settings.
- **File > 1 GB** — Power BI import limit (10 GB with Large Dataset setting on Premium). Reduce the file or enable Large models.

### `.rdl` specifically fails with `500 InternalServerError`

- Report uses a data source type not supported in the service (e.g. local file paths)
- Report references a shared dataset that doesn't exist in that workspace
- `.rdl` references an on-premises data source but no gateway is configured

**Fix:** Open the `.rdl` in Report Builder, **Test** the data source connection against the cloud/target data source, re-save, redeploy.

### `TooManyRequests (429)`

Power BI API rate limits:
- 200 requests/hour per user for dataset operations
- Deploys of many reports can hit this

**Fix:** The script has retry logic in `Connect-PowerBIWithServicePrincipal`. For the publish loop, batch by capacity or add `Start-Sleep` between reports. Consider throttling `-ThrottleLimit` if parallelizing.

## Datasource credential failures

### `DatasetRefreshFailed: The credentials provided for the SQL source are invalid`

The credentials in Key Vault are wrong, or the SQL user doesn't have access to the target database.

**Fix:** Test the credentials independently:

```powershell
$cred = Get-Credential   # type SQL creds
Invoke-Sqlcmd -ServerInstance "sql-prod.database.windows.net" -Database "SalesDW_Prod" -Credential $cred -Query "SELECT 1"
```

Update Key Vault with the corrected value.

### `Dataset has no gateway binding`

Applies when the datasource needs a gateway (on-prem SQL, SSAS) but the workspace isn't bound to one. Cloud sources (Azure SQL, Synapse) use "VNet Data Gateway" or none at all.

**Fix:** In Power BI Service → dataset → **Settings** → **Gateway connection** → choose gateway, or for cloud-only, leave disabled.

### Credentials not applied after publish (basic auth)

The deploy script applies credentials only for `.pbix`. Race condition: dataset isn't fully provisioned within the 10-second sleep.

**Fix:** The script already retries implicitly via the refresh failing. For stricter SLAs, increase the sleep to 20 s or replace with a poll:

```powershell
do {
    Start-Sleep 5
    $dataset = (Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets" -Method Get |
                ConvertFrom-Json).value | Where-Object name -eq $reportName
} while (-not $dataset -and (Get-Date) -lt $deadline)
```

## Parameter update failures

### `400 BadRequest` on `UpdateParameters`

The parameter name doesn't exist in the report, or its type is not a simple scalar (lists aren't updatable via API).

**Fix:** Open the `.pbix` in Desktop → **Transform data → Manage Parameters** and verify exact names and that each target parameter is of type `Text` / `Decimal` / etc. (not `List`).

### Parameter updated but refresh uses the old value

Parameters are cached until the next refresh. The script triggers a refresh after `Update-ReportDataset`, so this only appears if `-SkipRefresh` was passed or the refresh hasn't completed yet.

## Refresh failures

### `Refresh takes forever / times out`

Dataset is large or the datasource is slow. Refresh timeout on Premium is 5 h.

**Fix:**
- Enable **Incremental refresh** in Desktop
- Switch to **DirectQuery** where appropriate
- Split one large dataset into multiple smaller ones

### `NotifyOption=MailOnFailure but nobody receives mail`

The dataset is owned by the service principal, which has no inbox.

**Fix:** Per `OPERATIONS.md` §4.2. Either have a monitored distribution list take ownership after publish, or replace built-in notifications with an out-of-band monitor that polls the refresh API and alerts to Slack / PagerDuty.

## Pipeline platform issues

### Azure DevOps: `Could not resolve service connection`

Service connection was renamed or deleted.

**Fix:** Pipelines → Service connections → re-link. Update the `azureSubscription:` value in `azure-pipelines.yml` if the name changed.

### GitHub Actions: `Error: OIDC token request failed`

Federated credential missing or its `subject` doesn't match the workflow context.

**Fix:** Verify `SETUP.md` §3.4. Subject format must match exactly:
- `repo:{org}/{repo}:ref:refs/heads/main` for branch `main`
- `repo:{org}/{repo}:environment:powerbi-prod` for environment-scoped
- Use `az ad app federated-credential list --id <appId>` to inspect

### Module install slow / flakey

First runs install several PowerShell modules (`MicrosoftPowerBIMgmt`, `Az.KeyVault`, `powershell-yaml`). This can take 2–5 minutes on a cold agent.

**Fix:**
- Cache PSModule path between runs (`actions/cache` for GH, pipeline caching for ADO)
- Pre-install on self-hosted runners
- Use a custom agent image with modules pre-baked

## Diagnostic commands

### Get everything about a report

```powershell
# After connecting
$wsId = '<workspaceId>'
$reportId = '<reportId>'

# Report metadata
Invoke-PowerBIRestMethod -Url "groups/$wsId/reports/$reportId" -Method Get

# Owning dataset
Invoke-PowerBIRestMethod -Url "groups/$wsId/reports/$reportId" -Method Get |
    ConvertFrom-Json |
    ForEach-Object { Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$($_.datasetId)" -Method Get }

# Refresh history
Invoke-PowerBIRestMethod -Url "groups/$wsId/datasets/$dsId/refreshes" -Method Get
```

### Enable verbose logging from the module

```powershell
$VerbosePreference = 'Continue'
$DebugPreference   = 'Continue'
./scripts/Deploy-PowerBIReport.ps1 -Environment Dev -ArtifactPath ./reports -Verbose
```

### Force-disconnect a stuck session

```powershell
Disconnect-PowerBIServiceAccount -ErrorAction SilentlyContinue
Clear-AzContext -Force
```

## When to escalate

Open a Microsoft support ticket via the Power BI admin portal when:
- API returns `InternalServerError` consistently for > 1 hour
- Capacity metrics show unexplained 100 % CU usage
- Audit logs reveal unauthorized activity
- Service principal behaves inconsistently across identical tenants

Severity guidelines: Sev A (business-critical Prod reports down), Sev B (degraded), Sev C (everything else).
