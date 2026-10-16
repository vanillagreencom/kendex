#!/usr/bin/env bash
# Inputs: worktree-push, orch-env, dev-validate-run, worktree push, the submit
# publication commands, micro's tier record, merge-pr's completion command and the mailbox writer.
# Real Git transport and mailbox storage are exercised. GitHub PR creation and
# Linear completion are service fixtures. The driver follows the workflow's
# delivery receipt; it does not implement Git preparation or publication.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'worktree_push_delivery: scratch=mktemp-failed' >&2; exit 1; }
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
cleanup() {
  local status=$?
  if [[ "$status" != 0 && -n "${root:-}" ]]; then
    [[ ! -f "$root/create.err" ]] || cat "$root/create.err" >&2
    [[ ! -f "$root/publish.err" ]] || cat "$root/publish.err" >&2
  fi
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
WORKTREE="$REPO_ROOT/skills/worktree/scripts/worktree"
LIVE="$REPO_ROOT/skills/orch/scripts/worktree-push"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
MAIL="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
SUBMIT="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
MERGE="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
PUSH_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push / { line=$0 } END { print line }' "$SUBMIT")"
PR_COMMAND="$(awk '/^   \.agents\/skills\/github\/scripts\/github.sh .* pr-create / { sub(/^   /, ""); print; exit }' "$SUBMIT")"
COMPLETE_COMMAND="$(awk '/^   \[MAIN_REPO_ROOT\]\/\.agents\/skills\/linear\/scripts\/linear.sh issues complete / { sub(/^   /, ""); print; exit }' "$MERGE")"
NOTICE_COMMAND="$(awk '/^\.agents\/skills\/mailbox\/scripts\/lane-mail notice / { print; exit }' "$SUBMIT")"
MICRO_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/workflow-state set .* tier micro$/ { print; exit }' "$REPO_ROOT/skills/orch/workflows/micro.md")"
[[ -n "$PUSH_COMMAND" && -n "$PR_COMMAND" && -n "$COMPLETE_COMMAND" && -n "$NOTICE_COMMAND" && -n "$MICRO_COMMAND" ]] || exit 1
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Fixture Git repositories use local-path remotes, so no GitHub metadata exists.
if [[ "${1:-} ${2:-}" == 'pr list' ]]; then
  exit 0
fi
exit 1
SH
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
unset ORCH_DELIVERY ORCH_PR_ORDER DEV_VALIDATE_CMD DEV_VALIDATE_RANGE_CMD DEV_VALIDATE_CI_CONTEXT DEV_VALIDATE_SELECTION_CMD WORKTREE_DEFAULT_BRANCH KENDEX_ENV_FILE

new_fixture() { # NAME DELIVERY [micro]
  root="$TMP_ROOT/$1"
  main="$root/main"
  mkdir -p "$main"
  git init -q -b release "$main"
  git -C "$main" config user.name Fixture
  git -C "$main" config user.email fixture@example.com
  git -C "$main" config commit.gpgsign false
  git -C "$main" config gc.auto 0
  git -C "$main" config maintenance.auto false
  printf 'base\n' > "$main/file"
  printf 'tmp/\n.agents/\n.env.local\n' > "$main/.gitignore"
  cat > "$main/kendex.settings.toml" <<'TOML'
[env]
WORKTREE_DEFAULT_BRANCH = "release"
WORKTREE_BASE_DIR = "../trees"
ORCH_PR_ORDER = "review-first"
DEV_VALIDATE_CMD = "git rev-parse HEAD HEAD^{tree} > tmp/validated"
DEV_VALIDATE_TIMEOUT_SECS = "30"
TOML
  [[ "$2" == unset ]] || printf 'ORCH_DELIVERY = "%s"\n' "$2" >> "$main/kendex.settings.toml"
  if [[ "${3:-}" == micro ]]; then
    sed '/^DEV_VALIDATE_CMD =/d' "$main/kendex.settings.toml" > "$main/settings.new"
    mv -- "$main/settings.new" "$main/kendex.settings.toml"
  fi
  git -C "$main" add .
  git -C "$main" commit -qm base
  git init -q --bare "$root/origin.git"
  git --git-dir="$root/origin.git" config gc.auto 0
  git --git-dir="$root/origin.git" config maintenance.auto false
  git -C "$main" remote add origin "$root/origin.git"
  git -C "$main" push -qu origin release
  before="$(git -C "$main" rev-parse HEAD)"
  wt="$(cd "$main" && "$WORKTREE" create KEN-1 2>"$root/create.err")"
  mkdir -p "$wt/tmp"
  mkdir -p "$wt/.agents/skills/github/scripts" "$wt/.agents/skills/linear/scripts"
  cat > "$wt/.agents/skills/github/scripts/github.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$3" == pr-create ]] || exit 1
