#!/usr/bin/env bash
# `workflow-state append-file <id> <path> <file>`: reviewer text never crosses
# argv. A cause reaches the state byte for byte through a file, the array is
# created where the field is absent, anything that is not exactly one JSON
# value is refused with the record untouched, and no workflow spells the
# append by hand. Split from workflow-state-cycle-cap.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo
echo "--- workflow-state append-file ---"

cd_sd="$TMP_ROOT/append-state"
"$WS" --state-dir "$cd_sd" init KEN-CAP --worktree "$REPO_ROOT" --branch ken-cap >/dev/null

cause="$TMP_ROOT/cause.json"
# A cause carrying every character that ends a shell word early. It reaches
# the state byte for byte, or the command was not the file-bound one.
python3 - "$cause" <<'PYW'
import json, sys
json.dump({"cause": "fs.rs::write_all's guard \"quoted\" $(whoami) `id` | ;", "commit": "abc1234"},
          open(sys.argv[1], "w"))
PYW
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
# The type is read beside the length: jq counts an object's keys under the
# same operator, and the fixture object has two, so a bare assignment would
# read as two appended entries.
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes | "\(type):\(length)"')"
[[ "$got" == "array:2" ]] && ok "append-file appends rather than replacing" \
  || bad "append-file appends rather than replacing" "got=$got"
want="$(jq -r .cause "$cause")"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes[0].cause')"
[[ "$got" == "$want" ]] && ok "the cause reaches the state verbatim, shell metacharacters and all" \
  || bad "the cause reaches the state verbatim, shell metacharacters and all" "got=$got"

# The array is created where the field is absent — the // [] the workflows
# would spell at every call site.
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.frozen_causes "$cause" >/dev/null
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.frozen_causes | length')"
[[ "$got" == "1" ]] && ok "append-file creates the array when the field is absent" \
  || bad "append-file creates the array when the field is absent" "got=$got"

# Fails closed on anything that is not exactly one JSON value: a truncated or
# doubled write must not reach the record the recurrence rule reads.
printf 'not json\n' > "$TMP_ROOT/bad.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/bad.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file that is not JSON" || bad "append-file refuses a file that is not JSON"
printf '{"a":1}\n{"b":2}\n' > "$TMP_ROOT/two.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/two.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file holding two values" || bad "append-file refuses a file holding two values"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/nope.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a missing file" || bad "append-file refuses a missing file"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes | length')"
[[ "$got" == "2" ]] && ok "a refused append leaves the record untouched" \
  || bad "a refused append leaves the record untouched" "got=$got"

# The workflows that record a cause come through it — no second spelling of
# the append jq survives.
append_strays() { grep -rnF 'patched_causes // []) + [' "$1" 2>/dev/null || true; }
stray="$(append_strays "$REPO_ROOT/skills/orch/workflows")"
[[ -z "$stray" ]] && ok "no workflow spells the patched_causes append by hand" \
  || bad "no workflow spells the patched_causes append by hand" "$stray"
# Planted: the hand-spelled jq the workflows would carry.
CTRL_DIR="$TMP_ROOT/append-stray-workflows"
mkdir -p "$CTRL_DIR"
cat > "$CTRL_DIR/dev-fix.md" <<'CTRL'
workflow-state update [ISSUE_ID] --slurpfile e f '$e[0] as $x | .pr_comment_review.patched_causes = ((.pr_comment_review.patched_causes // []) + [$x])'
CTRL
[[ -n "$(append_strays "$CTRL_DIR")" ]] && ok "the stray check flags a workflow spelling the append by hand" \
  || bad "the stray check flags a workflow spelling the append by hand"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
