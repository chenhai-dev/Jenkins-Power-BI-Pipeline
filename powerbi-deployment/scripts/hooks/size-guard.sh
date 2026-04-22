#!/usr/bin/env bash
# =============================================================================
# Pre-commit hook: block commits of reports larger than 500MB
# =============================================================================
# .pbix files > 500MB often indicate a model that should be using Large Dataset
# storage format or DirectQuery. Block at the source.
#
# Power BI Service import limit is 1GB; we block at 500MB to encourage earlier
# conversations about model optimization.

set -euo pipefail

MAX_SIZE_BYTES=524288000   # 500 MB

staged_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(pbix|rdl)$' || true)

if [ -z "$staged_files" ]; then
    exit 0
fi

violations=0
while IFS= read -r file; do
    if [ ! -f "$file" ]; then
        continue
    fi

    # stat -c works on Linux; on macOS use stat -f
    if stat -c%s "$file" >/dev/null 2>&1; then
        size=$(stat -c%s "$file")
    else
        size=$(stat -f%z "$file")
    fi

    size_mb=$((size / 1024 / 1024))

    if [ "$size" -gt "$MAX_SIZE_BYTES" ]; then
        echo "✗ $file is ${size_mb}MB (limit 500MB)"
        echo "  → Consider Large Dataset format, DirectQuery, or model optimization"
        violations=$((violations + 1))
    else
        echo "✓ $file (${size_mb}MB)"
    fi
done <<< "$staged_files"

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "Blocked $violations file(s) exceeding size limit."
    echo "See: docs/TROUBLESHOOTING.md → 'File > 1 GB'"
    exit 1
fi

exit 0
