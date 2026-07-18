#!/usr/bin/env bash
# Regression lint for vstack#641: dev workflow docs must never present an
# unsupported decider issue-lookup shape. Generated dev-fix guidance once told
# a specialist to run `decisions issue CC-125`; the CLI has no `issue` action —
# the supported lookup is `decisions search --issue CC-125`. Rule (per physical
# line, prose and code alike, since guidance text is what agents relay): flag
# `decisions issue <ID>` / `decisions issues <ID>` and the `decisions show
# --issue` near-miss. The supported `decisions search --issue` never matches —
# `search` sits between the two tokens. Also asserts workflows/dev-fix.md still
# carries the supported form. Hermetic: scans files on disk only, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

offenders=0

while IFS= read -r -d '' file; do
  matches="$(grep -nE 'decisions[[:space:]]+(issues?([^a-zA-Z0-9_-]|$)|show[[:space:]]+--issue)' "$file" || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" | sed "s|^|$file:|"
    offenders=$((offenders + 1))
  fi
done < <(find "$SKILL_DIR" -maxdepth 2 -type f -name '*.md' -not -path '*/tests/*' -print0)

if (( offenders > 0 )); then
  echo "FAIL: $offenders file(s) use an unsupported decisions issue-lookup shape (use 'decisions search --issue')"
  exit 1
fi

if ! grep -q 'decisions search --issue' "$SKILL_DIR/workflows/dev-fix.md"; then
  echo "FAIL: workflows/dev-fix.md lost the supported 'decisions search --issue' lookup"
  exit 1
fi

echo "all pass"
