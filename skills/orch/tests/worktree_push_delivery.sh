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
DELIVERY_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/orch-env ORCH_DELIVERY / { print; exit }' "$SUBMIT")"
PUSH_COMMAND="$(awk '/^   \.agents\/skills\/orch\/scripts\/worktree-push / { sub(/^   /, ""); print; exit }' "$SUBMIT")"
PREPARE_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push --prepare-base / { print; exit }' "$SUBMIT")"
PUBLISH_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push --publish-base / { print; exit }' "$SUBMIT")"
REVIEW_COMMAND="$(awk '/^if ! BASE_REVIEW_STATE=/ { copy=1 } copy && /^```/ { exit } copy { print }' "$SUBMIT")"
ROOT_COMMAND="$(awk '/^if ! MAIN_REPO_ROOT=/ { copy=1 } copy && /^```/ { exit } copy { print }' "$SUBMIT")"
GITHUB_COMMAND="$(awk '/^gh issue close / { print; exit }' "$SUBMIT")"
PR_COMMAND="$(awk '/^   \.agents\/skills\/github\/scripts\/github.sh .* pr-create / { sub(/^   /, ""); print; exit }' "$SUBMIT")"
COMPLETE_COMMAND="$(awk '/^   \[MAIN_REPO_ROOT\]\/\.agents\/skills\/linear\/scripts\/linear.sh issues complete / { sub(/^   /, ""); print; exit }' "$MERGE")"
NOTICE_COMMAND="$(awk '/^\.agents\/skills\/mailbox\/scripts\/lane-mail notice / { print; exit }' "$SUBMIT")"
MICRO_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/workflow-state set .* tier micro$/ { print; exit }' "$REPO_ROOT/skills/orch/workflows/micro.md")"
[[ -n "$DELIVERY_COMMAND" && -n "$PUSH_COMMAND" && -n "$PREPARE_COMMAND" && -n "$PUBLISH_COMMAND" && -n "$REVIEW_COMMAND" && -n "$ROOT_COMMAND" && -n "$GITHUB_COMMAND" && -n "$PR_COMMAND" && -n "$COMPLETE_COMMAND" && -n "$NOTICE_COMMAND" && -n "$MICRO_COMMAND" ]] || exit 1
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Fixture Git repositories use local-path remotes, so no GitHub metadata exists.
if [[ "${1:-} ${2:-}" == 'pr list' ]]; then
  exit 0
fi
if [[ "${1:-} ${2:-}" == 'issue close' ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_ROOT/github-close"
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
DEV_VALIDATE_CMD = "if test -f AGENTS.md; then cmp AGENTS.md tmp/reloaded-rule || exit; fi; git rev-parse HEAD HEAD^{tree} > tmp/validated"
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
  mkdir -p "$wt/.agents/skills/github/scripts" "$main/.agents/skills/linear/scripts"
  cat > "$wt/.agents/skills/github/scripts/github.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$3" == pr-create ]] || exit 1
printf '%s\n' "$*" > "$FIXTURE_ROOT/pr-call"
SH
  cat > "$main/.agents/skills/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'issues complete' ]] || exit 1
printf '%s\n' "$*" > "$FIXTURE_ROOT/linear-call"
SH
  chmod +x "$wt/.agents/skills/github/scripts/github.sh" "$main/.agents/skills/linear/scripts/linear.sh"
  printf 'item\n' > "$wt/item"
  git -C "$wt" add item
  git -C "$wt" commit -qm 'feat(KEN-1): deliver item'
  item_head="$(git -C "$wt" rev-parse HEAD)"
  (cd "$wt" && "$STATE" init KEN-1 --worktree "$wt" --branch ken-1 >/dev/null)
  (cd "$wt" && "$STATE" append KEN-1 json_paths "$wt/tmp/review.json" >/dev/null)
  lifecycle=self
  review_verdict=pass
  tracker=linear
}

