#!/usr/bin/env bash
# Behavioral tests for base-freshness — the ../workflows/start-worktree.md § 1 review-cycle
# gate. A reused worktree can sit many commits behind origin, and a review
# cycle with no fetch on that path evaluates a stale base. The helper must
# FETCH origin (a
# stale remote-tracking ref is not evidence), report ahead/behind of HEAD vs
# the resolved base branch, and exit 0 fresh / 4 stale / 1 unverifiable. On a
# merge-queue base with no up-to-date rule, fresh is a clean trial merge
# rather than behind = 0, and the JSON names the reading that decided it.
#
# Bash 3.2 compatible.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BF="$REPO_ROOT/skills/orch/scripts/base-freshness"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# GitHub's branch rules come from a gh stub: STUB_RULES is the rules array
# the base's read answers through its own --jq, none when unset, and `fail`
# makes that read exit 1, so no case reaches the real GitHub.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq_filter="" prev=""
for a in "$@"; do
  [[ "$prev" != --jq ]] || jq_filter="$a"
  prev="$a"
done
case "${1:-}:${2:-}" in
  api:repos/*/rules/branches/*)
    [[ "${STUB_RULES:-}" != fail ]] || { echo 'gh: HTTP 502' >&2; exit 1; }
    jq -r "$jq_filter" <<<"${STUB_RULES:-[]}"
    ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

commit_upstream() {
  local msg="$1"
  printf '%s\n' "$msg" >>"$UPSTREAM/log.txt"
  git -C "$UPSTREAM" add log.txt
  git -C "$UPSTREAM" commit -q -m "$msg"
}

# Sandbox: an upstream repo pushed to a bare origin, and a clone standing in
# for the reused issue worktree.
UPSTREAM="$TMP_ROOT/upstream"
ORIGIN="$TMP_ROOT/origin.git"
WT="$TMP_ROOT/worktree"

mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email test@example.com
git -C "$UPSTREAM" config user.name Test
git -C "$UPSTREAM" config commit.gpgsign false
commit_upstream base
# -b main pins the bare repo's HEAD; without it the clone below checks out
# whatever ambient init.defaultBranch names, which differs across machines.
git init -q --bare -b main "$ORIGIN"
git -C "$UPSTREAM" remote add origin "$ORIGIN"
git -C "$UPSTREAM" push -q -u origin main

git clone -q "$ORIGIN" "$WT"
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
git -C "$WT" config commit.gpgsign false
git -C "$WT" checkout -q -b issue-42

echo "=== base-freshness review-cycle gate ==="

# Fresh: worktree branch is at origin/main.
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "fresh worktree exits 0"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "0" "fresh worktree reports behind = 0"
assert_eq "$(printf '%s' "$out" | jq -r '.fresh')" "true" "fresh worktree reports fresh = true"
assert_eq "$(printf '%s' "$out" | jq -r '.branch')" "issue-42" "JSON carries the current branch"
assert_eq "$(printf '%s' "$out" | jq -r '.base_branch')" "main" "JSON carries the resolved base branch"

# Stale: origin/main advances AFTER the clone. The worktree's remote-tracking
# ref points at the tip before the advance, so a nonzero `behind` here proves
# the helper fetched rather than trusting local refs.
commit_upstream upstream-1
commit_upstream upstream-2
git -C "$UPSTREAM" push -q origin main
git -C "$WT" commit -q --allow-empty -m local-work

set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "4" "stale worktree exits 4"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "2" "stale worktree reports commits behind origin base (fetch happened)"
assert_eq "$(printf '%s' "$out" | jq -r '.ahead')" "1" "stale worktree still reports local commits ahead"
assert_eq "$(printf '%s' "$out" | jq -r '.fresh')" "false" "stale worktree reports fresh = false"

# Rebase clears staleness: after rebasing onto the fetched base (what
# `worktree create <ID> --restack` does), the gate must pass.
git -C "$WT" rebase -q origin/main >/dev/null 2>&1
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "rebased worktree exits 0"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "0" "rebased worktree reports behind = 0"

# A merge-queue base with no up-to-date rule: behind is no longer stale by
# itself. A branch that merges cleanly onto the fetched base is fresh, one
# that conflicts is stale, and a strict rule keeps behind > 0 stale. Each case
# starts from its own branch off the old base and drops the checkout's policy
# record, so the rules the case names are the ones read. The control is a
# copy of the script whose fresh verdict no longer takes a clean merge.
QUEUE_RULES='[{"type":"merge_queue","parameters":{}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false}}]'
STRICT_RULES='[{"type":"merge_queue","parameters":{}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]'
mkdir -p "$TMP_ROOT/pkg/orch/scripts" "$TMP_ROOT/pkg/worktree/scripts/lib"
cp "$BF" "$REPO_ROOT/skills/orch/scripts/resolve-base-branch" "$TMP_ROOT/pkg/orch/scripts/"
cp "$REPO_ROOT/skills/worktree/scripts/lib/base-reading.sh" "$TMP_ROOT/pkg/worktree/scripts/lib/"
MUTANT_BF="$TMP_ROOT/pkg/orch/scripts/base-freshness"
[[ "$(grep -cF '    contained | merges-cleanly) fresh=true ;;' "$MUTANT_BF")" == 1 ]] || {
  echo "FIXTURE: the fresh verdict was not unique in $MUTANT_BF" >&2
  exit 2
}
sed -i.bak 's/^    contained | merges-cleanly) fresh=true ;;$/    contained) fresh=true ;;/' "$MUTANT_BF"
rm -f -- "${MUTANT_BF:?}.bak"
grep -qF '    contained) fresh=true ;;' "$MUTANT_BF" || {
  echo "FIXTURE: the fresh-verdict edit matched nothing in $MUTANT_BF" >&2
  exit 2
}
OLD_BASE="$(git -C "$WT" rev-parse origin/main~2)"
# A git whose trial merge cannot run, for the `trial-fails` script column.
mkdir -p "$TMP_ROOT/gitshim"
REAL_GIT="$(command -v git)"
cat >"$TMP_ROOT/gitshim/git" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  [[ "\$arg" != merge-tree ]] || exit 2
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP_ROOT/gitshim/git"
# label|script|rules|file the branch commits|exit|behind|policy|reading|fresh
while IFS='|' read -r q_label q_script q_rules q_file q_code q_behind q_policy q_reading q_fresh; do
  [[ -n "$q_label" ]] || continue
  git -C "$WT" checkout -q -B "queue-case" "$OLD_BASE"
  printf 'branch-side\n' >"$WT/$q_file"
  git -C "$WT" add "$q_file"
  git -C "$WT" commit -q -m "branch: $q_file"
  rm -f -- "$WT/.git/kendex-base-policy"
  [[ "$q_script" == mutant ]] && q_bf="$MUTANT_BF" || q_bf="$BF"
  q_path="$PATH"
  [[ "$q_script" != trial-fails ]] || q_path="$TMP_ROOT/gitshim:$PATH"
  set +e
  out="$(PATH="$q_path" STUB_RULES="$q_rules" env -u WORKTREE_DEFAULT_BRANCH "$q_bf" "$WT" 2>"$TMP_ROOT/err")"
  code=$?
  set -e
  assert_eq "$code:$(printf '%s' "$out" | jq -r '"\(.behind) \(.policy) \(.reading) \(.fresh)"')" \
    "$q_code:$q_behind $q_policy $q_reading $q_fresh" "$q_label"
done <<ROWS
a behind branch that merges cleanly onto a merge-queue base is fresh|real|$QUEUE_RULES|branch-only.txt|0|2|queue|merges-cleanly|true
must-fail: with the clean merge cut from the fresh verdict, that branch is stale|mutant|$QUEUE_RULES|branch-only.txt|4|2|queue|merges-cleanly|false
a branch that conflicts with a merge-queue base is stale|real|$QUEUE_RULES|log.txt|4|2|queue|conflicts|false
a strict up-to-date rule keeps a behind branch stale|real|$STRICT_RULES|branch-only.txt|4|2|strict|behind|false
a base with no queue keeps a behind branch stale|real|[]|branch-only.txt|4|2|no-queue|behind|false
a rules read that fails keeps a behind branch stale|real|fail|branch-only.txt|4|2|unverified|behind|false
a trial merge that cannot run keeps a behind branch stale|trial-fails|$QUEUE_RULES|branch-only.txt|4|2|queue|trial-failed|false
ROWS
git -C "$WT" checkout -q issue-42
rm -f -- "$WT/.git/kendex-base-policy"

# WORKTREE_DEFAULT_BRANCH overrides the resolved base (resolve-base-branch
# integration): compare against origin/trunk instead of origin/main.
git -C "$UPSTREAM" checkout -q -b trunk
commit_upstream trunk-only
git -C "$UPSTREAM" push -q origin trunk
git -C "$UPSTREAM" checkout -q main

set +e
out="$(WORKTREE_DEFAULT_BRANCH=trunk "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "4" "WORKTREE_DEFAULT_BRANCH base is honored (stale vs trunk)"
assert_eq "$(printf '%s' "$out" | jq -r '.base_branch')" "trunk" "JSON reports the overridden base branch"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "1" "behind counted against the overridden base"

# Unverifiable: fetch failure must exit 1 (never 0) so the workflow stops
# instead of reviewing an unknown base.
git -C "$WT" remote set-url origin "$TMP_ROOT/missing.git"
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
err="$(cat "$TMP_ROOT/err")"
assert_eq "$code" "1" "fetch failure exits 1"
assert_eq "$(sed -n '1p' "$TMP_ROOT/err")" "base-freshness: fetch-failed ref=origin/main" "fetch failure starts with the stable condition"
assert_contains "$err" "$TMP_ROOT/missing.git" "fetch failure keeps the tool detail after the header"

# No origin remote at all is equally unverifiable.
git -C "$WT" remote remove origin
set +e
"$BF" "$WT" >/dev/null 2>"$TMP_ROOT/err"
code=$?
set -e
err="$(cat "$TMP_ROOT/err")"
assert_eq "$code" "1" "missing origin remote exits 1"
assert_contains "$err" "base-freshness: missing-remote path=$WT remote=origin" "missing origin remote is named in the error"

# Workflow wiring: the start-worktree § 1 gate runs the helper before § 2
# delegation.
START_WT="$REPO_ROOT/skills/orch/workflows/start-worktree.md"
wiring="$(cat "$START_WT")"
assert_contains "$wiring" '.agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]' "start-worktree § 1 runs the base-freshness gate"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
