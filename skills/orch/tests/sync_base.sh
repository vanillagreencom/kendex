#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/orch/scripts/sync-base"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || { printf '        expected: %s\n        got:      %s\n' "$2" "$1"; fail "$3"; }; }

UPSTREAM="$TMP_ROOT/upstream.git"
SEED="$TMP_ROOT/seed"
CLONE="$TMP_ROOT/clone"
git init -q --bare "$UPSTREAM"
git init -q "$SEED"
git -C "$SEED" config user.email test@example.com
git -C "$SEED" config user.name test
printf 'one\n' > "$SEED/file"
printf 'tracked\n' > "$SEED/local"
printf 'ignored-*\n' > "$SEED/.gitignore"
git -C "$SEED" add .gitignore file local
git -C "$SEED" commit -q -m one
git -C "$SEED" branch -M main
git -C "$SEED" push -q "$UPSTREAM" main
git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
git clone -q "$UPSTREAM" "$CLONE"
git -C "$CLONE" config user.email test@example.com
git -C "$CLONE" config user.name test
git -C "$CLONE" remote set-head origin main

printf 'two\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m two
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "base checkout sync prints only the branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "base checkout fast-forwards"

git -C "$CLONE" switch -q -c feature
printf 'three\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m three
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "by-name sync prints the base branch"
assert_eq "$(git -C "$CLONE" branch --show-current)" "feature" "by-name sync keeps the active branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "unowned base ref fast-forwards"

STALE_TREE="$TMP_ROOT/stale-tree"
STALE_GONE="$TMP_ROOT/stale-tree-gone"
git -C "$CLONE" worktree add -q "$STALE_TREE" main
mv "$STALE_TREE" "$STALE_GONE"
printf 'four\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m four
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "stale-owner sync prints the branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "prune removes stale ownership before the update"
git -C "$CLONE" worktree list --porcelain | grep -Fq "$STALE_TREE" && fail "stale worktree registration is pruned" || ok "stale worktree registration is pruned"

BASE_TREE="$TMP_ROOT/base"$'\n'"tree"
git -C "$CLONE" worktree add -q "$BASE_TREE" main
printf 'five\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m five
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "owned-base sync prints the branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$(git -C "$SEED" rev-parse main)" "sync advances the worktree that owns the base"

git -C "$BASE_TREE" commit -q --allow-empty -m local-ahead
local_ahead_sha="$(git -C "$BASE_TREE" rev-parse HEAD)"
origin_sha="$(git -C "$BASE_TREE" rev-parse origin/main)"
AHEAD_MUTANT="$TMP_ROOT/sync-base-ahead-mutant"
assert_eq "$(grep -Fc '[[ "$LOCAL_SHA" == "$ORIGIN_SHA" ]] || {' "$SYNC")" "1" "local-ahead control finds the SHA equality gate"
awk '
  index($0, "SCRIPT_DIR=\"$(cd --") { print "SCRIPT_DIR=\"${SYNC_TEST_SCRIPT_DIR:?}\""; next }
  { sub(/\[\[ "\$LOCAL_SHA" == "\$ORIGIN_SHA" \]\]/, "[[ -n \"$LOCAL_SHA\" ]]"); print }
' "$SYNC" > "$AHEAD_MUTANT"
chmod +x "$AHEAD_MUTANT"
assert_eq "$(SYNC_TEST_SCRIPT_DIR="$REPO_ROOT/skills/orch/scripts" "$AHEAD_MUTANT" "$CLONE" 2>"$TMP_ROOT/local-ahead-mutant.err")" "main" "local-ahead control fails without SHA equality"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/local-ahead.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "owned local-ahead base fails closed" || fail "owned local-ahead base fails closed"
assert_eq "$out" "" "local-ahead refusal prints no branch"
grep -Fq "local $local_ahead_sha, origin $origin_sha" "$TMP_ROOT/local-ahead.err" && ok "local-ahead refusal names both SHAs" || fail "local-ahead refusal names both SHAs"
git -C "$BASE_TREE" reset -q --hard "$origin_sha"

