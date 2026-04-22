# Using Jenkins — Setup Guide

This guide walks through deploying the Power BI pipeline on Jenkins. It is an alternative to Azure DevOps / GitHub Actions covered in `SETUP.md`. The deployment *logic* is identical — only the CI/CD driver changes.

## 1. Prerequisites

### 1.1 Jenkins controller

- **Jenkins 2.387+** with Declarative Pipeline support (LTS recommended)
- HTTPS with valid certificate
- Backed up regularly (configuration + credentials)

### 1.2 Required plugins

Install via **Manage Jenkins → Plugins → Available plugins**:

| Plugin | Purpose |
|--------|---------|
| **Pipeline** | Declarative + scripted pipelines |
| **Pipeline: Stage View** | Visual pipeline status |
| **Blue Ocean** | Modern UI (optional but recommended) |
| **Git** | SCM checkout |
| **Credentials Binding** | Inject secrets as env vars |
| **Azure Credentials** | Native Azure SP credential type (optional) |
| **AnsiColor** | Colored log output |
| **Timestamper** | Timestamps in logs |
| **Workspace Cleanup** | `cleanWs()` step |
| **JUnit** | Pester test result publishing |
| **Email Extension** | `emailext` step |
| **Slack Notification** | `slackSend` step |
| **Parameterized Scheduler** | `parameterizedCron` for scheduled pipeline |
| **SSH Agent** | Git operations with deploy key |

### 1.3 Agents

You need at least one build agent with:

- **PowerShell 7.2+** installed and on `PATH` as `pwsh`
- **Windows preferred** (better Power BI tooling compatibility) — Linux works but has edge cases
- **Network access** to:
  - `*.powerbi.com`, `login.microsoftonline.com`
  - `*.vault.azure.net` (Key Vault)
  - `*.blob.core.windows.net` (backup storage)
  - `www.powershellgallery.com` (module install) — or internal proxy
  - Your Git server
- **Labels:** `powershell`, `windows` (the `Jenkinsfile` pins to `powershell && windows`)

For production, run at least **2 agents** for redundancy; consider dedicated agents for Prod deployments (separate labels: `powershell && windows && prod-deploy`).

#### Agent install quick start (Windows)

```powershell
# On agent machine, as Administrator
# 1. Install PowerShell 7
winget install --id Microsoft.PowerShell --source winget

# 2. Verify
pwsh -c '$PSVersionTable.PSVersion'

# 3. Install Git
winget install --id Git.Git

# 4. Pre-install the PS modules (speeds up every build)
pwsh -c "Install-Module MicrosoftPowerBIMgmt, powershell-yaml, Az.KeyVault, Az.Storage, Az.Accounts, Pester, PSScriptAnalyzer -Force -Scope AllUsers -AcceptLicense"

# 5. Launch Jenkins agent (via JNLP or SSH per your topology)
```

#### Agent install quick start (Linux)

```bash
# Install pwsh 7
wget -q "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get update && sudo apt-get install -y powershell

# Verify
pwsh -c '$PSVersionTable.PSVersion'

# Pre-install modules (use -Scope AllUsers so every build sees them)
sudo pwsh -c "Install-Module MicrosoftPowerBIMgmt, powershell-yaml, Az.KeyVault, Az.Storage, Az.Accounts, Pester, PSScriptAnalyzer -Force -Scope AllUsers -AcceptLicense"
```

## 2. Credentials setup

Jenkins needs the Azure AD service principal details for each environment. Store them in **Manage Jenkins → Credentials → System → Global credentials**.

### 2.1 Required credentials

Create each of these as **Secret text** kind (unless noted):

| ID | Type | Value | Scope |
|----|------|-------|-------|
| `pbi-sp-tenant-id` | Secret text | Your Azure AD tenant ID | Global |
| `pbi-sp-dev-client-id` | Secret text | Dev SP's `appId` | Global |
| `pbi-sp-dev-client-secret` | Secret text | Dev SP's client secret | Global |
| `pbi-sp-test-client-id` | Secret text | Test SP's `appId` | Global |
| `pbi-sp-test-client-secret` | Secret text | Test SP's client secret | Global |
| `pbi-sp-prod-client-id` | Secret text | Prod SP's `appId` | Global |
| `pbi-sp-prod-client-secret` | Secret text | Prod SP's client secret | Global |
| `jenkins-git-deploy-key` | SSH Username with private key | Git deploy key for tagging | Global |
| `slack-notifier-token` | Secret text | Slack bot token | Global |

