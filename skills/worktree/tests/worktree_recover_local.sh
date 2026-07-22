#!/usr/bin/env bash
# Regression coverage for guarded local-only branch recovery (vstack#780).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_path_absent() {
  local path="$1" name="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected path: %s\n' "$name" "$path"
  fi
}

assert_file() {
  local path="$1" name="$2"
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing file: %s\n' "$name" "$path"
  fi
}

assert_dir() {
  local path="$1" name="$2"
  if [[ -d "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing directory: %s\n' "$name" "$path"
  fi
}

assert_symlink_target() {
  local path="$1" want="$2" name="$3" got=""
  if [[ -L "$path" ]]; then
    got="$(readlink "$path")"
  fi
  assert_eq "$got" "$want" "$name"
}

run_recover() {
  local issue="$1" prefix="$2"
  shift 2
  set +e
  (cd "$ROOT/main" && "$@" "$WORKTREE_SCRIPT" create "$issue" --recover-local >"$ROOT/$prefix.out" 2>"$ROOT/$prefix.err")
  RECOVER_CODE=$?
  set -e
  RECOVER_ERR="$(cat "$ROOT/$prefix.err")"
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}:${2:-}" == "pr:list" ]]; then
  if [[ -f "${GH_STATE:?}/fail" ]]; then
    printf 'simulated PR discovery failure\n' >&2
    exit 42
  fi
  if [[ -f "$GH_STATE/open-pr" ]]; then
    head_name=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--head" ]]; then
        head_name="$argument"
        break
      fi
      previous="$argument"
    done
    if [[ "$head_name" == "$(cat "$GH_STATE/open-pr")" ]]; then
      printf '42\thttps://example.test/pull/42\n'
    fi
  fi
fi
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

ROOT="$TMP_ROOT/recovery"
mkdir -p "$ROOT/main" "$ROOT/gh-state"
export GH_STATE="$ROOT/gh-state"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
printf '.shared\nrecovery-trees\n' >"$ROOT/main/.gitignore"
printf 'copied\n' >"$ROOT/main/local.cfg"
git -C "$ROOT/main" add base.txt .gitignore local.cfg
git -C "$ROOT/main" commit -q -m base
git init -q --bare "$ROOT/origin.git"
git -C "$ROOT/main" remote add origin "$ROOT/origin.git"
git -C "$ROOT/main" push -q -u origin main
mkdir -p "$ROOT/main/.shared"
printf 'shared\n' >"$ROOT/main/.shared/value.txt"
cat >"$ROOT/main/.env" <<'CONFIG'
WORKTREE_BASE_DIR="../recovery-trees"
WORKTREE_SYMLINKS=".shared"
WORKTREE_RELATIVE_SYMLINKS="links/base=../base.txt"
WORKTREE_COPIES="local.cfg"
WORKTREE_MKDIRS="tmp"
CONFIG

echo "=== recover exact local-only branch and restore configured setup ==="

created_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-RECOVER)"
printf 'preserved commit\n' >"$created_path/preserved.txt"
git -C "$created_path" add preserved.txt
git -C "$created_path" commit -q -m 'preserve me'
surviving_head="$(git -C "$created_path" rev-parse HEAD)"
git -C "$ROOT/main" worktree remove --force "$created_path"
assert_path_absent "$created_path" "external removal leaves no worktree path"
assert_eq "$(git -C "$ROOT/main" rev-parse refs/heads/issue-recover)" "$surviving_head" "external removal preserves the local branch tip"

set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-RECOVER >"$ROOT/bare.out" 2>"$ROOT/bare.err")
bare_code=$?
set -e
assert_eq "$bare_code" "75" "bare create keeps treating the surviving branch as owned work"
assert_contains "$(cat "$ROOT/bare.err")" "create ISSUE-RECOVER --recover-local" "claim refusal routes lost local work to explicit recovery"
assert_eq "$(git -C "$ROOT/main" rev-parse refs/heads/issue-recover)" "$surviving_head" "bare claim refusal does not modify the surviving tip"
assert_path_absent "$created_path" "bare claim refusal does not recreate the worktree implicitly"

