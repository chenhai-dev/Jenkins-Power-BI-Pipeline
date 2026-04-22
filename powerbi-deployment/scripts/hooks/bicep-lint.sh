#!/usr/bin/env bash
# =============================================================================
# Pre-commit hook: validate all staged .bicep files compile cleanly.
# =============================================================================
set -euo pipefail

if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: Azure CLI not found. Install from https://aka.ms/InstallAzureCLI"
    exit 1
fi

# Ensure bicep is installed
if ! az bicep version >/dev/null 2>&1; then
    echo "Installing bicep..."
    az bicep install
fi

# Find staged bicep files
staged_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.bicep$' || true)

if [ -z "$staged_files" ]; then
    echo "No staged .bicep files. Skipping."
    exit 0
fi

failed=0
for file in $staged_files; do
    if [ ! -f "$file" ]; then
        continue
    fi
    echo "Validating: $file"
    if ! az bicep build --file "$file" --stdout > /dev/null 2>&1; then
        echo "FAIL: $file"
        az bicep build --file "$file" --stdout
        failed=1
    fi
done

if [ $failed -ne 0 ]; then
    echo "✗ Bicep validation failed"
    exit 1
fi

echo "✓ All Bicep files valid"
exit 0
