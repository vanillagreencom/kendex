#!/usr/bin/env bash
# Regression tests for kendex#705: `workflow-state set` stores non-JSON values
# as RAW strings — it never parses JSON string literals. submit-pr § 4 used to
# document `set … pr_review.mode '"[GATE_MODE]"'`, which stored the quote
# characters literally (serialized `"\"review\""`) and broke the § 6.1 gate 4
# mode comparison. Pinned here:
#   1. set semantics: a `{`/`[` prefix, exactly null/true/false, or an
#      all-digit value splices as JSON; every other value — including one that
#      starts with a double quote — is stored verbatim via `jq --arg`.
#      `append` shares the `{`/`[` hybrid; `update` is always a jq expression.
#   2. The fixed submit-pr § 4 shape (bare `[GATE_MODE]`) stores a clean
#      string, and the § 6.1 gate 4 read resolves a recorded mode and a state
#      with none recorded alike.
#   3. Docs lint (with injected-offender teeth): no `workflow-state set` line
#      in skills/**/*.md may wrap its value in the `'"…"'` idiom.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
SUBMIT_DOC="$REPO_ROOT/skills/orch/workflows/submit-pr.md"

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -qF "$needle" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing in %s: %s\n' "$name" "$file" "$needle"
  fi
}

echo "=== workflow-state set raw-string semantics (kendex#705) ==="

# --- Part 1: set / update / append value semantics -------------------------

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init issue-705 \
  --worktree "$REPO_ROOT" --branch issue-705 >/dev/null
sf="$sd/workflow-state-issue-705.json"

# Test 1: a bare string stores a clean JSON string.
"$WS" --state-dir "$sd" set issue-705 pr_review.mode review
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"review"' \
  "bare-string set stores a clean JSON string"

# Test 2 (pinned raw semantics): a pre-quoted value stores the quote
# characters literally — set never parses JSON string literals.
"$WS" --state-dir "$sd" set issue-705 pr_review.mode '"review"'
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"\"review\""' \
  "pre-quoted set stores literal quote characters (raw-string semantics)"

# Test 3: JSON-looking values splice as JSON; `off` is none of them.
"$WS" --state-dir "$sd" set issue-705 pr_review_baseline '{"last_threads":["PRRT_t"]}'
assert_eq "$(jq -r '.pr_review_baseline | type' "$sf")" "object" \
  "set splices a {…} value as a JSON object"
"$WS" --state-dir "$sd" set issue-705 review_agents '["a"]'
assert_eq "$(jq -c '.review_agents' "$sf")" '["a"]' \
  "set splices a […] value as a JSON array"
"$WS" --state-dir "$sd" set issue-705 skip_qa true
assert_eq "$(jq -c '.skip_qa' "$sf")" "true" \
  "set splices true as a JSON boolean"
"$WS" --state-dir "$sd" set issue-705 pre_delegate_sha null
assert_eq "$(jq -r '.pre_delegate_sha | type' "$sf")" "null" \
  "set splices null as JSON null"
"$WS" --state-dir "$sd" set issue-705 cycles 7
assert_eq "$(jq -c '.cycles' "$sf")" "7" \
  "set splices an all-digit value as a JSON number"
"$WS" --state-dir "$sd" set issue-705 pr_review.mode off
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"off"' \
  "set stores off as the clean string it looks like"

# Test 4: update is a jq expression — string literals need their JSON quotes.
"$WS" --state-dir "$sd" update issue-705 '.pr_review.mode = "off"'
assert_eq "$(jq -c '.pr_review.mode' "$sf")" '"off"' \
  "update applies jq-expression (JSON) semantics"

# Test 5: append shares the hybrid — bare strings verbatim, {/[ as JSON.
"$WS" --state-dir "$sd" append issue-705 json_paths plain.json
"$WS" --state-dir "$sd" append issue-705 json_paths '"quoted.json"'
"$WS" --state-dir "$sd" append issue-705 fixed_items '{"description":"x"}'
assert_eq "$(jq -c '.json_paths' "$sf")" '["plain.json","\"quoted.json\""]' \
  "append stores bare strings clean and pre-quoted strings verbatim"
assert_eq "$(jq -r '.fixed_items[0] | type' "$sf")" "object" \
  "append splices a {…} value as a JSON object"

