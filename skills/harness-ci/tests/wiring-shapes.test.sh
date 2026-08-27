#!/usr/bin/env bash
# The wiring shapes are the deliverable a consumer copies, so they are checked
# rather than trusted: every workflow expression stays on one line, and the
# script path they name is the path this package ships.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

WIRING="$TEST_DIR/../references/wiring.md"
[ -f "$WIRING" ] || { echo "missing $WIRING" >&2; exit 1; }

# Only the fenced yaml blocks, with the fences dropped.
yaml_lines() {
  awk '/^```yaml$/ { inblock = 1; next } /^```$/ { inblock = 0; next } inblock' "$WIRING"
}

blocks="$(yaml_lines)"
[ -n "$blocks" ] || { echo "no yaml blocks found in $WIRING" >&2; exit 1; }

# A folded scalar whose continuations are indented past its first line keeps
# the newlines instead of folding them, turning a wrapped expression into a
# multi-line one. One line per expression removes the trap outright.
unclosed="$(printf '%s\n' "$blocks" | grep -F '${{' | grep -vF '}}' || true)"
assert_eq "every workflow expression closes on its own line" "" "$unclosed"

# The path the shapes tell a consumer to run is the path this package ships.
# EVERY citation, not only the ones already ending in the script's name: a
# rename that reached one call site and not the rest has to fail here.
cited="$(printf '%s\n' "$blocks" | grep -oE '\.agents/skills/[A-Za-z0-9_/.-]+' | sort -u)"
assert_eq "the shapes name one script path" ".agents/skills/harness-ci/scripts/harness-only" "$cited"
assert_eq "that path is the one this package ships" "yes" \
  "$([ -x "$TEST_DIR/../scripts/harness-only" ] && echo yes || echo no)"

# Every flag the shapes pass is one the script accepts.
unknown_flags=""
for flag in $(printf '%s\n' "$blocks" | grep -oE '(^|[[:space:]])--[a-z-]+' | tr -d ' ' | sort -u); do
  case "$flag" in
    --event | --base | --head | --repo | --output) ;;
    *) unknown_flags="$unknown_flags $flag" ;;
  esac
done
assert_eq "the shapes pass only flags the script accepts" "" "$unknown_flags"

# The push endpoints come from the event payload, with `github.sha` LAST. On a
# branch-deletion push `github.event.after` is the all-zero sha and
# `github.sha` is the default branch tip, so a HEAD expression reaching
# `github.sha` before `after` would hand the classifier two real commits.
heads="$(printf '%s\n' "$blocks" | grep -F 'HEAD:' || true)"
assert_eq "the shapes carry a HEAD expression" "3" "$(printf '%s\n' "$heads" | grep -c 'HEAD:')"
misordered="$(printf '%s\n' "$heads" | grep -vE 'github\.event\.after[^|]*\|\|[^|]*github\.sha' || true)"
assert_eq "every HEAD expression tries github.event.after before github.sha" "" "$misordered"

# The parser is a REQUIREMENT, not a convenience. Announcing a skip and then
# reporting the suite green is the fail-open this file exists to close: the
# check that catches a malformed block is the one that would not have run.
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "harness-ci wiring-shapes needs python3 with PyYAML (pip install pyyaml)" >&2
  exit 1
fi

parsed="$(python3 - "$WIRING" <<'PY'
import re, sys, yaml
src = open(sys.argv[1]).read()
for i, block in enumerate(re.findall(r"```yaml\n(.*?)```", src, re.S), 1):
    body = block if block.lstrip().startswith(("env:", "jobs:")) else "jobs:\n" + block
    try:
        yaml.safe_load(body)
    except Exception as exc:
        print(f"block {i}: {exc}")
        sys.exit(0)
print("ok")
PY
)"
assert_eq "every shape parses as YAML" "ok" "$parsed"

report wiring-shapes
