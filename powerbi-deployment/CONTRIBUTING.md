# Contributing

Thanks for improving this pipeline. This guide keeps the codebase consistent and the Prod path safe.

## Ground rules

- `main` is always deployable to Prod.
- Every change reaches `main` via PR. No direct pushes.
- PRs require CODEOWNERS approval (see `CODEOWNERS`).
- Secrets never hit the repo. Period. Use Key Vault.

## Local setup

```bash
# 1. Clone
git clone <repo-url>
cd powerbi-deployment

# 2. Install tooling
pip install pre-commit detect-secrets
pre-commit install

# 3. Install PowerShell dependencies
pwsh -c "Install-Module MicrosoftPowerBIMgmt, powershell-yaml, Pester, PSScriptAnalyzer, Az.KeyVault, Az.Storage -Scope CurrentUser -Force"

# 4. (Optional) Azure CLI for Bicep builds
az bicep install

# 5. Create secrets baseline for detect-secrets
detect-secrets scan > .secrets.baseline
```

## Development workflow

### For pipeline / script changes

1. Branch: `feature/<short-description>` or `fix/<short-description>`
2. Make changes
3. Run locally:
   ```powershell
   Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning
   Invoke-Pester -Path ./tests
   ```
4. Run pre-commit:
   ```bash
   pre-commit run --all-files
   ```
5. Push, open PR
6. Pipeline runs validate → Dev → pause for Test approval → Test → pause for Prod approval → Prod

### For report changes

1. Branch: `report/<report-name>` or `feature/<descriptive>`
2. Drop new/updated `.pbix` or `.rdl` in `reports/`
3. Update `config/*.yaml` `reports:` section for each environment
4. Run pre-deployment validation locally:
   ```powershell
   ./scripts/Invoke-PreDeploymentValidation.ps1 `
       -ArtifactPath ./reports `
       -Environment Prod `
       -ConfigPath ./config/prod.yaml
   ```
5. Push, open PR

### For infrastructure changes

1. Branch: `infra/<change>`
2. Edit `infrastructure/main.bicep` or parameter files
3. Validate locally:
   ```bash
   az bicep build --file infrastructure/main.bicep --stdout > /dev/null
   az deployment group what-if \
       --resource-group rg-analytics-dev \
       --template-file infrastructure/main.bicep \
       --parameters infrastructure/dev.bicepparam
   ```
4. Infrastructure PRs require @org/cloud-security review
5. Deploy to Dev first, observe 24 h, then promote

## Code style

### PowerShell

- PowerShell 7.2+ syntax allowed and encouraged
- Use `[CmdletBinding()]` on all public functions
- Use approved verbs (`Get-Verb` in PowerShell)
- `Set-StrictMode -Version Latest` at file top
- `$ErrorActionPreference = 'Stop'` at file top
- Structured logging via `Write-DeploymentLog`, never `Write-Host` for anything durable
- Secrets: always `[SecureString]` parameters, never `[string]`
- Test all error paths with Pester

### Bicep

- Always use `targetScope` explicitly
- Use `@description()` on every parameter
- Use `@allowed()`, `@minValue()`, `@maxValue()` for validation
- Emit `output` for anything consumed by other stacks
- Resource names: `<type>-<purpose>-<env>`, lowercase, hyphen-separated

### YAML

- 2-space indent
- No tabs
- Comments liberally

## Testing

| Level | What | When |
|-------|------|------|
| Unit | `tests/*.Tests.ps1` | Every commit — runs in pipeline |
| Integration | `tests/integration/*.Tests.ps1` | Nightly on Dev workspace |
| E2E | Full pipeline Dev→Test→Prod | Every merge to `main` |

To run integration tests locally:

```powershell
$env:PBI_TEST_TENANT_ID     = "<tenant>"
$env:PBI_TEST_CLIENT_ID     = "<dev-sp-client-id>"
$env:PBI_TEST_CLIENT_SECRET = "<secret>"
$env:PBI_TEST_WORKSPACE_ID  = "<dev-workspace-id>"

Invoke-Pester -Path ./tests/integration -Tag Integration
```

## Commit message convention

Use Conventional Commits:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `security`

Examples:
```
feat(module): add OAuth2 credential binding support
fix(deploy): retry on transient 429 from imports API
docs(runbooks): clarify rollback identification of prior artifact
security(deps): pin MicrosoftPowerBIMgmt to 1.2.1111 (CVE-2024-*)
```

## Review checklist (for reviewers)

- [ ] PR description explains the "why"
- [ ] Linked to a change ticket if touching Prod config
- [ ] Tests added or updated
- [ ] No new hardcoded values that should be parameters
- [ ] Documentation updated (runbook, README, config example)
- [ ] Security review requested if: touching `infrastructure/`, auth code, or secret handling
- [ ] Breaking changes clearly flagged

## Releasing

- Each PR merged to `main` auto-deploys to Dev
- Tag releases semver on `main`: `git tag v1.2.3 && git push --tags`
- Create a GitHub Release with notes for anything deployed to Prod
- Release notes link to the pipeline run and the change ticket

## Getting help

- `#data-platform-help` Slack for questions
- `#data-platform-oncall` for urgent issues
- File issues in this repo for bugs / feature requests
