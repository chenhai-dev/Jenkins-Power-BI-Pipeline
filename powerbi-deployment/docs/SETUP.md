# Setup Guide — One-Time Infrastructure Provisioning

This guide walks through everything that must exist before the first pipeline run. Budget two to four hours, and expect to coordinate with the Azure AD admin, Power BI tenant admin, and the platform team that owns Key Vault.

## 1. Prerequisites checklist

| Item | Who provisions | Notes |
|------|---------------|-------|
| Azure AD tenant with Power BI | Identity team | Existing |
| Power BI Premium capacity (P1+) or Fabric (F64+) | Licensing | Required for `.rdl` paginated reports |
| Azure subscription per environment | Cloud platform | Dev / Test / Prod |
| Azure Key Vault per environment | Security | Store service principal secrets + datasource creds |
| Azure DevOps project or GitHub repo | DevOps | Hosts pipeline |
| Build agents with PowerShell 7.2+ | DevOps | Windows runners preferred (some PBI tooling is Windows-only) |

## 2. Power BI tenant configuration

Performed by a **Power BI Service Admin** in the Power BI Admin Portal (`app.powerbi.com` → Settings → Admin portal → Tenant settings).

### 2.1 Enable service principal access

Under **Developer settings**:

- **Allow service principals to use Power BI APIs** → Enabled
  - Apply to: a specific security group, e.g. `sg-powerbi-deployment-sp`
  - Add your deployment service principals to this group (see §3)
- **Allow service principals to create and use profiles** → Enabled (if using profiles)

### 2.2 Enable workspace creation by SPs (only if Dev auto-creates)

- **Create workspaces (new workspace experience)** → Enabled, applied to the SP group

### 2.3 Enable paginated report usage

- **Export and sharing settings** → **Users can print paginated reports** / **Download reports** → per policy
- **Paginated Reports** → Enabled for relevant workspaces' capacity

### 2.4 Premium capacity admin

For each Premium capacity (P1+ SKU or Fabric F64+), add the deployment service principal as a **Capacity admin** or grant **Assignment permissions** so it can bind workspaces to capacity.

> **Propagation time:** tenant setting changes can take up to 15 minutes to take effect.

## 3. Service principals

One service principal **per environment** (Dev, Test, Prod). Least privilege per environment.

### 3.1 Register app

```bash
az ad app create --display-name "sp-powerbi-deploy-prod" \
    --sign-in-audience AzureADMyOrg
```

Note the `appId` (= clientId) returned.

### 3.2 Create client secret

```bash
az ad app credential reset \
    --id <appId> \
    --display-name "pipeline-secret" \
    --years 1
```

Rotation policy: **annual minimum**. Use Key Vault secret expiry alerts.

### 3.3 Add SP to Power BI security group

```bash
az ad group member add \
    --group "sg-powerbi-deployment-sp" \
    --member-id <appObjectId>
```

### 3.4 Federated identity (recommended over client secret)

For GitHub Actions, configure OIDC:

```bash
az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:your-org/powerbi-deployment:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

This eliminates the long-lived client secret for GitHub-hosted runs.

### 3.5 Workspace permissions

In each target Power BI workspace:

1. Open workspace → **Manage access**
2. Add the service principal as **Admin** (Dev) or **Member** (Prod — least privilege)

> `.rdl` paginated reports specifically require the SP to have **Member or Admin** on the workspace, not just Contributor.

## 4. Azure Key Vault setup

One vault per environment. Network-restrict: private endpoint or trusted services only.

### 4.1 Create vault

```bash
az keyvault create \
    --name kv-powerbi-prod \
    --resource-group rg-analytics-prod \
    --location westeurope \
    --enable-rbac-authorization true
```

### 4.2 Required secrets

| Secret name | Value |
|-------------|-------|
| `sp-powerbi-deploy-prod-secret` | SP client secret from §3.2 |
| `sql-reporting-user-prod` | Datasource SQL username |
| `sql-reporting-password-prod` | Datasource SQL password |

### 4.3 Grant pipeline identity read access

```bash
# Pipeline's own identity (managed identity of self-hosted runner,
# or the OIDC-federated SP from §3.4)
az role assignment create \
    --assignee <pipelineIdentityObjectId> \
    --role "Key Vault Secrets User" \
    --scope "/subscriptions/<subId>/resourceGroups/rg-analytics-prod/providers/Microsoft.KeyVault/vaults/kv-powerbi-prod"
```

## 5. Premium capacity

### 5.1 Identify capacity ID

Azure portal → Capacities → your capacity → Properties → **Resource ID**. The GUID at the end is the `capacityId` to put in `config/*.yaml`.

### 5.2 Capacity sizing for paginated

Paginated reports are memory-hungry. Rough guidance:

| SKU | Concurrent paginated renders | Use case |
|-----|------------------------------|----------|
| P1 / F64 | 4–8 | Light reporting |
| P2 / F128 | 10–15 | Medium |
| P3 / F256 | 20+ | Heavy / enterprise |

Monitor via **Capacity metrics app**. Paginated renders above 100 % CU will throttle.

## 6. CI/CD platform setup

### Azure DevOps

1. **Create service connections** (Project Settings → Service connections):
   - `sc-powerbi-dev` → ARM connection to Dev subscription, scoped to `rg-analytics-dev`
   - `sc-powerbi-test` → same for Test
   - `sc-powerbi-prod` → same for Prod, **workload identity federation** (not secret-based)
2. **Create environments** (Pipelines → Environments):
   - `powerbi-dev` — no approval
   - `powerbi-test` — approval: QA lead
   - `powerbi-prod` — approval: Data Platform lead + Business-hours-only check (08:00–17:00 Mon–Thu)
3. **Link variable group** `powerbi-shared` to Key Vault (Library → + Variable group → Link secrets from Azure Key Vault)

### GitHub Actions

1. **Configure OIDC** per §3.4
2. **Repository variables**: `AZURE_TENANT_ID`, `AZURE_CLIENT_ID_{DEV,TEST,PROD}`, `AZURE_SUBSCRIPTION_ID_{DEV,TEST,PROD}`
3. **Environments** (Settings → Environments):
   - `powerbi-dev`, `powerbi-test`, `powerbi-prod`
   - Prod: required reviewers + deployment branch rule `main` and `release/*`

## 7. First deployment

1. Drop a `.pbix` or `.rdl` into `reports/`.
2. Update the `reports:` block in `config/dev.yaml` with the filename.
3. Commit and push. Pipeline triggers automatically.
4. Watch logs. First run will cold-install PS modules (≈ 2 min).
5. Validate in Power BI Service: the workspace should now contain the report, and for `.pbix`, a dataset with the same name.

## 8. Post-setup verification

Run the smoke test:

```powershell
./scripts/Deploy-PowerBIReport.ps1 -Environment Dev -ArtifactPath ./reports -DryRun
```

Expected output: `DryRun mode - skipping actual deployment` followed by one `Would deploy:` line per report. No errors.

## 9. Secret rotation runbook

Every 12 months (or on compromise):

1. Create new SP secret (§3.2) with a new `--display-name`, e.g. `pipeline-secret-2026`.
2. Add new secret version to Key Vault under the same secret name — old version retained.
3. Trigger pipeline; verify success with new secret.
4. Revoke old SP secret: `az ad app credential delete --id <appId> --key-id <oldKeyId>`.
5. Disable the old Key Vault secret version.

Zero downtime: Azure AD accepts both old and new secrets during the overlap window.
