#!/usr/bin/env bash
# Surface: hooks/worktree-prompt-claim.sh.
# Inputs: hooks/worktree-session-claim.sh, skills/worktree/scripts/**,
# hooks/tests/lib/assert.sh, hooks/tests/lib/first-line.sh.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$TEST_DIR/../worktree-prompt-claim.sh}"
JUDGE="$TEST_DIR/../worktree-session-claim.sh"
SCRIPTS="$TEST_DIR/../../skills/worktree/scripts"
TMP_ROOT="$(mktemp -d)" || { echo 'worktree-prompt-claim: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'worktree-prompt-claim: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'worktree-prompt-claim: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0
. "$TEST_DIR/lib/assert.sh"
. "$TEST_DIR/lib/first-line.sh"
MAIN="$TMP_ROOT/main"
TREE="$TMP_ROOT/tree"
WORLD_HOME="$TMP_ROOT/home"
INSTALL="$WORLD_HOME/.claude/hooks"
ERR_FILE="$TMP_ROOT/err"
OUT_FILE="$TMP_ROOT/out"
mkdir -p "$MAIN" "$INSTALL" "$WORLD_HOME/.agents/skills/worktree"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name t
git -C "$MAIN" config gc.auto 0
git -C "$MAIN" config maintenance.auto false
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b tree "$TREE" main
RECORD="$(git -C "$TREE" rev-parse --absolute-git-dir)/kendex-issue"
printf 'tree\n' >"$RECORD"
cp -R "$SCRIPTS" "$WORLD_HOME/.agents/skills/worktree/scripts"
GUARD="$WORLD_HOME/.agents/skills/worktree/scripts/worktree-session-guard"
cp "$HOOK" "$INSTALL/worktree-prompt-claim.sh"
cp "$JUDGE" "$INSTALL/worktree-session-claim.sh"

rows() {
  local label mode owner cwd rc want_rc want_key want_owner
  # Claude produces UserPromptSubmit. The prompt's contents cannot change
  # the claim decision, so the fixture sends its documented event only.
  while IFS='|' read -r label mode owner cwd want_rc want_key want_owner; do
    "$GUARD" release "$TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
    [ "$owner" = - ] || "$GUARD" claim "$TREE" --owner "$owner" >/dev/null
    rc=0
    (cd "$TMP_ROOT/$cwd" && env -i PATH="$PATH" HOME="$WORLD_HOME" USER=alice KENDEX_WORKTREE_CLAIM="$mode" \
      "$BASH" "$INSTALL/worktree-prompt-claim.sh" <<<'{"hook_event_name":"UserPromptSubmit"}' >"$OUT_FILE" 2>"$ERR_FILE") || rc=$?
    assert_eq "$rc" "$want_rc" "$label: prompt decision"
    assert_eq "$(first_line)" "${want_key//TREE/$TREE}" "$label: keyed reason"
    assert_eq "$(wc -c <"$OUT_FILE" | tr -d ' ')" 0 "$label: no advisory output"
    assert_eq "$(env -i PATH="$PATH" "$BASH" "$GUARD" status "$TREE" --repo "$MAIN" | jq -r 'if .locked then .owner else "none" end')" "$want_owner" "$label: lease owner"
  done <<'EOF'
foreign required lease|required|bob|tree|2|worktree-session-claim: held=TREE|bob
foreign optional lease|advisory|bob|tree|0|-|bob
unclaimed required tree|required|-|tree|0|-|alice
own required lease|required|alice|tree|0|-|alice
main checkout|required|-|main|0|-|none
EOF
}
rows

# A removed companion cannot evaluate the required claim. The dependency
# installer prevents this layout; manual deletion can still produce it.
missing_judge() {
  local rc=0
  (cd "$TREE" && env -i PATH="$PATH" HOME="$WORLD_HOME" USER=alice KENDEX_WORKTREE_CLAIM=required \
    "$BASH" "$INSTALL/worktree-prompt-claim.sh" </dev/null >"$OUT_FILE" 2>"$ERR_FILE") || rc=$?
  assert_eq "$rc" 2 'missing decision owner: prompt blocked'
  assert_eq "$(first_line)" "worktree-prompt-claim: judge=$INSTALL/worktree-session-claim.sh" 'missing decision owner: keyed reason'
}
mv "$INSTALL/worktree-session-claim.sh" "$TMP_ROOT/saved-judge.sh"
missing_judge
mv "$TMP_ROOT/saved-judge.sh" "$INSTALL/worktree-session-claim.sh"

# A copy that loses the blocking exit makes the foreign-lease assertion red.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  assert_eq "$(grep -cxF '  [ "$PROMPT" != true ] || exit 2' "$JUDGE" || :)" 1 'blocking control: unique anchor'
  sed 's/  \[ "$PROMPT" != true \] || exit 2/  [ "$PROMPT" != true ] || exit 0/' "$JUDGE" >"$INSTALL/worktree-session-claim.sh"
  ! cmp -s "$JUDGE" "$INSTALL/worktree-session-claim.sh" || exit 1
  log=$(PASS=0 FAIL=0 rows) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$log" | tr '\n' ';')" \
    'foreign required lease: prompt decision;' 'blocking control: claim failure must block'
  cp "$JUDGE" "$INSTALL/worktree-session-claim.sh"
  assert_eq "$(grep -cxF 'exec "$BASH" "$JUDGE" prompt' "$HOOK" || :)" 1 'forwarding control: unique anchor'
  sed 's/exec "$BASH" "$JUDGE" prompt/exec "$BASH" "$JUDGE"/' "$HOOK" >"$INSTALL/worktree-prompt-claim.sh"
  ! cmp -s "$HOOK" "$INSTALL/worktree-prompt-claim.sh" || exit 1
  log=$(PASS=0 FAIL=0 rows) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$log" | tr '\n' ';')" \
    'foreign required lease: prompt decision;foreign required lease: no advisory output;' 'forwarding control: event reaches decision owner'
  cp "$HOOK" "$INSTALL/worktree-prompt-claim.sh"
  assert_eq "$(grep -cxF '  exit 2' "$HOOK" || :)" 1 'missing owner control: unique anchor'
  sed 's/^  exit 2$/  exit 0/' "$HOOK" >"$INSTALL/worktree-prompt-claim.sh"
  ! cmp -s "$HOOK" "$INSTALL/worktree-prompt-claim.sh" || exit 1
  mv "$INSTALL/worktree-session-claim.sh" "$TMP_ROOT/saved-judge.sh"
  log=$(PASS=0 FAIL=0 missing_judge) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$log" | tr '\n' ';')" \
    'missing decision owner: prompt blocked;' 'missing owner control: cannot pass an unevaluated claim'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
