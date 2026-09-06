#!/usr/bin/env bash
# The workflow documents that carry dev-round-write's command and its
# additions transport: the live fenced command in dev-fix.md and
# review-pr-comments.md passes the additions path list and no data-file flag,
# the delegation block carries the Adds path list, every scope document points
# at the canonical protected-additions section without restating it, and the
# live command executes against a real worktree and binds its Adds list.
# Each pin has a control that a commented decoy or an inert command cannot
# satisfy. The writer itself is dev_round_write.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# fenced_block_with FILE NEEDLE — the first ```-fenced block holding NEEDLE.
fenced_block_with() {
  awk -v needle="$2" '
    /^[[:space:]]*```/ {
      if (!inside) { inside = 1; block = $0 ORS; next }
      block = block $0 ORS
      if (index(block, needle) > 0) { printf "%s", block; exit }
      inside = 0; block = ""; next
    }
    inside { block = block $0 ORS }
  ' "$1"
}

# delegation_block FILE NEEDLE — the first <delegation_format> block holding NEEDLE.
delegation_block() {
  awk -v needle="$2" '
    /<delegation_format>/ { inside = 1; block = "" }
    inside { block = block $0 ORS }
    /<\/delegation_format>/ && inside {
      if (index(block, needle) > 0) { printf "%s", block; exit }
      inside = 0; block = ""
    }
  ' "$1"
}

# matches TEXT ERE — yes or no.
matches() { grep -Eq -- "$2" <<<"$1" && echo yes || echo no; }

# pins ROW... — one assertion per row: `label~text-variable~ERE~yes-or-no`
# (the separator is ~ so an ERE may carry alternation and anchors).
pins() {
  local row label var re want
  for row in "$@"; do
    IFS='~' read -r label var re want <<<"$row"
    [[ -n "$want" ]] || { printf 'pins: a row with no expectation asserts nothing: %s\n' "$row" >&2; exit 1; }
    assert_eq "$(matches "${!var}" "$re")" "$want" "$label"
  done
}

LIVE_CMD='^[[:space:]]*\.agents/.+dev-round-write .+--adds "'
DATA_FLAG='(^|[[:space:]])--adds-[a-z]+([[:space:]]|$)'
LIVE_DELEGATION='^[[:space:]]*\[If the round may add files: "Adds: \[REPO_RELATIVE_PATHS\]'
SCOPE_REF='^[[:space:]]*[^<[:space:]].*schemas/dev-round\.md.*Protected additions'
SCOPE_CLAIM='Protected additions are|files? (the )?fix round may add|files? this round may add|Omit it to allow none|none allowed|files the orchestrator authorized.*add'

echo "=== the live workflow blocks own the additions transport ==="
for workflow in dev-fix review-pr-comments; do
  FILE="$REPO_ROOT/skills/orch/workflows/$workflow.md"
  ROUND_BLOCK="$(fenced_block_with "$FILE" "dev-round-write --worktree")"
  DELEGATION="$(delegation_block "$FILE" "Adds: [REPO_RELATIVE_PATHS]")"
  pins \
    "$workflow: the live command passes the additions path list~ROUND_BLOCK~$LIVE_CMD~yes" \
    "$workflow: the live command carries no additions data-file flag~ROUND_BLOCK~$DATA_FLAG~no" \
    "$workflow: the live delegation carries the Adds path list~DELEGATION~$LIVE_DELEGATION~yes"
done

echo "=== every scope document points at the canonical protected-additions section and restates nothing ==="
for doc in "$REPO_ROOT/skills/dev/workflows/dev-fix.md" "$REPO_ROOT/skills/orch/workflows/dev-fix.md" \
  "$REPO_ROOT/skills/orch/workflows/review-pr-comments.md" "$WRITE_BIN" "$CHECK"; do
  DOC_TEXT="$(<"$doc")"
  pins \
    "${doc#"$REPO_ROOT/"} points at the canonical scope~DOC_TEXT~$SCOPE_REF~yes" \
    "${doc#"$REPO_ROOT/"} makes no repository-wide additions claim~DOC_TEXT~$SCOPE_CLAIM~no"
done

echo "=== controls: a commented decoy, a prose decoy and an inert command cannot satisfy the pins ==="
SCOPE_MUTANT="$TMP_ROOT/scope-comment-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$SCOPE_MUTANT"
sed -i.bak '/schemas\/dev-round.md.*Protected additions/ s/^/<!-- /; /<!-- .*Protected additions/ s/$/ -->/' "$SCOPE_MUTANT"
SCOPE_MUTANT_TEXT="$(<"$SCOPE_MUTANT")"
COMMAND_MUTANT="$TMP_ROOT/dev-fix-command-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$COMMAND_MUTANT"
sed -i.bak '/dev-round-write --worktree/ s/^[[:space:]]*/# /' "$COMMAND_MUTANT"
printf '\n--adds "tools/decoy" outside the command block\n' >> "$COMMAND_MUTANT"
MUTANT_ROUND_BLOCK="$(fenced_block_with "$COMMAND_MUTANT" "dev-round-write --worktree")"
DELEGATION_MUTANT="$TMP_ROOT/dev-fix-delegation-mutant.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$DELEGATION_MUTANT"
sed -i.bak '/^   \[If the round may add files: "Adds:/ s/^/   <!-- /; /^   <!-- .*Adds:/ s/$/ -->/' "$DELEGATION_MUTANT"
printf '\nAdds: [REPO_RELATIVE_PATHS] prose decoy\n' >> "$DELEGATION_MUTANT"
MUTANT_DELEGATION="$(delegation_block "$DELEGATION_MUTANT" "Adds: [REPO_RELATIVE_PATHS]")"
pins \
  "a scope reference inside an HTML comment does not count~SCOPE_MUTANT_TEXT~$SCOPE_REF~no" \
  "a commented live command plus a prose decoy does not count~MUTANT_ROUND_BLOCK~$LIVE_CMD~no" \
  "an inert delegation line plus a prose decoy does not count~MUTANT_DELEGATION~$LIVE_DELEGATION~no"

echo "=== the live command executes and binds its Adds path list ==="
# The command is lifted from the fenced block, its placeholders filled, and
# run against a real worktree; an inert command satisfies the text pin and
# writes nothing, which is what the executable control catches.
WT="$TMP_ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
git -C "$WT" config commit.gpgsign false
git -C "$WT" commit -q --allow-empty -m base
init_growth_state "$STATE" "$WT" issue-826 seed 1000000 >/dev/null
ADDS_PATHS="tools/future-helper.sh skills/x/scripts/future-check"
run_workflow_round_command() { # WORKFLOW ROUND
  local block line
  block="$(fenced_block_with "$1" "dev-round-write --worktree")"
  line="$(awk '/dev-round-write --worktree/ { print; exit }' <<<"$block")"
  [[ -n "$line" ]] || return 1
  line="${line//.agents\/skills\/orch\/scripts\/dev-round-write/$WRITE_BIN}"
  line="${line//\[WORKTREE_PATH\]/$WT}"
  line="${line//\[ISSUE_ID\]/issue-826}"
  line="${line//\[DEV_ROUND_ID\]/$2}"
  line="${line/\[--adds/--adds}"
  line="${line/\[REPO_RELATIVE_PATHS\]/$ADDS_PATHS}"
  line="${line/\"]/\"}"
  "$STATE" --state-dir "$WT/tmp" set issue-826 dev_round_id "$2" >/dev/null
  env ORCH_STATE_DIR="$WT/tmp" bash -c "$line"
}
rid=40
for workflow in dev-fix review-pr-comments; do
  printf '%s' '[{"n":1,"text":"workflow item","reach":"tools/guard on a staged render"}]' > "$WT/tmp/dev-round-items-$rid-$rid.json"
  run_workflow_round_command "$REPO_ROOT/skills/orch/workflows/$workflow.md" "$rid-$rid" >/dev/null
  assert_eq "$(jq -c '.adds' "$WT/tmp/dev-round-issue-826-$rid-$rid.json")" '["tools/future-helper.sh","skills/x/scripts/future-check"]' \
    "$workflow: the live command executes and binds its Adds path list"
  rid=$((rid + 1))
done
INERT="$TMP_ROOT/inert-workflow.md"
cp "$REPO_ROOT/skills/orch/workflows/dev-fix.md" "$INERT"
sed -i.bak '/dev-round-write --worktree/ s|^[[:space:]]*\.agents|true # .agents|' "$INERT"
printf '%s' '[{"n":1,"text":"inert workflow","reach":"tools/guard on a staged render"}]' > "$WT/tmp/dev-round-items-42-42.json"
run_workflow_round_command "$INERT" 42-42 >/dev/null
assert_eq "$([[ -e "$WT/tmp/dev-round-issue-826-42-42.json" ]] && echo yes || echo no)" "no" "control: a satisfied-but-inert command writes no record"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