recovered_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-RECOVER --recover-local)"
assert_eq "$recovered_path" "$ROOT/recovery-trees/issue-recover" "recovery recreates at the configured external path"
assert_eq "$(git -C "$recovered_path" branch --show-current)" "issue-recover" "recovery checks out the exact normalized issue branch"
assert_eq "$(git -C "$recovered_path" rev-parse HEAD)" "$surviving_head" "recovery preserves the exact committed tip"
assert_file "$recovered_path/preserved.txt" "recovery preserves committed content"
assert_symlink_target "$recovered_path/.shared" "$ROOT/main/.shared" "recovery restores configured main-checkout symlink"
assert_symlink_target "$recovered_path/links/base" "../base.txt" "recovery restores configured relative symlink"
assert_file "$recovered_path/local.cfg" "recovery restores configured copies"
assert_dir "$recovered_path/tmp" "recovery restores configured mkdirs"

git -C "$ROOT/main" branch issue-recovery-race main
race_head="$(git -C "$ROOT/main" rev-parse issue-recovery-race)"
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-recovery-race --recover-local >"$ROOT/race-a.out" 2>"$ROOT/race-a.err") &
race_pid_a=$!
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-RECOVERY-RACE --recover-local >"$ROOT/race-b.out" 2>"$ROOT/race-b.err") &
race_pid_b=$!
wait "$race_pid_a"
race_code_a=$?
wait "$race_pid_b"
race_code_b=$?
set -e
if [[ "$race_code_a:$race_code_b" == "0:75" || "$race_code_a:$race_code_b" == "75:0" ]]; then
  PASS=$((PASS + 1))
  printf '  ok    concurrent recovery has one success and one active-work exit\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  concurrent recovery exit codes\n        expected: 0:75 or 75:0\n        got:      %s:%s\n' "$race_code_a" "$race_code_b"
fi
assert_eq "$(git -C "$ROOT/recovery-trees/issue-recovery-race" rev-parse HEAD)" "$race_head" "concurrent recovery creates one checkout at the preserved tip"

echo "=== recovery refusal cases fail closed without branch mutation ==="

run_recover issue-missing missing env
assert_eq "$RECOVER_CODE" "1" "missing exact local branch exits nonzero"
assert_contains "$RECOVER_ERR" "requires the exact local branch 'issue-missing'" "missing branch refusal names the required identity"
assert_path_absent "$ROOT/recovery-trees/issue-missing" "missing branch creates no path"

active_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active)"
active_head="$(git -C "$active_path" rev-parse HEAD)"
run_recover issue-active active env
assert_eq "$RECOVER_CODE" "75" "active registered worktree exits 75"
assert_contains "$RECOVER_ERR" "Active work already exists" "active worktree keeps normal ownership refusal"
assert_eq "$(git -C "$active_path" rev-parse HEAD)" "$active_head" "active refusal does not modify its branch"

git -C "$ROOT/main" branch issue-remote main
remote_head="$(git -C "$ROOT/main" rev-parse issue-remote)"
git -C "$ROOT/main" push -q origin issue-remote
run_recover issue-remote remote env
assert_eq "$RECOVER_CODE" "75" "published branch exits 75"
assert_contains "$RECOVER_ERR" "a remote branch already exists" "published refusal reports remote ownership"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-remote)" "$remote_head" "remote refusal preserves the local tip"
assert_path_absent "$ROOT/recovery-trees/issue-remote" "remote refusal creates no path"

git init -q --bare "$ROOT/secondary.git"
git -C "$ROOT/main" remote add secondary "$ROOT/secondary.git"
git -C "$ROOT/main" branch issue-secondary main
secondary_head="$(git -C "$ROOT/main" rev-parse issue-secondary)"
git -C "$ROOT/main" push -q secondary issue-secondary
run_recover issue-secondary secondary env
assert_eq "$RECOVER_CODE" "75" "branch published only on a secondary remote exits 75"
assert_contains "$RECOVER_ERR" "secondary/issue-secondary" "secondary ownership refusal names the remote branch"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-secondary)" "$secondary_head" "secondary refusal preserves the local tip"
assert_path_absent "$ROOT/recovery-trees/issue-secondary" "secondary ownership creates no path"
git -C "$ROOT/main" remote remove secondary

