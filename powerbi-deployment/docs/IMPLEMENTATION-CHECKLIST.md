# Implementation Checklist — Zero to Production

This is the consolidated path from empty repo to Prod deployment. Expect **1–2 weeks** for a team doing this for the first time, driven mostly by cross-team coordination rather than code.

Work through phases in order. Do not start Phase N until Phase N-1 is complete.

---

## Phase 0 — Prerequisites (Week 0)

### 0.1 Licensing and organization

- [ ] Power BI Premium capacity (P1+) OR Fabric capacity (F64+) procured
  - [ ] Capacity lives in a region aligned with data residency
  - [ ] Sized per `docs/SETUP.md` §5.2 for expected paginated report load
- [ ] Azure subscriptions provisioned per environment:
  - [ ] `sub-analytics-dev`
  - [ ] `sub-analytics-test`
  - [ ] `sub-analytics-prod`
- [ ] Resource groups: `rg-analytics-{dev,test,prod}` in each subscription
- [ ] Azure AD tenant admin identified and reachable
- [ ] Power BI Service admin identified (may be same person)
- [ ] Git hosting decided: Azure DevOps or GitHub Enterprise
- [ ] CI/CD agent strategy decided: Microsoft-hosted (faster start) or self-hosted (better security posture)

### 0.2 People

- [ ] DevOps team assigned as pipeline owner
- [ ] Data Platform team assigned as report SME
- [ ] Security team contact for infra / IAM review
- [ ] 2+ CAB-approved approvers for Prod gate
- [ ] On-call rotation established for `#data-platform-oncall`

---

## Phase 1 — Identity and tenant (Days 1–2)

**Owner: DevOps + Identity team**

### 1.1 Power BI tenant settings

Log in as Power BI Service admin → **Admin portal → Tenant settings**:

- [ ] Create Azure AD security group `sg-powerbi-deployment-sp` (empty initially)
- [ ] Enable **Allow service principals to use Power BI APIs** → scoped to that group
- [ ] Enable **Create workspaces (new workspace experience)** → same group (for Dev auto-create)
- [ ] Enable **Paginated Reports** for Premium capacity workspaces
- [ ] Enable **Export and sharing** per org policy
- [ ] Wait 15 min for propagation

### 1.2 Service principals (one per env)

For each of `dev`, `test`, `prod`:

```bash
# Replace <env>
az ad app create --display-name "sp-powerbi-deploy-<env>" --sign-in-audience AzureADMyOrg
# Note the returned appId (clientId)

# Create a client secret (or prefer federated credential — §1.3)
az ad app credential reset --id <appId> --display-name "pipeline-secret-$(date +%Y%m)" --years 1

# Get the objectId for role assignments
az ad sp show --id <appId> --query id -o tsv

# Add the SP to the Power BI group
az ad group member add --group "sg-powerbi-deployment-sp" --member-id <spObjectId>
```

- [ ] `sp-powerbi-deploy-dev` created + added to group
- [ ] `sp-powerbi-deploy-test` created + added to group
- [ ] `sp-powerbi-deploy-prod` created + added to group
- [ ] Client secrets saved in password manager, **to be moved to Key Vault in Phase 2**

### 1.3 Federated credentials (GitHub only)

If using GitHub Actions:

```bash
az ad app federated-credential create --id <prodAppId> --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/<repo>:environment:powerbi-prod",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

- [ ] Federated credential added for each environment (scope to env, not branch)

### 1.4 Premium capacity assignment permissions

Power BI Admin Portal → **Capacity settings** → your capacity → **Capacity admins**:

- [ ] Add all three deployment SPs as capacity admins **OR** specifically grant assignment permission

---

## Phase 2 — Infrastructure (Days 2–3)

**Owner: DevOps + Cloud Security**

### 2.1 Bicep deployment per environment

```bash
# Log in to the target subscription
az account set --subscription <dev-sub-id>

# Edit the bicepparam with real object IDs from Phase 1
# infrastructure/dev.bicepparam -> pipelineSpObjectId, devopsGroupObjectId

az deployment group create \
    --resource-group rg-analytics-dev \
    --template-file infrastructure/main.bicep \
    --parameters infrastructure/dev.bicepparam
```

- [ ] Dev infrastructure deployed
- [ ] Test infrastructure deployed
- [ ] Prod infrastructure deployed (**Cloud Security reviewer required**)
- [ ] Outputs captured: `keyVaultName`, `storageAccountName`, `logAnalyticsWorkspaceId`

### 2.2 Key Vault secrets

For each environment, populate:

```bash
# Authenticate as a human with Key Vault Secrets Officer or higher on the vault
az login

# Replace <env> and values
az keyvault secret set --vault-name kv-powerbi-<env> \
    --name sp-powerbi-deploy-<env>-secret \
    --value "<from-phase-1.2>" \
    --expires "$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)"