printf '%s\n' "$*" > "$FIXTURE_ROOT/pr-call"
SH
  cat > "$wt/.agents/skills/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'issues complete' ]] || exit 1
printf '%s\n' "$*" > "$FIXTURE_ROOT/linear-call"
SH
  chmod +x "$wt/.agents/skills/github/scripts/github.sh" "$wt/.agents/skills/linear/scripts/linear.sh"
  printf 'item\n' > "$wt/item"
  git -C "$wt" add item
  git -C "$wt" commit -qm 'feat(KEN-1): deliver item' -m 'Closes #1'
  item_head="$(git -C "$wt" rev-parse HEAD)"
  (cd "$wt" && "$STATE" init KEN-1 --worktree "$wt" --branch ken-1 >/dev/null)
}

workflow_command() { # COMMAND
  local command="$1"
  command="${command//\[WORKTREE_PATH\]/$wt}"
  command="${command//\[MAIN_REPO_ROOT\]/$wt}"
  command="${command//\[ISSUE_ID\]/KEN-1}"
  command="${command//\[ISSUE\]/KEN-1}"
  command="${command//\[PREFIX\]/feat}"
  command="${command//\[ISSUE_TITLE\]/Fixture}"
  command="${command//\[MERGED_AT\]/${pushed_at:-unused}}"
  command="${command//\[MET_BOXES\]/1}"
  command="${command//\[EVIDENCE_FILE\]/$wt/tmp/evidence}"
  command="${command//.agents\/skills\/mailbox\/scripts\/lane-mail/$MAIL}"
  command="${command//.agents\/skills\/orch\/scripts\/workflow-state/$STATE}"
  (cd "$wt" && FIXTURE_ROOT="$root" BODY_FILE="$wt/tmp/body" "$BASH" -c "$command")
}

publish_step() { # PUSH_SCRIPT
  rc=0
  push_command="${PUSH_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$1}"
  output="$(ORCH_WORKTREE_BIN="$WORKTREE" workflow_command "$push_command" 2>"$root/publish.err")" || rc=$?
  [[ "$rc" == 0 ]] || return 0
  receipt="$(sed -n 's/^delivery: mode=push-base //p' <<<"$output")"
  if [[ -n "$receipt" ]]; then
    # Run the owning workflows' commands against service fixtures.
    landed="${receipt#* commit=}"
    landed="${landed%% *}"
    pushed_at="${receipt##* at=}"
    workflow_command "$COMPLETE_COMMAND"
    printf 'Pushed %s to release.\n' "$landed" > "$wt/tmp/delivery-KEN-1.md"
    workflow_command "$NOTICE_COMMAND" >/dev/null
  else
    # PR creation is the workflow's unchanged service boundary.
    workflow_command "$PR_COMMAND"
  fi
}

for mode in push-base unset pr; do
  new_fixture "mode-$mode" "$mode"
  if [[ "$mode" == push-base ]]; then
    # Internal review produces another item commit before publication.
    printf 'fix\n' > "$wt/fix"
    git -C "$wt" add fix
    git -C "$wt" commit -qm 'fix(KEN-1): correct item'
  fi
  publish_step "$LIVE"
  assert_eq "$rc" 0 "delivery=$mode publishes" "$root/publish.err"
  remote="$(git --git-dir="$root/origin.git" rev-parse release)"
  if [[ "$mode" == push-base ]]; then
    head="$(git -C "$wt" rev-parse HEAD)"
    assert_eq "$remote" "$head" 'remote base holds the prepared commit'
    assert_eq "$(git -C "$wt" rev-list --count "$before..HEAD")" 1 'all item commits become one cycle commit'
    assert_eq "$(cat "$wt/tmp/validated")" "$(git -C "$wt" rev-parse HEAD 'HEAD^{tree}')" 'local validation covers the exact published commit and tree'
    assert_eq "$([[ -e "$root/pr-call" ]] && echo called || echo absent)" absent 'direct delivery creates no PR'
    assert_eq "$(jq -r '.text' "$wt/tmp/lane-mail/KEN-1/to-overseer.jsonl")" "Pushed $head to release." 'completion notice names the pushed commit'
    assert_eq "$(cat "$root/linear-call")" "issues complete KEN-1 --post-merge-at $pushed_at --done-when-met 1 --evidence-file $wt/tmp/evidence" 'completion uses the captured push time'
    assert_eq "$(git -C "$wt" show -s --format=%B HEAD | sed -n '/^Closes /p')" 'Closes #1' 'fold preserves the GitHub issue closure line'
  else
    assert_eq "$remote" "$before" "delivery=$mode leaves base unchanged"
    assert_eq "$(git --git-dir="$root/origin.git" rev-parse ken-1)" "$item_head" "delivery=$mode publishes the item branch"
    assert_eq "$([[ -s "$root/pr-call" ]] && echo called || echo absent)" called "delivery=$mode keeps PR publication"
  fi