### 2.2 Alternative: Azure Credentials Plugin

If you installed the Azure Credentials Plugin, use its **Azure Service Principal** credential type instead of separate secret-text entries. This is cleaner but requires the plugin:

1. **Add Credentials → Azure Service Principal**
2. Fields:
   - Subscription ID (one per environment)
   - Client ID
   - Client Secret (or certificate)
   - Tenant ID
3. ID: `az-sp-powerbi-prod`, `az-sp-powerbi-test`, `az-sp-powerbi-dev`

You can then bind in the pipeline like:

```groovy
withCredentials([azureServicePrincipal('az-sp-powerbi-prod')]) {
    pwsh '''
        Connect-AzAccount -ServicePrincipal `
            -Credential (New-Object PSCredential(
                $env:AZURE_CLIENT_ID,
                (ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force)
            )) `
            -TenantId $env:AZURE_TENANT_ID
    '''
}
```

### 2.3 Fetching secrets from Key Vault (recommended for Prod)

For stronger secret hygiene, store secrets only in Key Vault and have Jenkins pull them at job start. Two options:

**Option A — Jenkins Azure Key Vault Plugin**

Install the plugin, configure a Key Vault URL under **Manage Jenkins → Configure System**, then reference secrets in pipelines:

```groovy
withCredentials([
    azureKeyVault([
        credentialID: 'az-sp-kv-reader',
        secretType: 'Secret',
        name: 'sp-powerbi-deploy-prod-secret',
        version: '',
        envVariable: 'PBI_CLIENT_SECRET'
    ])
]) {
    // PBI_CLIENT_SECRET available here
}
```

**Option B — inline `az cli` fetch**

```groovy
withCredentials([azureServicePrincipal('az-sp-kv-reader')]) {
    pwsh '''
        az login --service-principal -u $env:AZURE_CLIENT_ID `
                 -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID | Out-Null
        $env:PBI_CLIENT_SECRET = az keyvault secret show `
            --vault-name kv-powerbi-prod `
            --name sp-powerbi-deploy-prod-secret `
            --query value -o tsv
    '''
}
```

The simplest path (shown in `Jenkinsfile`) uses direct Secret-text credentials; migrate to Key Vault plugin once comfortable.

## 3. User & role setup

The `Jenkinsfile` gates Test and Prod deployments on input submitters. Configure these groups in **Manage Jenkins → Security**:

### 3.1 If using built-in Jenkins users

Create users and assign to groups via **Role-Based Access Control Plugin** (install separately):

| Group | Members | Permission |
|-------|---------|------------|
| `data-platform-leads` | 2+ platform leads | Approve Test + Prod |
| `qa-leads` | QA lead + backups | Approve Test |
| `release-managers` | Release engineers | Approve Prod |
| `cab-leads` | CAB chairs | Emergency out-of-hours approval |

Reference them in the pipeline like `submitter: 'qa-leads,data-platform-leads'`.

### 3.2 If using LDAP/AD integration

Map your AD groups to Jenkins via the **LDAP** or **Active Directory** plugin, then reference AD group names directly in the `submitter` field.

### 3.3 If using SSO (SAML / OIDC)

Similar approach via the **SAML Plugin** / **OpenID Connect Authentication Plugin**. Groups come from the IdP token claims.

## 4. Job creation

### 4.1 Main deployment pipeline

1. **New Item → Multibranch Pipeline**
2. Name: `powerbi-deploy`
3. **Branch Sources:** Git (Azure Repos, GitHub, GitLab, Bitbucket — whichever you use)
4. **Build Configuration:**
   - Mode: `by Jenkinsfile`
   - Script path: `pipelines/Jenkinsfile`