printf 'dirty\n' >> "$BASE_TREE/local"
printf 'six\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m six
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/tracked-dirty.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "nonconflicting tracked dirtiness fails closed" || fail "nonconflicting tracked dirtiness fails closed"
assert_eq "$out" "" "tracked-dirty sync prints no branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "tracked-dirty base does not advance"
grep -Fq 'base checkout is dirty' "$TMP_ROOT/tracked-dirty.err" && ok "tracked-dirty refusal names the checkout" || fail "tracked-dirty refusal names the checkout"
grep -Fq ' local' "$TMP_ROOT/tracked-dirty.err" && ok "tracked-dirty refusal names the path" || fail "tracked-dirty refusal names the path"
git -C "$BASE_TREE" restore local
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "cleaned tracked base can catch up"

printf 'untracked\n' > "$BASE_TREE/untracked"
printf 'ignored\n' > "$BASE_TREE/ignored-unrelated"
printf 'seven\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m seven
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
UNTRACKED_MUTANT="$TMP_ROOT/sync-base-untracked-mutant"
assert_eq "$(grep -Fc -- '--untracked-files=no' "$SYNC")" "1" "untracked control finds the tracked-only dirtiness check"
awk '
  index($0, "SCRIPT_DIR=\"$(cd --") { print "SCRIPT_DIR=\"${SYNC_TEST_SCRIPT_DIR:?}\""; next }
  { sub(/--untracked-files=no/, "--untracked-files=all"); print }
' "$SYNC" > "$UNTRACKED_MUTANT"
chmod +x "$UNTRACKED_MUTANT"
rc=0
SYNC_TEST_SCRIPT_DIR="$REPO_ROOT/skills/orch/scripts" "$UNTRACKED_MUTANT" "$CLONE" >/dev/null 2>"$TMP_ROOT/untracked-mutant.err" || rc=$?
[[ $rc -ne 0 ]] && ok "untracked control fails when unrelated files are classified as dirty" || fail "untracked control fails when unrelated files are classified as dirty"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "untracked mutant does not advance the base"
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/untracked-safe.err")"
assert_eq "$out" "main" "unrelated untracked file allows base sync"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$(git -C "$SEED" rev-parse main)" "unrelated untracked file does not block the fast-forward"
assert_eq "$(cat "$BASE_TREE/untracked")" "untracked" "unrelated untracked file is preserved"
assert_eq "$(cat "$BASE_TREE/ignored-unrelated")" "ignored" "unrelated ignored file is preserved"
rm -f -- "$BASE_TREE/untracked" "$BASE_TREE/ignored-unrelated"

printf 'local clobber\n' > "$BASE_TREE/clobber"
printf 'upstream clobber\n' > "$SEED/clobber"
git -C "$SEED" add clobber
git -C "$SEED" commit -q -m clobber
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/untracked-clobber.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "untracked clobber fails closed" || fail "untracked clobber fails closed"
assert_eq "$out" "" "untracked clobber prints no branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "untracked clobber does not advance the base"
grep -Fq 'untracked working tree files would be overwritten' "$TMP_ROOT/untracked-clobber.err" && ok "untracked clobber refusal names the overwrite" || fail "untracked clobber refusal names the overwrite"
grep -Fq 'clobber' "$TMP_ROOT/untracked-clobber.err" && ok "untracked clobber refusal names the path" || fail "untracked clobber refusal names the path"
assert_eq "$(cat "$BASE_TREE/clobber")" "local clobber" "untracked clobber is preserved"
rm -f -- "$BASE_TREE/clobber"
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "cleaned clobber base can catch up"

printf 'local ignored clobber\n' > "$BASE_TREE/ignored-clobber"
printf 'upstream ignored clobber\n' > "$SEED/ignored-clobber"
git -C "$SEED" add -f ignored-clobber
git -C "$SEED" commit -q -m ignored-clobber
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/ignored-clobber.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "ignored untracked clobber fails closed" || fail "ignored untracked clobber fails closed"
assert_eq "$out" "" "ignored untracked clobber prints no branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "ignored untracked clobber does not advance the base"
grep -Fq 'ignored-clobber' "$TMP_ROOT/ignored-clobber.err" && ok "ignored collision refusal names the path" || fail "ignored collision refusal names the path"
assert_eq "$(cat "$BASE_TREE/ignored-clobber")" "local ignored clobber" "ignored collision preserves local data"

rm -f -- "$BASE_TREE/ignored-clobber"
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "cleaned ignored clobber base can catch up"