workflow_command() { # COMMAND
  local command="$1" main_root_ref='${MAIN_REPO_ROOT}'
  command="${command//\[WORKTREE_PATH\]/$wt}"
  command="${command//\[MAIN_REPO_ROOT\]/$main_root_ref}"
  command="${command//\[ISSUE_ID\]/KEN-1}"
  command="${command//\[ISSUE\]/KEN-1}"
  command="${command//\[PREFIX\]/feat}"
  command="${command//\[ISSUE_TITLE\]/Fixture}"
  command="${command//\[MERGED_AT\]/${pushed_at:-unused}}"
  command="${command//\[MET_BOXES\]/1}"
  command="${command//\[EVIDENCE_FILE\]/$wt/tmp/evidence}"
  command="${command//\[LIFECYCLE\]/$lifecycle}"
  command="${command//\[REVIEW_VERDICT\]/$review_verdict}"
  command="${command//\[PREPARED_BASE\]/${prepared_base:-unused}}"
  command="${command//\[PREPARED_HEAD\]/${prepared_head:-unused}}"
  command="${command//\[ISSUE_NUMBER\]/${github_number:-1}}"
  command="${command//\[OWNER\/REPO\]/fixture/project}"
  command="${command//.agents\/skills\/mailbox\/scripts\/lane-mail/$MAIL}"
  command="${command//.agents\/skills\/orch\/scripts\/workflow-state/$STATE}"
  command="${command//.agents\/skills\/orch\/scripts\/git-context/$REPO_ROOT\/skills\/orch\/scripts\/git-context}"
  (cd "$wt" && FIXTURE_ROOT="$root" BODY_FILE="$wt/tmp/body" "$BASH" -c "$command")
}

prepare_step() { # PUSH_SCRIPT
  rc=0
  workflow_command "$REVIEW_COMMAND" 2>"$root/publish.err" || rc=$?
  [[ "$rc" == 0 ]] || return 0
  bound_head="$(git -C "$wt" rev-parse --verify HEAD)"
  push_command="${PREPARE_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$1}"
  output="$(ORCH_WORKTREE_BIN="$WORKTREE" workflow_command "$push_command" 2>>"$root/publish.err")" || rc=$?
  [[ "$rc" == 0 ]] || return 0
  receipt="$(sed -n 's/^prepared-base: //p' <<<"$output")"
  prepared_base="${receipt#* before=}"
  prepared_base="${prepared_base%% *}"
  prepared_head="${receipt##* commit=}"
}

transport_step() { # PUSH_SCRIPT
  push_command="${PUBLISH_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$1}"
  output="$(ORCH_WORKTREE_BIN="$WORKTREE" workflow_command "$push_command" 2>>"$root/publish.err")" || rc=$?
  [[ "$rc" == 0 ]] || return 0
  receipt="$(sed -n 's/^delivery: mode=push-base //p' <<<"$output")"
  if [[ -n "$receipt" ]]; then
    # Run the owning workflows' commands against service fixtures.
    landed="${receipt#* commit=}"
    landed="${landed%% *}"
    pushed_at="${receipt##* at=}"
    if [[ "$tracker" == linear ]]; then
      # No caller root is bound. The production init and completion share a shell.
      workflow_command "$ROOT_COMMAND"$'\n'"$COMPLETE_COMMAND"
    else
      workflow_command "$GITHUB_COMMAND"
      github_number=2 workflow_command "$GITHUB_COMMAND"
    fi
    printf 'Pushed %s to release.\n' "$landed" > "$wt/tmp/delivery-KEN-1.md"
    workflow_command "$NOTICE_COMMAND" >/dev/null
  fi
}

