#!/usr/bin/env bash
# Surface: claude-question-attention.sh. Inputs: both claude attention hooks
# and tests/lib/assert.sh. Main-hook fixtures own delivery and cooldown.
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$TEST_DIR/../claude-question-attention.sh}"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "$TEST_DIR/../../tmp/claude-question-attention.XXXXXX")" || { echo 'claude-question-attention-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "claude-question-attention-test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'claude-question-attention-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/lib/assert.sh"
PYTHON="$(command -v python3)"

status=0
"$PYTHON" - "$HOOK" "$BASH" "$TMP_ROOT" <<'PY' || status=$?
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

hook, bash, scratch = sys.argv[1:]
root = Path(scratch)
installed = root / "scope with spaces" / ".claude" / "hooks"
installed.mkdir(parents=True)
companion = installed / "claude-question-attention.sh"
shutil.copyfile(hook, companion)
env = {"HOME": str(root), "PATH": os.defpath}
payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"})

def fire():
    result = subprocess.run([bash, str(companion)], input=payload, capture_output=True,
                            text=True, env=env, timeout=8, cwd=str(root))
    assert result.returncode == 0, (result.returncode, result.stderr)
    return result

missing = fire()
assert missing.stdout == ""
assert missing.stderr.splitlines()[0] == "claude-question-attention: companion=missing"
main = installed / "claude-attention.sh"
# The sibling is the existing admission owner. This forwarding fixture reads
# stdin unchanged and reports its cwd, rather than reimplementing its rules.
main.write_text("#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$PWD\" >&2\ncat\n")
forwarded = fire()
assert forwarded.stdout == payload, repr(forwarded.stdout)
assert forwarded.stderr.strip() == str(root)
main.rename(installed / "claude-attention.sh.disabled")
disabled = fire()
assert disabled.stdout == ""
assert disabled.stderr.splitlines()[0] == "claude-question-attention: companion=missing"
shutil.copyfile(Path(hook).parent / "claude-attention.sh", main)
bin_dir = root / "bin"
bin_dir.mkdir()
(bin_dir / "python3").symlink_to(sys.executable)
tmux = bin_dir / "tmux"
tmux.write_text("#!" + bash + "\n" + '''
set -euo pipefail
case "$1" in
  display-message) printf '%s\\t%s\\n' '%1' '$1' ;;
  list-clients) printf '%s\\t%s\\n' '$1' '%2' ;;
  *) exit 1 ;;
esac
''')
tmux.chmod(0o755)
env.update(PATH=str(bin_dir), TMUX="fixture,1,0", TMUX_PANE="%1",
           XDG_CACHE_HOME=str(root / "cache"))
delivered = fire()
assert json.loads(delivered.stdout) == {"terminalSequence": "\u0007"}
assert delivered.stderr == ""
print("installed companion fixtures passed")
PY
assert_eq "$status" 0 'installed question companion contract'
[ "$FAIL" -eq 0 ]