done

new_fixture micro push-base micro
workflow_command "$MICRO_COMMAND"
cat > "$main/.git/hooks/pre-commit" <<SH
#!/usr/bin/env bash
printf 'hook\n' >> "$root/hook-count"
SH
chmod +x "$main/.git/hooks/pre-commit"
publish_step "$LIVE"
assert_eq "$rc" 0 'micro can publish with no DEV_VALIDATE_CMD' "$root/publish.err"
assert_eq "$(cat "$root/hook-count")" hook 'micro preparation runs normal commit hooks'
assert_eq "$([[ -e "$wt/tmp/validated" ]] && echo ran || echo absent)" absent 'micro starts no validation command'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$(git -C "$wt" rev-parse HEAD)" 'micro publishes its guarded commit'

new_fixture remote-advanced push-base
printf 'remote\n' > "$main/remote"
git -C "$main" add remote
git -C "$main" commit -qm remote
git -C "$main" push -q origin release
advanced="$(git -C "$main" rev-parse HEAD)"
common_dir="$(git -C "$main" rev-parse --absolute-git-dir)"
cat > "$common_dir/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'push\n' >> "$root/push-count"
SH
chmod +x "$common_dir/hooks/pre-push"
publish_step "$LIVE"
assert_eq "$rc" 0 'an advanced base is rebased before validation' "$root/publish.err"
assert_eq "$(git -C "$wt" rev-parse HEAD^)" "$advanced" 'prepared item has the advanced base as parent'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$(git -C "$wt" rev-parse HEAD)" 'rebased item reaches remote base'
assert_eq "$(cat "$root/push-count")" push 'the advanced-base fixture performs one publication push'

new_fixture conflict push-base
printf 'local\n' > "$wt/file"
git -C "$wt" commit -qam 'fix(KEN-1): local conflict'
printf 'remote\n' > "$main/file"
git -C "$main" commit -qam remote
git -C "$main" push -q origin release
advanced="$(git -C "$main" rev-parse HEAD)"
publish_step "$LIVE"
assert_eq "$rc" 1 'a conflicting history refuses publication'
assert_eq "$(sed -n 's/^worktree-\([^:]*\):.*/\1/p' "$root/publish.err" | tail -1)" push-rebase-failed 'conflict has a keyed restack refusal'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$advanced" 'conflict cannot overwrite the base'

# The existing setting reader is the production decision. Mutating only that
# read must route the same fixture to PR creation instead of direct delivery.
MUTANT_SCRIPTS="$(mutant_scripts unread-delivery orch-env)" || exit 1
orch_fixture_shared_libs "${MUTANT_SCRIPTS%/scripts}"
mutate_file "$MUTANT_SCRIPTS/orch-env" 'local value="${!VAR_NAME-}"' $'local value="${!VAR_NAME-}"\n  [[ "$VAR_NAME" != ORCH_DELIVERY ]] || value=""'
new_fixture unread-setting-control push-base
publish_step "$MUTANT_SCRIPTS/worktree-push"
assert_eq "$rc" 0 'unread-setting control reaches publication'
assert_eq "$([[ -s "$root/pr-call" ]] && echo called || echo absent)" called 'must-fail control opens a PR when delivery is unread'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$before" 'must-fail control misses base publication'

printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