publish_step() { # PUSH_SCRIPT
  local delivery_command delivery
  delivery_command="${DELIVERY_COMMAND//.agents\/skills\/orch\/scripts\/orch-env/${1%/*}\/orch-env}"
  delivery="$(workflow_command "$delivery_command")" || return 1
  if [[ "$delivery" == push-base ]]; then
    prepare_step "$1"
    [[ "$rc" == 0 ]] || return 0
    transport_step "$1"
  else
    rc=0
    push_command="${PUSH_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$1}"
    output="$(ORCH_WORKTREE_BIN="$WORKTREE" workflow_command "$push_command" 2>"$root/publish.err")" || rc=$?
    [[ "$rc" == 0 ]] || return 0
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
    assert_eq "$([[ -e "$wt/.agents/skills/linear/scripts/linear.sh" ]] && echo present || echo absent)" absent 'standalone completion uses the resolved common checkout'
  else
    assert_eq "$remote" "$before" "delivery=$mode leaves base unchanged"
    assert_eq "$(git --git-dir="$root/origin.git" rev-parse ken-1)" "$item_head" "delivery=$mode publishes the item branch"
    assert_eq "$([[ -s "$root/pr-call" ]] && echo called || echo absent)" called "delivery=$mode keeps PR publication"
  fi
done

# The gate is the workflow's executable acceptance rule, not its prose.
for review_case in self-standard-empty self-small-empty managed-standard-failed managed-small-pass; do
  new_fixture "review-$review_case" push-base
  lifecycle="${review_case%%-*}"
  review_tier="${review_case#*-}"
  review_tier="${review_tier%%-*}"
  (cd "$wt" && "$STATE" set KEN-1 tier "$review_tier" >/dev/null)
  if [[ "$review_case" != managed-standard-failed ]]; then
    (cd "$wt" && "$STATE" update KEN-1 '.json_paths = []' >/dev/null)
  fi
  [[ "$review_case" != managed-standard-failed ]] || review_verdict=action_required
  publish_step "$LIVE"
  if [[ "$review_case" == managed-small-pass ]]; then
    assert_eq "$rc" 0 'managed review pass satisfies the existing gate without report paths' "$root/publish.err"
  else
    assert_eq "$rc" 1 "$review_case stops publication"
    assert_eq "$(git -C "$wt" rev-parse HEAD)" "$item_head" "$review_case stops before preparation"
    assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$before" "$review_case leaves the base unchanged"
  fi
done

new_fixture github-completion push-base
tracker=github
assert_eq "$(git -C "$wt" show -s --format=%b "$item_head")" '' 'normal item producer has no closing trailer'
printf 'child\n' > "$wt/child"
git -C "$wt" add child
git -C "$wt" commit -qm 'fix(KEN-1): finish bundled child' -m 'Closes #2'
publish_step "$LIVE"
assert_eq "$rc" 0 'GitHub item with a subject-only root commit publishes' "$root/publish.err"
assert_eq "$(cat "$root/github-close")" $'issue close 1 --repo fixture/project --reason completed\nissue close 2 --repo fixture/project --reason completed' 'GitHub completion closes the resolved root and qualified child'
assert_eq "$([[ -e "$root/linear-call" ]] && echo called || echo absent)" absent 'GitHub completion does not call the Linear owner'

new_fixture micro push-base micro
workflow_command "$MICRO_COMMAND"
(cd "$wt" && "$STATE" update KEN-1 '.json_paths = []' >/dev/null)
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
printf 'Read this imported rule before validation.\n' > "$main/AGENTS.md"
git -C "$main" add AGENTS.md
git -C "$main" commit -qm remote
git -C "$main" push -q origin release
advanced="$(git -C "$main" rev-parse HEAD)"
common_dir="$(git -C "$main" rev-parse --absolute-git-dir)"
cat > "$common_dir/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'push\n' >> "$root/push-count"
SH
chmod +x "$common_dir/hooks/pre-push"
prepare_step "$LIVE"
assert_eq "$rc" 0 'preparation returns control after importing base rules' "$root/publish.err"
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$advanced" 'preparation leaves the remote base unchanged'
assert_eq "$([[ -e "$wt/tmp/validated" ]] && echo ran || echo absent)" absent 'preparation returns before local validation'
assert_eq "$([[ -e "$root/push-count" ]] && echo pushed || echo absent)" absent 'preparation returns before transport'
assert_eq "$(git -C "$wt" diff --no-renames --name-only "$bound_head" HEAD -- AGENTS.md)" AGENTS.md 'bound pre-rebase head identifies the changed loaded rule'
# The lane reads the imported rule during the production command boundary.
cat "$wt/AGENTS.md" > "$wt/tmp/reloaded-rule"
transport_step "$LIVE"
assert_eq "$rc" 0 'an advanced base is rebased before validation' "$root/publish.err"
assert_eq "$(git -C "$wt" rev-parse HEAD^)" "$advanced" 'prepared item has the advanced base as parent'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$(git -C "$wt" rev-parse HEAD)" 'rebased item reaches remote base'
assert_eq "$(cat "$root/push-count")" push 'the advanced-base fixture performs one publication push'

new_fixture changed-prepared-head push-base
prepare_step "$LIVE"
git -C "$wt" commit -q --allow-empty -m 'fix(KEN-1): changed after preparation'
transport_step "$LIVE"
assert_eq "$rc" 1 'a head changed during the rules pause refuses publication'
assert_eq "$([[ -e "$wt/tmp/validated" ]] && echo ran || echo absent)" absent 'changed prepared head refuses before validation'
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$before" 'changed prepared head cannot update the base'

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

# A disabled acceptance predicate must expose the unreviewed base publication.
cp "$SUBMIT" "$TMP_ROOT/submit-review-control.md"
mutate_file "$TMP_ROOT/submit-review-control.md" '.tier == "micro" or (' '.tier == "micro" or true or ('
REVIEW_COMMAND="$(awk '/^if ! BASE_REVIEW_STATE=/ { copy=1 } copy && /^```/ { exit } copy { print }' "$TMP_ROOT/submit-review-control.md")"
new_fixture missing-review-control push-base
(cd "$wt" && "$STATE" update KEN-1 '.json_paths = []' >/dev/null)
publish_step "$LIVE"
assert_eq "$rc" 0 'disabled-review control reaches base transport' "$root/publish.err"
assert_eq "$(git --git-dir="$root/origin.git" rev-parse release)" "$(git -C "$wt" rev-parse HEAD)" 'disabled-review control exposes publication without review'

printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