# --- Part 2: documented § 4 shape + § 6.1 gate 4 read ----------------------

GATE4_READ='.pr_review.mode // ""'

# Clean state written by the fixed § 4 command.
"$WS" --state-dir "$sd" init issue-705c \
  --worktree "$REPO_ROOT" --branch issue-705 >/dev/null
"$WS" --state-dir "$sd" set issue-705c pr_review.mode off
assert_eq "$("$WS" --state-dir "$sd" get issue-705c "$GATE4_READ")" "off" \
  "gate 4 read resolves a clean recorded mode"

# Nothing recorded at all → empty output AND exit 0. A get that FAILS prints
# nothing either, and a command substitution in an argument does not trip
# set -e, so comparing stdout alone passes on a broken read. Status and output
# are asserted together.
"$WS" --state-dir "$sd" init issue-705e \
  --worktree "$REPO_ROOT" --branch issue-705 >/dev/null
out="$("$WS" --state-dir "$sd" get issue-705e "$GATE4_READ")" && rc=0 || rc=$?
assert_eq "$rc|$out" "0|" \
  "gate 4 read yields empty and exits 0 when no mode was recorded"

# Teeth: the same read against a record that is not there exits 1 on empty
# stdout, the shape the assertion above used to accept.
out="$("$WS" --state-dir "$sd" get issue-705x "$GATE4_READ" 2>/dev/null)" && rc=0 || rc=$?
assert_eq "$([[ "$rc|$out" != "0|" ]] && echo flagged)" "flagged" \
  "the empty-state assertion reds on a failing read, not just a non-empty one"

# The docs must carry exactly these shapes.
assert_file_contains "$SUBMIT_DOC" \
  "workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]" \
  "submit-pr records the gate mode as a bare word"
assert_file_contains "$SUBMIT_DOC" "$GATE4_READ" \
  "submit-pr gate 4 documents the recorded-mode read"

# --- Part 3: docs lint — no set line may carry a '"…"'-wrapped value -------

# scan_set_quoted <file>
# Emits every line that invokes `workflow-state set` (the helper path token
# followed by the plain `set` subcommand) AND contains the two-character
# sequence  '"  — the single-quoted-double-quote idiom. The JSON-object idiom
# `set … '{"k":…}'` never puts those two characters adjacent, so it is not
# flagged; neither are set-git-head/set-now lines (no ` set ` token).
scan_set_quoted() {
  grep -n "scripts/workflow-state" "$1" 2>/dev/null \
    | grep " set " | grep -F "'\"" || true
}

offenders=""
while IFS= read -r doc; do
  out="$(scan_set_quoted "$doc")"
  [[ -n "$out" ]] && offenders+="$doc: $out"$'\n'
done < <(find "$REPO_ROOT/skills" -name '*.md' | LC_ALL=C sort)

if [[ -z "$offenders" ]]; then
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "no skills doc passes workflow-state set a quote-wrapped value"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "workflow-state set lines carry '\"…\"'-wrapped values:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# Teeth: the scanner flags an injected offender and accepts the legal shapes.
scratch="$TMP_ROOT/inject.md"

printf '%s\n' ".agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode '\"[GATE_MODE]\"'" > "$scratch"
assert_eq "$([[ -n "$(scan_set_quoted "$scratch")" ]] && echo flagged)" "flagged" \
  "lint flags a set line with a '\"…\"'-wrapped value"

printf '%s\n' ".agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review.mode [GATE_MODE]" > "$scratch"
assert_eq "$([[ -z "$(scan_set_quoted "$scratch")" ]] && echo clean)" "clean" \
  "lint accepts the bare-word set shape"

printf '%s\n' ".agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_review_baseline '{\"last_threads\":[\"PRRT_x\"]}'" > "$scratch"
assert_eq "$([[ -z "$(scan_set_quoted "$scratch")" ]] && echo clean)" "clean" \
  "lint accepts the JSON-object set idiom"

printf '%s\n' ".agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha '\"x\"'" > "$scratch"
assert_eq "$([[ -z "$(scan_set_quoted "$scratch")" ]] && echo clean)" "clean" \
  "lint scopes to the plain set subcommand (set-git-head untouched)"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