git -C "$ROOT/main" branch issue-secondary-unreachable main
unreachable_head="$(git -C "$ROOT/main" rev-parse issue-secondary-unreachable)"
git -C "$ROOT/main" remote add unreachable-secondary "$ROOT/missing-secondary.git"
run_recover issue-secondary-unreachable secondary-unreachable env
assert_eq "$RECOVER_CODE" "1" "unreachable secondary remote blocks local-only recovery"
assert_contains "$RECOVER_ERR" "local-only branch recovery requires every configured remote" "strict recovery discovery explains the secondary-remote requirement"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-secondary-unreachable)" "$unreachable_head" "unreachable-secondary refusal preserves the local tip"
assert_path_absent "$ROOT/recovery-trees/issue-secondary-unreachable" "unreachable secondary creates no path"
git -C "$ROOT/main" remote remove unreachable-secondary

refspec_tree="$(git -C "$ROOT/main" rev-parse 'main^{tree}')"
refspec_head="$(printf 'refspec survivor\n' | git -C "$ROOT/main" commit-tree "$refspec_tree" -p main)"
git -C "$ROOT/main" update-ref refs/heads/issue-refspec "$refspec_head"
git -C "$ROOT/main" config --unset-all remote.origin.fetch
git -C "$ROOT/main" config --add remote.origin.fetch '+refs/heads/issue-refspec:refs/heads/issue-refspec'
refspec_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-refspec --recover-local)"
assert_eq "$(git -C "$ROOT/main" rev-parse refs/heads/issue-refspec)" "$refspec_head" "explicit recovery fetch ignores a local-head destructive fetch refspec"
assert_eq "$(git -C "$refspec_path" rev-parse HEAD)" "$refspec_head" "refspec-safe recovery checks out the pre-fetch snapshot"

git -C "$ROOT/main" config --unset-all remote.origin.fetch
git -C "$ROOT/main" config --add remote.origin.fetch '+refs/heads/issue-refspec-fail:refs/heads/issue-refspec-fail'
git -C "$ROOT/main" branch issue-refspec-fail main
refspec_fail_head="$(git -C "$ROOT/main" rev-parse issue-refspec-fail)"
git --git-dir="$ROOT/origin.git" update-ref -d refs/heads/main
run_recover issue-refspec-fail refspec-fail env
assert_eq "$RECOVER_CODE" "1" "missing remote default branch makes the constrained recovery fetch fail closed"
assert_contains "$RECOVER_ERR" "Could not safely refresh origin/main" "constrained fetch failure is explicit"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-refspec-fail)" "$refspec_fail_head" "failed fetch cannot prune or rewrite the snapshotted local branch"
assert_path_absent "$ROOT/recovery-trees/issue-refspec-fail" "failed constrained fetch creates no path"
git -C "$ROOT/main" push -q origin refs/heads/main:refs/heads/main
git -C "$ROOT/main" config --unset-all remote.origin.fetch
git -C "$ROOT/main" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

rewind_tree="$(git -C "$ROOT/main" rev-parse 'main^{tree}')"
stale_tracking_head="$(printf 'stale tracking advance\n' | git -C "$ROOT/main" commit-tree "$rewind_tree" -p main)"
git -C "$ROOT/main" update-ref refs/remotes/origin/main "$stale_tracking_head"
git -C "$ROOT/main" branch issue-default-rewind main
rewind_recovery_head="$(git -C "$ROOT/main" rev-parse issue-default-rewind)"
rewind_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-default-rewind --recover-local)"
assert_eq "$(git -C "$ROOT/main" rev-parse refs/remotes/origin/main)" "$(git -C "$ROOT/main" rev-parse refs/heads/main)" "constrained forced refspec accepts an authoritative default-branch rewind"
assert_eq "$(git -C "$rewind_path" rev-parse HEAD)" "$rewind_recovery_head" "default-branch rewind still preserves the snapshotted recovery tip"

git -C "$ROOT/main" branch issue-upstream main
git -C "$ROOT/main" branch --set-upstream-to=origin/main issue-upstream >/dev/null
run_recover issue-upstream upstream env
assert_eq "$RECOVER_CODE" "75" "configured upstream history exits 75"
assert_contains "$RECOVER_ERR" "has configured upstream history" "upstream refusal explains the ambiguity"
assert_path_absent "$ROOT/recovery-trees/issue-upstream" "upstream refusal creates no path"

git -C "$ROOT/main" branch issue-pr main
printf 'issue-pr\n' >"$ROOT/gh-state/open-pr"
run_recover issue-pr pr env
assert_eq "$RECOVER_CODE" "75" "open PR exits 75"
assert_contains "$RECOVER_ERR" "an open pull request already exists" "PR refusal reports remote workflow ownership"
assert_path_absent "$ROOT/recovery-trees/issue-pr" "PR refusal creates no path"
rm -f "$ROOT/gh-state/open-pr"

