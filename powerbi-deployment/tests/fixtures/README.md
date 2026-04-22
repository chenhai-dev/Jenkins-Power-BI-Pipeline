# Test Fixtures

Sample artifacts used by integration tests. These are intentionally minimal.

## Files

### `sample.rdl`

Minimal Power BI Paginated Report (RDL 2016 schema). Contains:
- Single inline data source (`SYSTEM.DATA.DATASET` — no real connection)
- One dataset with static query returning `SELECT 1 AS Id, 'Integration Test' AS Label`
- One Tablix with 2 columns (Id, Label) and a header row

Used by `tests/integration/Integration.Tests.ps1` to verify `.rdl` publish path.

### `sample.pbix` (not committed — see below)

A minimal `.pbix` is binary and not suitable to commit. To produce one for integration tests:

1. Open Power BI Desktop
2. **Get Data → Enter Data**
3. Create a single-column table with one row
4. **Save as** `tests/fixtures/sample.pbix`
5. **Do not commit.** Instead, add to `.gitignore` and produce it in the integration test pipeline from a known source.

If your CI produces the fixture at test time, add a step like:

```yaml
- name: Build sample .pbix fixture
  shell: pwsh
  run: |
    # Use pbi-tools or similar to build from a pbip project under source control
    pbi-tools compile-pbix ./tests/fixtures/sample-pbip --out ./tests/fixtures/sample.pbix
```

(`pbi-tools` is a third-party project; evaluate for your supply chain policy before adopting.)

## Note on secrets

These fixtures contain **no** credentials, connection strings, or sensitive data. The `sample.rdl` data source is deliberately `SYSTEM.DATA.DATASET` with an empty connect string. If you modify these fixtures, run:

```bash
gitleaks detect --config ../../.gitleaks.toml --source .
```

before committing.