5. **Behaviours:**
   - Discover branches (all)
   - Discover pull requests from origin (merging to target)
   - Discover pull requests from forks (contributors only) — or disable if private
6. **Scan Multibranch Pipeline Triggers:** every 5 minutes (or use webhooks — preferred)
7. **Orphaned Item Strategy:** Keep at most 14 days / 20 branches

Save. Jenkins auto-discovers branches and builds `main` + active branches.

### 4.2 Scheduled operations pipeline

1. **New Item → Pipeline** (not multibranch; one branch only)
2. Name: `powerbi-scheduled-ops`
3. **Pipeline → Definition:** `Pipeline script from SCM`
4. **SCM:** Git, pointing at your repo
5. **Branch:** `*/main`
6. **Script Path:** `pipelines/Jenkinsfile.scheduled`

Save. The `parameterizedCron` trigger inside the Jenkinsfile schedules both backup and health check.

### 4.3 Webhook setup (recommended over SCM polling)

**Azure Repos:** Project settings → Service hooks → subscribe `Code pushed` → Jenkins.

**GitHub:** Repo Settings → Webhooks → add `https://jenkins.example.com/github-webhook/`, event: push + PR.

**GitLab:** Repo Settings → Integrations → add `https://jenkins.example.com/project/powerbi-deploy`, events: push + MR.

Then in the job config, **uncheck** "Poll SCM" and **check** "GitHub hook trigger for GITScm polling" (or equivalent). Webhook-driven builds trigger instantly instead of on a 5-min poll.

## 5. Shared library (optional but recommended)

If you have multiple Power BI repos, extract the helper functions from `Jenkinsfile` into a Jenkins Shared Library:

### 5.1 Create the library repo

```
jenkins-shared-library/
└── vars/
    ├── deployPowerBI.groovy
    └── powerBIHealth.groovy
```

**`vars/deployPowerBI.groovy`:**

```groovy
def call(Map args) {
    def envName = args.environment
    def configPath = args.configPath ?: "./config/${envName.toLowerCase()}.yaml"
    def dryRun = args.dryRun ? '-DryRun' : ''

    pwsh """
        ./scripts/Deploy-PowerBIReport.ps1 `
            -Environment ${envName} `
            -ConfigPath ${configPath} `
            -ArtifactPath ./reports `
            ${dryRun}
    """
}
```

### 5.2 Configure in Jenkins

**Manage Jenkins → System → Global Pipeline Libraries:**

- Name: `powerbi-shared`
- Default version: `main`
- Source: Git, pointing at your library repo

### 5.3 Use in `Jenkinsfile`

```groovy
@Library('powerbi-shared') _

pipeline {
    // ...
    stages {
        stage('Deploy to Dev') {
            steps {
                deployPowerBI(environment: 'Dev')
            }
        }
    }
}
```

This keeps the per-repo `Jenkinsfile` thin (~50 lines) and centralizes deployment logic.

## 6. Differences from Azure DevOps / GitHub Actions

| Aspect | Azure DevOps / GH Actions | Jenkins |
|--------|---------------------------|---------|
| Infrastructure | Hosted by Microsoft / GitHub | Self-hosted (you manage uptime, patches) |
| Agents | Hosted pool + self-hosted | Always self-hosted |
| OIDC federation | Native, recommended for Prod | Not built-in; use Azure Credentials plugin or Key Vault plugin |
| Approval gates | Built-in (Environments) | Via `input` step + submitter-allowlist |
| Secrets store | KV via native integration | Credentials store or KV plugin |
| Webhooks | Native | Plugin-based (GitHub plugin, GitLab plugin) |
| Concurrency control | Concurrency groups | `disableConcurrentBuilds()` + lockable resources |
| Logs | Retained in service | On controller — rotate + archive to central log sink |
| Audit | Per-org audit log | Plugin (Audit Trail) — configure explicitly |
| Cost | Per-minute billing | Fixed infra cost, unlimited builds |

### When Jenkins makes sense