git -C "$ROOT/main" branch issue-occupied main
mkdir -p "$ROOT/recovery-trees/issue-occupied"
printf 'do not delete\n' >"$ROOT/recovery-trees/issue-occupied/marker"
run_recover issue-occupied occupied env
assert_eq "$RECOVER_CODE" "75" "occupied incomplete target exits 75"
assert_contains "$RECOVER_ERR" "not a registered worktree" "occupied target is reported as incomplete"
assert_file "$ROOT/recovery-trees/issue-occupied/marker" "occupied target remains untouched"

git -C "$ROOT/main" branch issue-foreign main
mkdir -p "$ROOT/recovery-trees/issue-foreign"
git -C "$ROOT/recovery-trees/issue-foreign" init -q
printf 'foreign\n' >"$ROOT/recovery-trees/issue-foreign/marker"
run_recover issue-foreign foreign env
assert_eq "$RECOVER_CODE" "75" "foreign repository target exits 75"
assert_contains "$RECOVER_ERR" "not a registered worktree" "foreign target is refused by repository ownership guard"
assert_file "$ROOT/recovery-trees/issue-foreign/marker" "foreign repository remains untouched"

stale_path="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-stale)"
stale_head="$(git -C "$stale_path" rev-parse HEAD)"
rm -rf "$stale_path"
run_recover issue-stale stale env
assert_eq "$RECOVER_CODE" "75" "stale registration exits 75"
assert_contains "$RECOVER_ERR" "incomplete or stale worktree registration" "stale registration is not silently pruned"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-stale)" "$stale_head" "stale refusal preserves the branch"
assert_path_absent "$stale_path" "stale refusal does not recreate an ambiguous registration"

git -C "$ROOT/main" branch issue-ambiguous main
git -C "$ROOT/main" branch robot/issue-ambiguous main
run_recover issue-ambiguous ambiguous env BOT_NAME=robot BOT_EMAIL=robot@example.test
assert_eq "$RECOVER_CODE" "75" "alternate bot-owned local branch exits 75"
assert_contains "$RECOVER_ERR" "another local candidate branch exists" "alternate candidate refusal explains ambiguity"
assert_path_absent "$ROOT/recovery-trees/issue-ambiguous" "ambiguous candidates create no path"

empty_tree="$(git -C "$ROOT/main" mktree </dev/null)"
unrelated_commit="$(printf 'unrelated\n' | git -C "$ROOT/main" commit-tree "$empty_tree")"
git -C "$ROOT/main" update-ref refs/heads/issue-unrelated "$unrelated_commit"
run_recover issue-unrelated unrelated env
assert_eq "$RECOVER_CODE" "75" "unrelated local history exits 75"
assert_contains "$RECOVER_ERR" "does not share history" "unrelated-history refusal verifies repository ancestry"
assert_eq "$(git -C "$ROOT/main" rev-parse issue-unrelated)" "$unrelated_commit" "unrelated refusal preserves the local ref"
assert_path_absent "$ROOT/recovery-trees/issue-unrelated" "unrelated history creates no path"

run_recover main default env
assert_eq "$RECOVER_CODE" "75" "default branch identity exits 75"
assert_contains "$RECOVER_ERR" "resolves to the default branch" "default branch cannot masquerade as an issue branch"

git -C "$ROOT/main" branch issue-options main
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-options --recover-local --reuse >"$ROOT/options.out" 2>"$ROOT/options.err")
options_code=$?
set -e
assert_eq "$options_code" "1" "recovery rejects reuse combination"
assert_contains "$(cat "$ROOT/options.err")" "cannot be combined" "incompatible recovery flags are explicit"
assert_path_absent "$ROOT/recovery-trees/issue-options" "invalid option combination creates no path"

touch "$ROOT/gh-state/fail"
git -C "$ROOT/main" branch issue-discovery-fail main
run_recover issue-discovery-fail discovery-fail env
assert_eq "$RECOVER_CODE" "1" "PR discovery failure exits nonzero"
assert_contains "$RECOVER_ERR" "refusing to assume it is unowned" "PR discovery failure is fail closed"
assert_path_absent "$ROOT/recovery-trees/issue-discovery-fail" "discovery failure creates no path"

echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
