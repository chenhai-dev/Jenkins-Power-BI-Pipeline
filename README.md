# Power BI Paginated Report (RDL) — Jenkins Shared Library

Automated CI/CD pipeline for deploying Power BI Paginated Reports (`.rdl` files) to a Power BI Premium workspace via the Power BI REST API.

---

## Table of Contents

1. [Overview](#overview)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Azure AD Service Principal](#step-1--azure-ad-service-principal)
5. [Step 2 — Power BI Workspace Setup](#step-2--power-bi-workspace-setup)
6. [Step 3 — Jenkins Setup](#step-3--jenkins-setup)
7. [Step 4 — Create the Pipeline Job](#step-4--create-the-pipeline-job)
8. [Pipeline Parameters Reference](#pipeline-parameters-reference)
9. [How It Works](#how-it-works)
10. [Deployment Scenarios](#deployment-scenarios)
11. [Security Considerations](#security-considerations)
12. [Troubleshooting](#troubleshooting)

---

## Overview

This library deploys one or more `.rdl` files from a Git repository into a Power BI workspace.  
For each file it:

1. Checks whether the report already exists in the workspace.
2. Patches the ODBC connection string inside the RDL XML (find → replace).
3. Uploads the file via the Power BI Import API (`Overwrite` for existing, `Abort` for new).
4. Polls until the import completes.
5. Calls `Default.UpdateDatasources` to bind the Power BI service-side datasource credential.
6. Exports a CSV + JSON summary and emails the team.

All failures are collected — processing continues for remaining files — and the build fails only at the end with a clear list of which files failed.

---

## Repository Structure

```
shared-library/
├── Jenkinsfile                            ← Consumer: 2-line entry point
├── README.md                              ← This document
├── vars/
│   └── powerBiRdlPipeline.groovy          ← Pipeline definition (Groovy)
└── resources/
    └── scripts/
        └── deploy-rdl.ps1                 ← Deployment logic (PowerShell 7)
```

The `vars/` and `resources/` directories must be in the same Git repository that is registered as the Jenkins Global Pipeline Library. The consumer `Jenkinsfile` lives in a **separate** repository (your RDL source repo, or any repo).

---

## Prerequisites

| Requirement | Details |
|---|---|
| Jenkins | 2.387+ (LTS recommended) |
| Jenkins plugins | Pipeline, Git, Docker Pipeline, Credentials Binding, Email Extension (emailext) |
| Docker on agents | `ubuntu-ci-image:1.11.0` must be reachable from `artifactory.ap.manulife.com` |
| PowerShell 7 | Must be installed inside the Docker image (`pwsh` on PATH) |
| Power BI Premium | The target workspace must be on Premium capacity (required for REST API RDL import) |
| Azure AD | An App Registration (Service Principal) with Power BI API permissions |

---

## Step 1 — Azure AD Service Principal

### 1.1 Create the App Registration

1. Go to **Azure Portal → Azure Active Directory → App registrations → New registration**.
2. Give it a name (e.g. `jenkins-powerbi-deploy-kh`).
3. Leave **Redirect URI** blank (client credentials flow does not need one).
4. Click **Register**.

### 1.2 Create a Client Secret

1. In the app, go to **Certificates & secrets → Client secrets → New client secret**.
2. Set an expiry (12 or 24 months recommended — put a reminder in your calendar to rotate it).
3. Copy the **Value** immediately — you cannot retrieve it later.

Note the three values you will need:

| Value | Where to find it |
|---|---|
| **Tenant ID** | Azure AD → Overview → Tenant ID |
| **Client ID** (Application ID) | App Registration → Overview → Application (client) ID |
| **Client Secret** | The value you just copied |

### 1.3 Grant Power BI API Permissions

1. In the App Registration, go to **API permissions → Add a permission → Power BI Service**.
2. Choose **Application permissions** (not Delegated).
3. Add the following permissions:

   | Permission | Purpose |
   |---|---|
   | `Dataset.ReadWrite.All` | Upload / replace reports |
   | `Report.ReadWrite.All` | Read report metadata, update datasources |
   | `Workspace.Read.All` | List reports in the workspace |

4. Click **Grant admin consent for \<your tenant\>**.  
   ⚠️ This requires a **Global Administrator** or **Power BI Administrator** Azure AD role.

---

## Step 2 — Power BI Workspace Setup

The Service Principal must be a **Member** or **Admin** of every workspace it deploys to.

1. In **Power BI Service**, open the target workspace.
2. Go to **Workspace settings → Access**.
3. Search for the SPN by its display name (the App Registration name).
4. Grant **Member** or **Admin** role.

> **Tip:** If you manage many workspaces, use the Power BI REST API to automate SPN workspace membership across environments.

### Verify SPN Access (Optional)

Use PowerShell to confirm before running Jenkins:

```powershell
$body = @{
    client_id     = '<client-id>'
    client_secret = '<client-secret>'
    scope         = 'https://analysis.windows.net/powerbi/api/.default'
    grant_type    = 'client_credentials'
}
$token = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" `
    -Body $body -ContentType 'application/x-www-form-urlencoded'

$headers = @{ Authorization = "Bearer $($token.access_token)" }
Invoke-RestMethod -Method Get `
    -Uri "https://api.powerbi.com/v1.0/myorg/groups/<workspace-id>/reports" `
    -Headers $headers | Select-Object -ExpandProperty value | Select name, id
```

If this lists reports (or returns an empty array), the SPN has access.

---

## Step 3 — Jenkins Setup

### 3.1 Required Plugins

Install these via **Manage Jenkins → Plugins**:

| Plugin | Why |
|---|---|
| Pipeline | Core declarative pipeline support |
| Git | `GitSCM` checkout step |
| Docker Pipeline | Docker agent support |
| Credentials Binding | `withCredentials` block |
| Email Extension | `emailext` notification step |
| Timestamper | `timestamps()` option |

### 3.2 Register the Shared Library

1. Go to **Manage Jenkins → System → Global Pipeline Libraries**.
2. Click **Add** and fill in:

   | Field | Value |
   |---|---|
   | Name | `powerbi-shared-lib` |
   | Default version | `main` (or a release tag) |
   | Load implicitly | ☐ (leave unchecked — explicit `@Library` is safer) |
   | Retrieval method | Modern SCM |
   | Source Code Management | Git |
   | Repository URL | URL of the repo containing this `shared-library/` folder |
   | Credentials | SSH key or token with read access to the library repo |

3. Save.

> **Monorepo note:** If this `shared-library/` directory lives inside a larger monorepo, set  
> **Library Path** → `shared-library` so Jenkins only loads `vars/` and `resources/` from that sub-path.

### 3.3 Jenkins Credentials

Add three credentials per environment in **Manage Jenkins → Credentials → System → Global credentials**.

#### SPN Username/Password (Client ID + Secret)

| Field | Value |
|---|---|
| Kind | Username with password |
| ID | `AZ_SPN_KH_PAS_NONPROD` |
| Username | Azure AD Client ID (GUID) |
| Password | Azure AD Client Secret |

#### SPN Tenant ID (Secret Text)

| Field | Value |
|---|---|
| Kind | Secret text |
| ID | `AZ_SPN_KH_PAS_NONPROD_TENANT_ID` |
| Secret | Azure AD Tenant ID (GUID) |

#### Git SSH Key (if using SSH clone)

| Field | Value |
|---|---|
| Kind | SSH Username with private key |
| ID | `DevSecOps_SCM_SSH_CLONE_PRIVATE_KEY` |
| Username | `git` |
| Private Key | The SSH private key with read access to the RDL Git repos |

**Naming convention:** The pipeline derives the Tenant ID credential by appending `_TENANT_ID` to the `SPN_Credential_ID` parameter.  
For PROD, create: `AZ_SPN_KH_PAS_PROD` and `AZ_SPN_KH_PAS_PROD_TENANT_ID`.

---

## Step 4 — Create the Pipeline Job

1. **New Item → Pipeline** (or **Multibranch Pipeline** if you want branch-based builds).
2. Under **Pipeline → Definition**, select **Pipeline script from SCM**.
3. Set SCM to **Git**, enter the URL of the repository that contains the consumer `Jenkinsfile`.
4. Set **Script Path** to `Jenkinsfile` (or the path to the consumer file).
5. Save and run.

### Consumer Jenkinsfile (2 lines)

```groovy
@Library('powerbi-shared-lib') _

powerBiRdlPipeline()
```

Place this file at the root of your RDL source repository.

---

## Pipeline Parameters Reference

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `PowerBI_Apps` | String | ✅ | — | Application code (e.g. `CAS`). Used to find the RDL folder: `<MARKET>-<APP>/<ENV>/` |
| `PowerBI_Env` | String | ✅ | — | Workspace sub-folder name (e.g. `KH_REP_SIT02_EDB`) |
| `Group_ID_Env` | String | ✅ | — | Power BI Workspace GUID (from the workspace URL) |
| `Find_String` | String | ⬜ | — | ODBC connection string to find inside the RDL XML |
| `Replace_String` | String | ⬜ | — | Replacement ODBC connection string (also used for API datasource binding) |
| `PowerBI_Repo_URL` | String | ✅ | — | SSH URL of the Git repo containing `.rdl` files |
| `Git_Branch` | String | ✅ | — | Branch or tag to deploy (e.g. `release/2.0`) |
| `SPN_Credential_ID` | String | ✅ | `AZ_SPN_KH_PAS_NONPROD` | Jenkins credential ID for the Azure SPN |
| `ALLOW_REPLACE_EXISTING_RDL` | Boolean | ⬜ | `false` | Allow overwriting reports that already exist in the workspace |
| `DRY_RUN` | Boolean | ⬜ | `false` | Validate and list RDL files without uploading anything |
| `Mail_Builder` | String | ⬜ | — | Comma-separated email addresses for deployment notification |

### RDL Folder Layout

The pipeline checks out the Git repo and looks for `.rdl` files at:

```
<WORKSPACE>/<MARKET>-<APP>/<ENV>/*.rdl
```

Example:

```
KH-D2C-CAS/
└── KH_REP_SIT02_EDB/
    ├── Report_CashFlow.rdl
    ├── Report_PolicySummary.rdl
    └── Report_ClaimStatus.rdl
```

The **Market** segment is derived from the first folder of the Jenkins job path (e.g. the job `KH-D2C/CAS/SIT02` → Market = `KH-D2C`).

---

## How It Works

```
Jenkins Pipeline
│
├─ Initialization
│   └─ Derive market from job path, validate required params
│
├─ Checkout Repo
│   └─ Clone RDL source repo (SSH) into <MARKET>-<APP>/<ENV>/
│
└─ Deploy Power BI RDL  (PowerShell 7 inside Docker)
    │
    ├─ Acquire Azure AD access token (client credentials flow)
    │   └─ Token is cached and auto-refreshed every ~55 min
    │
    ├─ List existing reports in the workspace
    │
    └─ For each .rdl file:
        ├─ (1) Patch ODBC connection string in RDL XML (find → replace)
        ├─ (2) POST to /imports  (nameConflict=Overwrite or Abort)
        ├─ (3) Poll /imports/{id} until importState = Succeeded
        └─ (4) POST to /reports/{id}/Default.UpdateDatasources
                 → binds the Power BI service-side datasource credential

Post-deploy:
├─ Archive report-id-comparison-summary.csv + .json
└─ Email team with build summary and attached log
```

### Why Two Steps for the Datasource?

The ODBC text replacement (step 1) updates the embedded connection string inside the RDL file *before it is uploaded*. However, the Power BI service maintains its own datasource binding registry that is separate from the file content. Step 4 (`Default.UpdateDatasources`) instructs the Power BI service to register the new connection string in its gateway/datasource store, which is what the report actually uses at render time.

Skipping step 4 results in the report showing a datasource error even though the RDL file has the correct string.

---

## Deployment Scenarios

### New report (first-time deploy)

```
ALLOW_REPLACE_EXISTING_RDL = false  (or true — both work for new reports)
```

1. ODBC string is patched.
2. Imported with `nameConflict=Abort`.
3. Datasource is bound.
4. `IdCompareStatus` → `NEW_REPORT_CREATED`.

### Update existing report

```
ALLOW_REPLACE_EXISTING_RDL = true
```

1. ODBC string is patched.
2. Imported with `nameConflict=Overwrite`.
3. Datasource is bound.
4. `IdCompareStatus` → `UNCHANGED` (same report ID) or `ID_CHANGED` (Power BI assigned a new ID — update any embed links).

### Validate without deploying

```
DRY_RUN = true
```

The pipeline authenticates, checks out the repo, lists the RDL files it *would* deploy, then exits without uploading anything. Use this to confirm credentials and RDL discovery before a real deployment.

---

## Security Considerations

- **Secrets never in logs.** Client ID, secret, and tenant ID are injected via `withCredentials` only — they appear as `****` in the build log.
- **Least-privilege SPN.** Grant only `Dataset.ReadWrite.All`, `Report.ReadWrite.All`, and `Workspace.Read.All`. Do not use user-delegated tokens.
- **One SPN per environment.** Use separate `AZ_SPN_KH_PAS_NONPROD` and `AZ_SPN_KH_PAS_PROD` credentials so a NONPROD pipeline cannot write to PROD. The `SPN_Credential_ID` parameter enforces this at the job level.
- **Secret rotation.** Azure AD client secrets expire. Rotate them before expiry and update the Jenkins credential. Set a calendar reminder.
- **SSH Git clone.** The pipeline uses SSH for Git checkout. Do not use HTTPS tokens stored in the URL.
- **Docker socket mount.** The `-v /var/run/docker.sock` mount is required by the CI image. Restrict which agents this job can run on.

---

## Troubleshooting

### `Missing required environment variables: PBI_TENANT_ID`

The credential ID suffix does not match. If `SPN_Credential_ID` is `AZ_SPN_KH_PAS_NONPROD`, there must be a Jenkins Secret Text credential named exactly `AZ_SPN_KH_PAS_NONPROD_TENANT_ID`.

---

### `403 Forbidden` on import or datasource update

The SPN is not a **Member** or **Admin** of the target workspace. Check [Step 2](#step-2--power-bi-workspace-setup).

Also verify that **admin consent was granted** for all API permissions in Azure AD.

---

### `Report already exists. Set ALLOW_REPLACE_EXISTING_RDL=true`

The report name already exists in the workspace and `ALLOW_REPLACE_EXISTING_RDL` is `false`. Set it to `true` to overwrite.

---

### `Import timed out after 5 minutes`

The Power BI service is slow. Usually transient — re-run the job. If it happens consistently, check Power BI service health at https://status.powerbi.com.

---

### `No datasources found for report <id>` (warning, not error)

The import succeeded but the report has no datasource registered yet. This can happen on a brand-new Premium capacity that has not processed the report fully. Wait a few minutes and re-run.

---

### `IdCompareStatus = ID_CHANGED` in the summary

An overwrite import assigned a new GUID to the report. Any embed tokens, dashboard tiles, or bookmarks that reference the old ID are now broken. Update them with the new ID from the summary CSV.

---

### Email not sent

1. Confirm `Mail_Builder` is filled in.
2. Confirm the **Email Extension** plugin is installed and configured in **Manage Jenkins → System → Extended E-mail Notification** (SMTP host, credentials).

---

### How to find the Workspace (Group) ID

Open the workspace in Power BI Service. The URL will be:  
`https://app.powerbi.com/groups/<WORKSPACE-GUID>/...`

Copy the GUID — that is the `Group_ID_Env` parameter.