- Your org has a standard Jenkins estate you must use
- Strict data sovereignty: pipeline execution must stay on-prem
- You need custom plugins not available in hosted platforms
- Existing Jenkins shared libraries / conventions to reuse
- Self-hosted runner networking is simpler on Jenkins than standing up self-hosted GH / ADO runners

### When Jenkins is a poor fit

- Small team without Jenkins admin capacity
- Prod security posture requires OIDC federation (Jenkins can do it with effort; others do it natively)
- You need ephemeral, auto-scaling agents (possible with Jenkins + Kubernetes plugin but complex)

## 7. Hardening the Jenkins controller

Before first Prod deploy:

- [ ] Jenkins behind HTTPS with valid cert (not self-signed)
- [ ] CSRF protection enabled
- [ ] Agent → Controller security enabled
- [ ] No anonymous read access
- [ ] `Script Security` plugin enforcing approved Groovy only
- [ ] Credentials in **System** scope, never **Global** if any untrusted users exist
- [ ] Audit Trail plugin installed; logs shipped to SIEM
- [ ] Backups of `JENKINS_HOME` running (at minimum: credentials.xml + secrets/ + jobs/)
- [ ] Jenkins admin accounts use SSO / MFA
- [ ] Build agents isolated in a dedicated VLAN; outbound firewalled to the destinations listed in §1.3
- [ ] Regular plugin updates (with test instance)
- [ ] Jenkins URL advertised internally only (no public internet exposure unless webhooks require it — use an ingress with IP allowlist)

## 8. Quick verification

After setup, verify the pipeline before the first real deploy:

```
# Trigger a PR build (validation + tests, no deploy)
Open a PR → pipeline should run Lint, Pester, Validation stages and stop

# Trigger a Dev deploy
Push to a feature branch → pipeline should complete Dev, then wait at Test approval

# Trigger a dry-run to Prod
Build with parameters: DEPLOY_SCOPE=prod-only, DRY_RUN=true
→ Should reach Prod stage, log "DryRun mode - skipping actual deployment", and exit clean
```

## 9. Troubleshooting Jenkins-specific issues

### `pwsh: command not found`

The agent doesn't have PowerShell 7. Install per §1.3.

### `input submitter = 'foo' is not allowed`

The Jenkins user who clicked Approve isn't in the submitter allowlist. Either add them or adjust the `submitter` field.

### `java.io.NotSerializableException` inside pipeline

Groovy's CPS-transform is strict. Move complex logic into `script { ... }` blocks or shared library functions. The `@NonCPS` annotation is another option.

### Hung `input` step

Default timeout was exceeded. Approvers must act within the `timeout` block. Extend if your org needs longer SLAs.

### `fatal: could not read Username for 'https://...'`

SCM checkout step is using anonymous HTTPS against a private repo. Configure a credential ID on the checkout step or use an SSH URL with a deploy key.

### Secrets leaking into build logs

- Never `echo $env:PBI_CLIENT_SECRET` — Jenkins masks it but only if the credentials-binding plugin marked it
- Confirm all sensitive bindings use `credentials(...)` not plain environment pass-through
- Enable **Mask Passwords Plugin** for extra coverage

### Build queue starvation

Prod approvals hold an agent executor while waiting. Use `agent none` at pipeline top level and declare `agent { label ... }` only inside stages that actually need one — the approval stage can then run on the controller without occupying an executor.

```groovy
pipeline {
    agent none
    stages {
        stage('Build') {
            agent { label 'powershell' }
            steps { /* ... */ }
        }
        stage('Approval: Prod') {
            // No agent declaration → runs on controller, no executor used
            steps { input 'Approve?' }
        }
        stage('Deploy Prod') {
            agent { label 'powershell' }
            steps { /* ... */ }
        }
    }
}
```

The provided `Jenkinsfile` uses a single top-level `agent` for simplicity; switch to the `agent none` pattern once you feel comfortable with it.

## 10. Migration path

If you eventually move off Jenkins to Azure DevOps / GitHub Actions, the **only** files you need to change are the pipeline definitions. The deployment logic (PowerShell module + scripts + config + infrastructure) is CI-platform-agnostic and stays intact.
