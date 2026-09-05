#!/usr/bin/env bash
# The CI command runs the CANDIDATE's checker on the candidate spec and
# rejects stale generated files. This repository is the package's source, so
# a change to the renderer or the derivation is judged by itself; the trusted
# default-branch checker is the consumer rule, and here it reported drift by
# construction on every such change.
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

# The candidate's checker is what runs: a stub in the candidate's own package
# copy decides the exit code. With a trusted-checkout checker this stub would
# never be reached.
mkdir -p "$spec/scripts" || exit 1
printf '#!/usr/bin/env bash\nexit 3\n' >"$spec/scripts/bot-instructions"
chmod +x "$spec/scripts/bot-instructions" || exit 1
output="$(cd "$runner" && bash -c "$command" 2>&1)" && status=0 || status=$?
[ "$status" -eq 3 ] && ok "CI runs the candidate's checker" \
  || bad "CI runs the candidate's checker" "exit $status: $output"

# The real package in the candidate's copy: a clean candidate passes and a
# stale one is refused, so the wiring judges what it reads.
rm -rf -- "${spec:?}/scripts"
python3 - "$BI_ROOT/skills/bot-instructions/scripts" "$spec/scripts" <<'PY' || exit 1
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
PY
output="$(cd "$runner" && bash -c "$command" 2>&1)" && status=0 || status=$?
[ "$status" -eq 0 ] && ok "a clean candidate passes its own checker" \
  || bad "a clean candidate passes its own checker" "exit $status: $output"
if python3 - "$spec" <<'PY'; then
from pathlib import Path
import sys
assert not list(Path(sys.argv[1]).rglob('*.pyc')), 'the checker wrote bytecode into its package files'
PY
  ok "running the checker leaves its package files unchanged"
else
  bad "running the checker leaves its package files unchanged"
fi

printf '\nStale instructions.\n' >>"$candidate/.github/copilot-instructions.md"
output="$(cd "$runner" && bash -c "$command" 2>&1)" && status=0 || status=$?
if [ "$status" -eq 1 ] && [[ "$output" == *"drift:"*".github/copilot-instructions.md"* ]]; then
  ok "CI refuses stale candidate output"
else
  bad "CI refuses stale candidate output" "exit $status: $output"
fi
bi_summary