az keyvault secret set --vault-name kv-powerbi-<env> \
    --name sql-reporting-user-<env> \
    --value "<sql-username>" \
    --expires "..."

az keyvault secret set --vault-name kv-powerbi-<env> \
    --name sql-reporting-password-<env> \
    --value "<sql-password>" \
    --expires "..."
```

- [ ] Dev secrets populated
- [ ] Test secrets populated
- [ ] Prod secrets populated (**change window, paired with Security**)
- [ ] Expiry set to max 1 year for SP secret, max 6 months for datasource credentials
- [ ] Expiry alerts verified in Azure Monitor

### 2.3 Networking (Prod only, if applicable)

- [ ] Private endpoint created for Prod Key Vault
- [ ] Private endpoint created for Prod Storage Account
- [ ] DNS zones linked to the VNet hosting agents

---

## Phase 3 — Workspaces (Day 3)

**Owner: DevOps + Data Platform**

Power BI Service → **Workspaces** → **Create workspace**:

- [ ] `Enterprise-Analytics-DEV` created, assigned to Dev Premium/shared capacity
- [ ] `Enterprise-Analytics-TEST` created, assigned to Test capacity
- [ ] `Enterprise-Analytics-PROD` created, assigned to Prod Premium capacity

For each workspace, **Manage access**:

- [ ] Add the corresponding environment SP as:
  - Dev: **Admin**
  - Test: **Member**
  - Prod: **Member**

Capture each workspace's ID (from URL: `app.powerbi.com/groups/<wsId>/`) and record in `config/*.yaml`.

- [ ] Workspace IDs captured
- [ ] Capacity IDs captured (Azure Portal → capacity → Resource ID)
- [ ] All four `config/*.yaml` placeholders replaced with real GUIDs

---

## Phase 4 — CI/CD wiring (Day 4)

**Owner: DevOps**

### Azure DevOps path

- [ ] Project created
- [ ] Repo initialized with contents of this package
- [ ] Service connections created (Project Settings → Service connections):
  - [ ] `sc-powerbi-dev` — Azure RM, scoped to Dev RG, workload identity federation
  - [ ] `sc-powerbi-test` — same, Test
  - [ ] `sc-powerbi-prod` — same, Prod
- [ ] Environments created (Pipelines → Environments):
  - [ ] `powerbi-dev` — no approval
  - [ ] `powerbi-test` — approval: QA lead
  - [ ] `powerbi-prod` — approval: 2 approvers + business-hours check (Mon–Thu 08:00–17:00)
- [ ] Variable group `powerbi-shared` linked to Key Vault
- [ ] Pipeline created from `pipelines/azure-pipelines.yml`
- [ ] Scheduled pipeline created from `pipelines/azure-pipelines-scheduled.yml`
- [ ] Branch policies on `main`:
  - [ ] Minimum 2 reviewers
  - [ ] Require pipeline success
  - [ ] Check CODEOWNERS

### GitHub Actions path

- [ ] Repo contains `.github/workflows/` with `github-actions.yml` and `github-actions-scheduled.yml`
- [ ] Repository variables set:
  - [ ] `AZURE_TENANT_ID`
  - [ ] `AZURE_CLIENT_ID_DEV`, `AZURE_CLIENT_ID_TEST`, `AZURE_CLIENT_ID_PROD`
  - [ ] `AZURE_SUBSCRIPTION_ID_DEV`, `AZURE_SUBSCRIPTION_ID_TEST`, `AZURE_SUBSCRIPTION_ID_PROD`
- [ ] Environments created (Settings → Environments):
  - [ ] `powerbi-dev`
  - [ ] `powerbi-test` — required reviewers + wait timer
  - [ ] `powerbi-prod` — required reviewers + deployment branch rule (`main`, `release/*`)
- [ ] Branch protection on `main`:
  - [ ] Require PR
  - [ ] Require CODEOWNERS review
  - [ ] Require status checks: validate job
  - [ ] Require signed commits

---

## Phase 5 — First report (Day 5)

**Owner: DevOps + Data Analyst**

### 5.1 Smoke-test report

Create a minimal report to validate the pipeline end-to-end:

- [ ] Open Power BI Desktop
- [ ] Create blank report with a single visual sourced from a parameterized Azure SQL table
- [ ] Define parameters: `SqlServerName`, `DatabaseName`, `Environment`
- [ ] Save as `reports/SmokeTest.pbix`
- [ ] (Optional) Create `reports/SmokeTest.rdl` in Power BI Report Builder with one dataset

### 5.2 Wire into configs

```yaml
# config/dev.yaml, test.yaml, prod.yaml — in each, add:
reports:
  - fileName: "SmokeTest.pbix"
    displayName: "Smoke Test [{env}]"
    parameters:
      SqlServerName: "sql-{env}.database.windows.net"
      DatabaseName: "SmokeTest_{env}"
      Environment: "{env}"
```

- [ ] Dev config updated
- [ ] Test config updated
- [ ] Prod config updated

### 5.3 Commit + observe

```bash
git checkout -b report/smoketest
git add reports/ config/
git commit -m "feat(reports): initial smoke test deployment"
git push origin report/smoketest
# Open PR, merge
```

- [ ] Validate stage passes
- [ ] Dev deployment succeeds
- [ ] Test approval issued and granted
- [ ] Test deployment succeeds
- [ ] Prod approval issued and granted
- [ ] Prod deployment succeeds
- [ ] Report visible in each workspace
- [ ] Dataset refresh successful in each workspace

---

## Phase 6 — Observability (Days 6–7)

**Owner: DevOps**

### 6.1 Log shipping

- [ ] Confirm pipeline logs flow to Log Analytics (`customLogs_CL` or similar)
- [ ] Create KQL queries for common scenarios (from `docs/OPERATIONS.md` §9.2)
- [ ] Import saved queries into Log Analytics workspace

### 6.2 Alerts

Configured by Bicep (`infrastructure/main.bicep`), verify they actually fire:

- [ ] KV unauthorized-access alert — test by calling KV without permissions, confirm email arrives
- [ ] Pipeline failure alert — test by deliberately failing Dev pipeline, confirm email arrives
- [ ] Health check failure alert — test by stopping capacity, confirm alert

### 6.3 Dashboards

- [ ] Create Azure Dashboard or Grafana board showing:
  - `powerbi_overall_health` per env
  - Deploy frequency (pipeline run count)
  - Deploy success rate
  - Dataset refresh success rate
  - Capacity CU %
  - Last backup age

---

## Phase 7 — DR validation (Day 7–8)

**Owner: DevOps + Data Platform**

### 7.1 Backup validation

- [ ] Scheduled backup has run at least twice (check blob container)
- [ ] Blob contains `manifest.json` + `.pbix` / `.rdl` files
- [ ] Manifest JSON parses correctly

### 7.2 DR drill in Dev

Follow `docs/runbooks/DISASTER-RECOVERY.md` Scenario 2 on Dev:

- [ ] Download latest backup from Dev container
- [ ] Extract, redeploy to a **new** throwaway workspace in Dev
- [ ] Verify all reports restored
- [ ] Document observed RTO
- [ ] File drill report in incident management system

### 7.3 Rollback drill

- [ ] Deploy a modified `SmokeTest.pbix` to Dev (e.g., change the title)
- [ ] Download previous artifact from pipeline
- [ ] Execute `Rollback-PowerBIReport.ps1` against Dev
- [ ] Verify prior version restored

---

## Phase 8 — Prod go-live (Day 8–10)

**Owner: DevOps + CAB**

### 8.1 Pre-go-live

- [ ] All prior phases complete and signed off
- [ ] Security review passed (`docs/SECURITY.md` checklist)
- [ ] On-call primed; backup on-call confirmed
- [ ] Business stakeholders informed of go-live window

### 8.2 First production deployment

Follow `docs/runbooks/PRODUCTION-DEPLOYMENT.md` strictly for the first Prod deploy. Do **not** skip any steps even if they feel redundant.

- [ ] Change ticket opened
- [ ] Pre-deployment checklist completed
- [ ] Pipeline executed
- [ ] Prod validation passed
- [ ] Business owner sign-off recorded
- [ ] Change ticket closed

### 8.3 Post-go-live

- [ ] First-week hypercare: DevOps monitors actively
- [ ] Capture any incidents, feed back to `TROUBLESHOOTING.md`
- [ ] After 2 weeks of stable operation, transition to BAU

---

## Phase 9 — Ongoing operations (Week 3+)

### Routine cadence

| Cadence | Task | Owner |
|---------|------|-------|
| Every deploy | PR review, validation, approval | Team |
| Every 15 min | Health check (automated) | Pipeline |
| Nightly | Backup (automated) | Pipeline |
| Weekly | Dashboard review | DevOps |
| Monthly | Capacity + cost review | Data Platform |
| Monthly | Rollback drill in Dev | DevOps |
| Quarterly | Workspace access audit | Security |
| Quarterly | DR drill in Dev | DevOps |
| Quarterly | `TROUBLESHOOTING.md` refresh based on incidents | DevOps |
| Annual | SP secret rotation | DevOps + Security |
| Annual | Security review (`SECURITY.md`) | Security |
| Annual | Penetration test | Security |

---

## Sign-off

Production go-live requires signatures from:

- [ ] **DevOps Lead** — pipeline tested and operational
- [ ] **Data Platform Lead** — reports validated in Test
- [ ] **Security Lead** — security checklist passed
- [ ] **Business Owner** — accepting the deployed solution
- [ ] **CAB Chair** — change approved for Prod

_Signature record preserved in the change management system._