EFFECT_MUTANT="$TMP_ROOT/sync-base-effect-mutant"
assert_eq "$(grep -Fc -- 'merge --ff-only --no-overwrite-ignore' "$SYNC")" "1" "effect control finds no-overwrite-ignore"
awk '
  index($0, "SCRIPT_DIR=\"$(cd --") { print "SCRIPT_DIR=\"${SYNC_TEST_SCRIPT_DIR:?}\""; next }
  { sub(/--ff-only --no-overwrite-ignore/, "--ff-only"); print }
' "$SYNC" > "$EFFECT_MUTANT"
chmod +x "$EFFECT_MUTANT"
printf 'upstream effect\n' > "$SEED/ignored-effect"
git -C "$SEED" add -f ignored-effect
git -C "$SEED" commit -q -m ignored-effect
git -C "$SEED" push -q "$UPSTREAM" main
printf 'local effect\n' > "$BASE_TREE/ignored-effect"
out="$(SYNC_TEST_SCRIPT_DIR="$REPO_ROOT/skills/orch/scripts" "$EFFECT_MUTANT" "$CLONE" 2>"$TMP_ROOT/effect-mutant.err")"
assert_eq "$out" "main" "effect control fails when merge may overwrite ignored data"
assert_eq "$(cat "$BASE_TREE/ignored-effect")" "upstream effect" "effect mutant exposes the ignored-file data loss the flag prevents"

CASE_PROBE="$BASE_TREE/case-probe"
mkdir "$CASE_PROBE"
printf 'probe\n' > "$CASE_PROBE/MixedCase"
if [[ -e "$CASE_PROBE/mixedcase" ]]; then
  printf 'upstream case\n' > "$SEED/ignored-case"
  git -C "$SEED" add -f ignored-case
  git -C "$SEED" commit -q -m ignored-case
  git -C "$SEED" push -q "$UPSTREAM" main
  printf 'IGNORED-CASE\n' >> "$(git -C "$BASE_TREE" rev-parse --git-path info/exclude)"
  printf 'local case\n' > "$BASE_TREE/IGNORED-CASE"
  before="$(git -C "$BASE_TREE" rev-parse HEAD)"
  rc=0
  out="$($SYNC "$CLONE" 2>"$TMP_ROOT/case-collision.err")" || rc=$?
  [[ $rc -ne 0 ]] && ok "effectful merge refuses a case-insensitive ignored alias" || fail "effectful merge refuses a case-insensitive ignored alias"
  assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "case-insensitive collision does not advance the base"
  assert_eq "$(cat "$BASE_TREE/IGNORED-CASE")" "local case" "case-insensitive collision preserves local data"
  rm -f -- "$BASE_TREE/IGNORED-CASE"
  "$SYNC" "$CLONE" >/dev/null 2>"$TMP_ROOT/case-clean.err"
else
  ok "case-insensitive collision control is skipped on a case-sensitive filesystem"
fi
rm -rf "$CASE_PROBE"

git -C "$BASE_TREE" commit -q --allow-empty -m diverged
printf 'eight\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m eight
git -C "$SEED" push -q "$UPSTREAM" main
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/diverged.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "divergent base fails closed" || fail "divergent base fails closed"
assert_eq "$out" "" "failed sync prints no branch"
grep -Fq 'Not possible to fast-forward' "$TMP_ROOT/diverged.err" && ok "divergence reports the fast-forward refusal" || fail "divergence reports the fast-forward refusal"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/sync-base [MAIN_REPO_ROOT]' "$MERGE_WORKFLOW" && ok "merge-pr delegates base synchronization to the script" || fail "merge-pr delegates base synchronization to the script"
grep -Fq 'merge --ff-only "origin/[BASE_BRANCH]"' "$MERGE_WORKFLOW" && fail "merge-pr removes the prose base-sync procedure" || ok "merge-pr removes the prose base-sync procedure"
grep -Fq 'scripts/resolve-base-branch [MAIN_REPO_ROOT]' "$MERGE_WORKFLOW" && ok "merge-pr resolves the failed sync base branch" || fail "merge-pr resolves the failed sync base branch"
grep -Fq 'rev-parse "refs/heads/[BASE_BRANCH]"' "$MERGE_WORKFLOW" && ok "merge-pr collects the stale local SHA" || fail "merge-pr collects the stale local SHA"
grep -Fq 'rev-parse "refs/remotes/origin/[BASE_BRANCH]"' "$MERGE_WORKFLOW" && ok "merge-pr collects the stale origin SHA" || fail "merge-pr collects the stale origin SHA"

printf 'sync-base: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
