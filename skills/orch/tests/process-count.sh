#!/usr/bin/env bash
# The shared process instrument maps synthetic IDs without checking liveness.
# Its direct-target mode excludes stub children and counts each PID once.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'process-count: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "process-count: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'process-count: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
python3 - "$TEST_DIR/lib/process-count.py" "$TMP_ROOT" "$BASH" "${BASHPID:-}" <<'PY'
import importlib.util
from contextlib import redirect_stdout
from io import StringIO
import os
from pathlib import Path
import subprocess
import sys


def load(path):
    spec = importlib.util.spec_from_file_location("counter", path)
    counter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(counter)
    return counter


source = Path(sys.argv[1])
counter = load(source)
trace = ["+count:100: start", "++count:101: exec gh", "++count:102: substitution"]
external = ["w 101 100 gh 100", "w 201 101 jq 0", "w 202 102 date 100"]
rows = [
    ("legacy wrapper format", trace, ["w 101 gh", "w 202 date"], {"100"}, False, None, 3),
    ("default counts all external starts", trace, external, {"100"}, False, None, 4),
    ("target excludes its stub child", trace, external, {"100"}, True, None, 3),
    ("target counts an exec PID once", trace, external + ["w 101 100 bash 100"], {"100"}, True, None, 3),
    ("target counts an untraced pipeline parent", trace, external + ["w 203 105 jq 100"], {"100"}, True, None, 5),
    ("target counts its gh command", trace, external, {"100"}, True, "gh", 1),
    ("target excludes its stub jq command", trace, external, {"100"}, True, "jq", 0),
    ("target counts a subshell command", trace, external, {"100"}, True, "date", 1),
    ("trace stops at the watch marker", ["+count:100: start", "count:end", "+count:999: later"], [], {"100"}, False, None, 0),
]


def failures(module):
    return [label for label, *args, want in rows if module.total(*args) != want]


assert not failures(counter), failures(counter)
pass_trace = [
    "+count:100:mail_turn.check_mail: call",
    "++count:101:mail_turn.check_mail: substitution",
    "++count:102:long_pass.observe_lanes: exec tmux",
    "++count:104:outside: setup",
]
pass_external = [
    "102 100 100 long_pass.observe_lanes",
    "201 102 0 long_pass.observe_lanes",
    "103 105 100 long_pass.check_lanes",
]
want_passes = {"mail_turn.check_mail": 1, "long_pass.observe_lanes": 1, "long_pass.check_lanes": 2}
assert counter.pass_counts(pass_trace, pass_external, {"100"}) == want_passes
complete_rows = [
    "101 100 0 mail_turn.fixture",
    "102 101 0 mail_turn.fixture",
    "103 102 0 outside",
    "104 100 fixture mail_turn.fixture",
    "105 104 0 outside",
]
assert counter.pass_counts([], complete_rows, {"100"}, True) == {"mail_turn.fixture": 4}
text = source.read_text()
old = 'if owner in existing and step.startswith('
assert text.count(old) == 1
mutated = text.replace(old, 'if step.startswith(')
assert mutated != text
path = Path(sys.argv[2]) / "pass-mutant.py"
path.write_text(mutated)
assert load(path).pass_counts(pass_trace, pass_external, {"100"}) != want_passes, "must-fail: dependency births counted as watch starts"
old = "and parent not in fixtures"
assert text.count(old) == 1
mutated = text.replace(old, "")
assert mutated != text
path = Path(sys.argv[2]) / "fixture-mutant.py"
path.write_text(mutated)
assert load(path).pass_counts([], complete_rows, {"100"}, True) != {"mail_turn.fixture": 4}, "must-fail: fixture implementation counted as product work"

scratch = Path(sys.argv[2])
raw = scratch / "raw-steps"
raw.mkdir()
(raw / "trace").write_bytes(b"+count:100:mail_turn.check_mail: comparison \xef\\xbb\n++count:101:mail_turn.check_mail: exec git\n")
(raw / "steps").write_text("")
(raw / "existing").write_text("100\n")
output = StringIO()
with redirect_stdout(output):
    counter.steps(raw)
assert dict(line.split("=", 1) for line in output.getvalue().splitlines()) == {
    "mail_turn.check_mail": "1", "mail_turn": "1", "long_pass": "0",
}
old = 'errors="surrogateescape"'
assert text.count(old) == 1
mutated = text.replace(old, 'errors="strict"')
assert mutated != text
path = scratch / "strict-trace.py"
path.write_text(mutated)
try:
    load(path).steps(raw)
except UnicodeDecodeError:
    pass
else:
    raise AssertionError("must-fail: strict step trace decoding accepted raw bytes")

# A real absolute helper starts once. Its own Bash child belongs to the
# dependency, and the watch must not claim it.
target = scratch / "oversee-watch"
helper = scratch / "helper.sh"
target.write_text('mail_turn() { "$BASH" "$1"; }; mail_turn "$1"\n')
helper.write_text('"$BASH" -c ":"\n')


def absolute_helper_count(module, name):
    root = scratch / name
    module.install(root, os.environ["PATH"], sys.argv[3], str(target), "passes")
    subprocess.run([sys.argv[3], str(target), str(helper)], check=True,
                   env={"PATH": str(root / "bin") + os.pathsep + os.environ["PATH"],
                        "BASH_ENV": str(root / "bash-env")})
    return sum(module.pass_counts(
        (root / "trace").read_text().splitlines(),
        (root / "steps").read_text().splitlines(),
        set((root / "existing").read_text().splitlines()),
    ).values())


absolute_checks = 0
if sys.argv[4]:
    assert absolute_helper_count(counter, "absolute") == 1
    old = 'if [[ ${_KENDEX_PROCESS_COUNT_OWNER:-0} != 0 ]]; then'
    assert text.count(old) == 1
    mutated = text.replace(old, 'if false; then')
    assert mutated != text
    path = scratch / "absolute-mutant.py"
    path.write_text(mutated)
    assert absolute_helper_count(load(path), "absolute-control") != 1, "must-fail: absolute helper entry was not counted"
    absolute_checks = 2
for old, new in [
    ("owner in existing and pid not in existing", "pid not in existing"),
    ("elif command == name:", "else:"),
]:
    text = source.read_text()
    assert text.count(old) == 1
    mutated = text.replace(old, new)
    assert mutated != text
    path = Path(sys.argv[2]) / "mutant.py"
    path.write_text(mutated)
    assert failures(load(path)), "must-fail: the planted counter defect passed"
print(f"pass: {len(rows) + 6 + absolute_checks}   fail: 0")
PY
