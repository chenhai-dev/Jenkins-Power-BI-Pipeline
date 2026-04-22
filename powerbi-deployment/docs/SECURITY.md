# Security Hardening Checklist

Security review must pass before the pipeline can be promoted to serve Prod. Review annually and after any significant change.

## 1. Identity & access

### Azure AD / Entra ID

- [ ] One service principal **per environment** — no shared SPs across Dev/Test/Prod
- [ ] SP names follow convention: `sp-powerbi-deploy-<env>`
- [ ] SPs added only to the Power BI "allowed service principals" security group — not tenant-wide
- [ ] SP credentials rotated at most every 12 months (target: 6 months)
- [ ] Federated credentials preferred over client secrets (GitHub OIDC configured where possible)
- [ ] No user-account-based auth anywhere in the pipeline
- [ ] Conditional Access policy excludes SPs from MFA requirement but *includes* them in device/location restriction where feasible

### Power BI

- [ ] Prod SP granted **Member** workspace role, not Admin (principle of least privilege)
- [ ] Only SP for that environment has access to that environment's workspace
- [ ] Tenant setting "Service principals can use Power BI APIs" scoped to the specific SP security group
- [ ] Workspace access reviewed quarterly (list users/SPs + roles)
- [ ] Row-Level Security (RLS) enforced on datasets containing sensitive data
- [ ] Audit log export to SIEM configured (Purview / Log Analytics)

### Azure subscription

- [ ] Separate subscriptions per environment
- [ ] RBAC follows least-privilege; pipeline identity has only `Key Vault Secrets User` + `Storage Blob Data Contributor` + (optionally) `Reader` on the RG
- [ ] No Owner/Contributor at subscription scope for any automation identity

## 2. Secrets management

- [ ] All secrets live in Azure Key Vault, never in code, config files, or environment variables that outlive the process
- [ ] Key Vault has `enableRbacAuthorization: true` (not legacy access policies)
- [ ] Key Vault has `enableSoftDelete: true` and `enablePurgeProtection: true` in Prod
- [ ] Key Vault has `publicNetworkAccess: Disabled` (private endpoint required) in Prod
- [ ] Key Vault firewall: if private endpoint not feasible, allow-list pipeline agent IPs only
- [ ] Secret expiry dates set; alerts 30 days before expiry (Bicep template includes this)
- [ ] No secrets logged: `Write-DeploymentLog` does not accept `SecureString`; regression-tested in Pester
- [ ] Secrets masked in pipeline output (Azure DevOps / GH Actions both do this automatically for their secret stores)
- [ ] Pipeline identity's Key Vault access scoped to the *specific* vault for that environment, not vault-wide

## 3. Code security

- [ ] `PSScriptAnalyzer` runs in CI; errors and warnings block merge
- [ ] Pester tests verify no plaintext secrets in log output
- [ ] No `Invoke-Expression` or `iex` on user-controlled strings
- [ ] All web calls use `Invoke-PowerBIRestMethod` (which pins TLS and handles auth), not raw `Invoke-WebRequest` with custom headers
- [ ] Dependencies pinned: `MicrosoftPowerBIMgmt -RequiredVersion <x>` in manifest
- [ ] Dependabot / Renovate configured to alert on module vulnerabilities
- [ ] Signed commits required on `main` branch

## 4. Supply chain

- [ ] Pipeline definition (YAML) requires PR review from 2 CODEOWNERS
- [ ] `main` branch protected: no direct pushes, PR required, status checks mandatory
- [ ] Release branches (`release/*`) also protected
- [ ] Pre-deployment validation (`Invoke-PreDeploymentValidation.ps1`) runs every build:
  - Rejects `.pbix` / `.rdl` with embedded credentials
  - Scans for common secret patterns (AWS keys, JWT, SQL connection strings with embedded password)
  - Rejects references to local file paths
- [ ] Build artifacts retained 30 days minimum for audit + rollback
- [ ] Pipeline agent image is either a known Microsoft-hosted image, or a self-hosted image built from a hardened golden image

## 5. Network

- [ ] Self-hosted agents (if used) live in a VNet with private endpoints to Key Vault, Storage, and (ideally) Power BI Service
- [ ] Outbound traffic from agents allowed only to: `*.powerbi.com`, `login.microsoftonline.com`, `*.blob.core.windows.net`, `*.vault.azure.net`, package repositories (PSGallery, NuGet)
- [ ] Microsoft-hosted agents accepted for non-Prod; Prod uses self-hosted for outbound control
- [ ] TLS 1.2 minimum everywhere (enforced at storage account and Key Vault)

## 6. Data protection

- [ ] Datasource credentials bound via `Update-ReportDatasourceCredentials` — never embedded in `.pbix`
- [ ] Connection encryption enforced: `encryptedConnection: "Encrypted"` in config
- [ ] Privacy level set to `Organizational` (not `Public`) to prevent cross-source data leakage
- [ ] Sensitivity labels applied to workspaces and datasets containing regulated data (GDPR / HIPAA / PCI as applicable)
- [ ] Data exfiltration: export settings restricted per tenant policy (Excel export, "Analyze in Excel", etc.)
- [ ] Private Link / VNet Data Gateway used for any on-prem or VNet-private data source

## 7. Audit & compliance

- [ ] Power BI audit log retained 90+ days (365 in regulated industries)
- [ ] Pipeline logs shipped to central log analytics workspace (Log Analytics / Splunk)
- [ ] Each deployment logs a correlation ID present in both pipeline logs and Power BI audit log — traceable end-to-end
- [ ] Every Prod deployment is associated with a change ticket (ServiceNow)
- [ ] Deployment summary JSON archived per record retention policy
- [ ] Quarterly access review: identities with workspace / Key Vault / capacity-admin permissions
- [ ] Annual penetration test scope includes Power BI Service exposure
- [ ] SOC 2 / ISO controls mapped to this pipeline as applicable

## 8. Monitoring & response

- [ ] Key Vault unauthorized-access alert configured (see `infrastructure/main.bicep`)
- [ ] Pipeline failure alert → on-call (via PagerDuty / Opsgenie)
- [ ] Health check (`Get-PowerBIHealth.ps1`) scheduled every 15 min
- [ ] Anomaly detection on audit log: unusual SP activity volume, off-hours deploys
- [ ] Incident response plan references this document and the DR runbook
- [ ] Regular security drills: secret rotation, SP compromise simulation

## 9. Regulatory considerations (if applicable)

### GDPR
- [ ] Data residency: Premium capacity region matches data-sovereignty requirements
- [ ] Reports containing personal data use RLS to restrict access
- [ ] Data subject access request (DSAR) process defined for Power BI datasets
- [ ] Retention of audit logs aligned with GDPR Art. 30 record-keeping

### HIPAA
- [ ] Microsoft BAA signed covering Power BI Service
- [ ] PHI-containing reports deployed only to capacities in BAA-covered regions
- [ ] Encryption at rest verified (Microsoft-managed + BYOK option if required)
- [ ] Breach notification workflow includes Power BI audit log review

### PCI-DSS
- [ ] No cardholder data in reports (design-level — enforce in validation)
- [ ] If any scope: environment is isolated with dedicated SP, vault, capacity

## 10. Annual review

This document reviewed and signed off annually by:

- [ ] Security team lead
- [ ] Data Platform lead
- [ ] DevOps lead

**Last reviewed:** <date>
**Next review:** <date + 12 months>
