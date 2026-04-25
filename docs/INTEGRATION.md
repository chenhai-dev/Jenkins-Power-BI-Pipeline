# Integration Checklist

Steps to integrate this Power BI deployment library into the existing
`feature/powerbi-pipeline` branch of `mfc-innersource/eng-jenkins-pipeline-lib`.

## 1. Rebase first (this branch is 4734 commits behind master)

```bash
git checkout feature/powerbi-pipeline
git fetch origin master
git rebase origin/master
# Resolve conflicts. Pay particular attention to:
#   - vars/ (if shared library conventions changed)
#   - src/com/manulife/ (if package layout changed)
#   - Any common helpers like notification or credential utilities
```

If the rebase is painful, alternative: cherry-pick this work onto a fresh
branch off current master and discard the year-old `feature/powerbi-pipeline`
branch.

## 2. Replace the misnamed Groovy file

The existing `vars/pipelineJavaPowerBI-KH.groovy` is **not callable as a step**
because Jenkins requires `var` filenames to be valid Groovy identifiers
(letters/digits/underscores). The hyphen breaks step registration silently.

```bash
git rm vars/pipelineJavaPowerBI-KH.groovy
# Add the new file:
cp <staging>/vars/pipelineJavaPowerBI_KH.groovy vars/
```

Verify by searching the org for any consumer that already calls
`pipelineJavaPowerBI-KH(...)`. None should exist (it never worked), but if
any do, they need to be updated to the new underscore name in the same PR
to avoid breaking them.

## 3. Drop in the rest of the files

```bash
# Source classes
mkdir -p src/com/manulife/powerbi
cp <staging>/src/com/manulife/powerbi/*.groovy src/com/manulife/powerbi/

# PowerShell resources
mkdir -p resources/com/manulife/powerbi/scripts
cp <staging>/resources/com/manulife/powerbi/scripts/*.ps1 resources/com/manulife/powerbi/scripts/

# Per-app config
mkdir -p resources/com/manulife/powerbi/config
cp <staging>/resources/com/manulife/powerbi/config/*.json resources/com/manulife/powerbi/config/

# Tests
mkdir -p test/groovy/com/manulife/powerbi
cp <staging>/test/groovy/com/manulife/powerbi/*.groovy test/groovy/com/manulife/powerbi/

# Docs and examples
cp <staging>/docs/README-powerbi.md docs/
cp <staging>/examples/Jenkinsfile.kh-d2c examples/
```

## 4. Update the workspace IDs

Every config file in `resources/com/manulife/powerbi/config/` has placeholder
GUIDs. Get the real workspace IDs from your Power BI admin and substitute:

```bash
# Get workspace ID from URL: https://app.powerbi.com/groups/<GUID>/list
sed -i 's/REPLACE-WITH-DEV-WORKSPACE-GUID/<actual-dev-guid>/' \
    resources/com/manulife/powerbi/config/KH-D2C-DEV.json
# repeat for TEST, UAT, PROD
```

## 5. Run unit tests locally

```bash
./gradlew test --tests com.manulife.powerbi.*
```

All eight tests in `PowerBIDeploymentConfigTest` should pass. If the
pipeline-lib repo doesn't already have a Gradle test harness, see the
existing `test/` folder for whatever test runner pattern it uses.

## 6. Onboard the Jenkins agent(s)

On every Windows agent labelled `windows-powerbi`, run as Administrator:

```powershell
.\resources\com\manulife\powerbi\scripts\Bootstrap-JenkinsAgent.ps1
```

This installs `MicrosoftPowerBIMgmt`, `Az.Accounts`, and enables TLS 1.2.

## 7. Create the Jenkins credentials

Three credentials of type "Secret text", per `(app, env)` pair. For KH-D2C:

| Credential ID                     | Value                                 |
|-----------------------------------|---------------------------------------|
| `pbi-kh-d2c-dev-tenant-id`        | Azure AD tenant GUID                  |
| `pbi-kh-d2c-dev-client-id`        | Service principal application GUID    |
| `pbi-kh-d2c-dev-client-secret`    | Service principal client secret value |
| `pbi-kh-d2c-test-tenant-id`       | (typically same as DEV)               |
| `pbi-kh-d2c-test-client-id`       | (separate SP per env recommended)     |
| `pbi-kh-d2c-test-client-secret`   |                                       |
| ... (UAT, PROD)                   |                                       |

Use folder-scoped credentials so only the KH-D2C jobs have access.

## 8. Smoke test

In the consuming app repo (e.g. `KH-D2C`), drop in
`examples/Jenkinsfile.kh-d2c`. Create a Jenkins pipeline pointing at it.

First run:
- `TARGET_ENV = DEV`
- `DRY_RUN = true`

All stages should be green. Then re-run with `DRY_RUN = false` and verify
the report appears in the DEV workspace.

## 9. Pre-merge checklist

- [ ] Rebased onto current `master`
- [ ] Old `pipelineJavaPowerBI-KH.groovy` (hyphen) removed
- [ ] New `pipelineJavaPowerBI_KH.groovy` (underscore) added
- [ ] All unit tests pass
- [ ] Workspace IDs filled in for at least DEV
- [ ] Smoke-tested with DRY_RUN against DEV
- [ ] Smoke-tested with real publish against DEV
- [ ] PR description includes link to the smoke-test build
- [ ] Reviewer added from platform team
