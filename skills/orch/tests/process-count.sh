#!/usr/bin/env bash
# The shared process instrument maps synthetic IDs without checking liveness.
# Its direct-target mode excludes stub children and counts each PID once.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'process-count: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "process-count: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'process-count: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
python3 - "$TEST_DIR/lib/process-count.py" "$TMP_ROOT" <<'PY'
import importlib.util
from pathlib import Path
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
print(f"pass: {len(rows) + 2}   fail: 0")
PY
