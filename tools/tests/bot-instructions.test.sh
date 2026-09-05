#!/usr/bin/env bash
# The CI command must use candidate doctrine and reject stale generated files.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/skills/bot-instructions/tests/lib/harness.sh"

candidate="$(bi_new_repo candidate)" || exit 1
spec="$candidate/skills/bot-instructions"
mkdir -p "$spec/schemas" || exit 1
cp "$BI_ROOT/skills/bot-instructions/SKILL.md" "$spec/SKILL.md" || exit 1
cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" "$spec/schemas/renders.md" || exit 1
python3 - "$spec/SKILL.md" <<'PY' || exit 1
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
changed, count = re.subn(r'(?m)^  version: "[^"]+"$', '  version: "candidate"', s)
assert count == 1 and changed != s
p.write_text(changed)
PY
# A pull request can replace its checker with a passing script. CI must use
# the trusted checkout's executable while reading this candidate's doctrine.
mkdir -p "$spec/scripts" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' >"$spec/scripts/bot-instructions"
chmod +x "$spec/scripts/bot-instructions" || exit 1
bi_must adopt --repo "$candidate" --spec "$spec" || exit 1
bi_must render --repo "$candidate" --spec "$spec" || exit 1
bi_commit "$candidate"

command="$(awk '
  $1 == "-" && $2 == "id:" && $3 == "bot-instructions-check" { selected = 1; next }
  selected && $1 == "run:" { sub(/^[[:space:]]*run:[[:space:]]*/, ""); print; found++; selected = 0 }
  END { if (found != 1) exit 1 }
' "$REPO/.github/workflows/skill-tests.yml")" || exit 1
runner="$BI_TMP/runner"
mkdir -p "$runner" || exit 1
ln -s "$candidate" "$runner/candidate" || exit 1
checker="$runner/bot-checker/skills/bot-instructions"
python3 - "$BI_ROOT/skills/bot-instructions" "$checker" <<'PY' || exit 1
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
PY

output="$(cd "$runner" && bash -c "$command" 2>&1)"
status=$?
[ "$status" -eq 0 ] && ok "CI reads the candidate spec through the trusted checker" \
  || bad "CI reads the candidate spec through the trusted checker" "$output"
if python3 - "$checker" <<'PY'; then
from pathlib import Path
import sys
assert not list(Path(sys.argv[1]).rglob('*.pyc')), 'the checker wrote bytecode into its installed files'
PY
  ok "running the checker leaves its package files unchanged"
else
  bad "running the checker leaves its package files unchanged"
fi

printf '\nStale instructions.\n' >>"$candidate/.github/copilot-instructions.md"
output="$(cd "$runner" && bash -c "$command" 2>&1)"
status=$?
if [ "$status" -eq 1 ] && [[ "$output" == *"drift:"*".github/copilot-instructions.md"* ]]; then
  ok "CI refuses stale candidate output"
else
  bad "CI refuses stale candidate output" "exit $status: $output"
fi
bi_summary
