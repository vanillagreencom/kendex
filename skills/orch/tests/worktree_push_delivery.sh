#!/usr/bin/env bash
# Inputs: worktree-push, orch-env, dev-validate-run, worktree push, the submit
# publication commands, review-pr's checkpoint command, micro's tier record,
# merge-pr's completion command and the mailbox writer.
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
REVIEW="$REPO_ROOT/skills/orch/workflows/review-pr.md"
CHECKPOINT_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push --checkpoint / { print; exit }' "$REVIEW")"
DELIVERY_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/orch-env ORCH_DELIVERY / { print; exit }' "$SUBMIT")"
PUSH_COMMAND="$(awk '/^   \.agents\/skills\/orch\/scripts\/worktree-push / { sub(/^   /, ""); print; exit }' "$SUBMIT")"
PREPARE_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push --prepare-base / { print; exit }' "$SUBMIT")"
PUBLISH_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/worktree-push --publish-base / { print; exit }' "$SUBMIT")"
REVIEW_COMMAND="$(awk '/^if ! BASE_REVIEW_STATE=/ { copy=1 } copy && /^```/ { exit } copy { print }' "$SUBMIT")"
ROOT_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/git-context common-root / { print; exit }' "$SUBMIT")"
GITHUB_COMMAND="$(awk '/^gh issue close / { print; exit }' "$SUBMIT")"
PR_COMMAND="$(awk '/^   \.agents\/skills\/github\/scripts\/github.sh .* pr-create / { sub(/^   /, ""); print; exit }' "$SUBMIT")"
COMPLETE_COMMAND="$(awk '/^   \[MAIN_REPO_ROOT\]\/\.agents\/skills\/linear\/scripts\/linear.sh issues complete / { sub(/^   /, ""); print; exit }' "$MERGE")"
NOTICE_COMMAND="$(awk '/^\.agents\/skills\/mailbox\/scripts\/lane-mail notice / { print; exit }' "$SUBMIT")"
MICRO_COMMAND="$(awk '/^\.agents\/skills\/orch\/scripts\/workflow-state set .* tier micro$/ { print; exit }' "$REPO_ROOT/skills/orch/workflows/micro.md")"
[[ -n "$CHECKPOINT_COMMAND" && -n "$DELIVERY_COMMAND" && -n "$PUSH_COMMAND" && -n "$PREPARE_COMMAND" && -n "$PUBLISH_COMMAND" && -n "$REVIEW_COMMAND" && -n "$ROOT_COMMAND" && -n "$GITHUB_COMMAND" && -n "$PR_COMMAND" && -n "$COMPLETE_COMMAND" && -n "$NOTICE_COMMAND" && -n "$MICRO_COMMAND" ]] || exit 1
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

new_fixture() { # NAME DELIVERY [micro|range]
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
  if [[ "${3:-}" == range ]]; then
    cat >> "$main/kendex.settings.toml" <<'TOML'
DEV_VALIDATE_RANGE_CMD = "printf r >> tmp/range-count; echo $DEV_VALIDATE_BASE > tmp/range-base; git rev-parse HEAD HEAD^{tree} > tmp/validated; test ! -e tmp/fail"
TOML
    sed '/^DEV_VALIDATE_CMD =/s/git rev-parse HEAD HEAD\^{tree} > tmp\/validated/printf f >> tmp\/full-count; git rev-parse HEAD HEAD^{tree} > tmp\/validated/' "$main/kendex.settings.toml" > "$main/settings.new"
    mv -- "$main/settings.new" "$main/kendex.settings.toml"
  fi
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
  local command="$1"
  command="${command//\[WORKTREE_PATH\]/$wt}"
  command="${command//\[MAIN_REPO_ROOT\]/${completion_root:-}}"
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
  (cd "$wt" && env -u MAIN_REPO_ROOT FIXTURE_ROOT="$root" BODY_FILE="$wt/tmp/body" "$BASH" -c "$command")
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
      completion_root="$(workflow_command "$ROOT_COMMAND")" || return $?
      workflow_command "$COMPLETE_COMMAND"
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

checkpoint_case() { # NAME SCRIPT MODE STATE PHASE
  local script="$2" mode="$3" state="$4" phase="$5" map head base_now command rc=0 output
  new_fixture "$1" "$mode"
  if [[ "$state" == restack || "$state" == push-rebase ]]; then
    (cd "$wt" && ORCH_WORKTREE_BIN="$WORKTREE" "$LIVE" --checkpoint --worktree "$wt" --issue KEN-1 --set-upstream) >"$root/initial.out" 2>"$root/publish.err"
  fi
  (cd "$wt" && "$STATE" update KEN-1 --arg old "$item_head" \
    '.json_paths=[] | .fixed_items=[{commit:$old}] | .pr_comment_review.fixes=[{commit:$old}]' >/dev/null)
  if [[ "$state" == restack || "$state" == push-rebase ]]; then
    printf 'Updated rule\n' > "$main/AGENTS.md"
    git -C "$main" add AGENTS.md
    git -C "$main" commit -qm 'docs: update rule'
    git -C "$main" push -q origin release
    if [[ "$state" == restack ]]; then
      (cd "$main" && "$WORKTREE" create KEN-1 --restack) >"$root/restack.out" 2>>"$root/publish.err"
    fi
  fi
  map="$(git -C "$wt" rev-parse --git-path kendex-rebase-map)"
  if [[ "$state" == unmapped ]]; then
    printf 'rebase-unmapped: %s\n' "$item_head" > "$map"
  fi
  base_now="$(git --git-dir="$root/origin.git" rev-parse release)"
  if [[ "$phase" == checkpoint ]]; then
    command="${CHECKPOINT_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$script}"
  else
    command="${PUSH_COMMAND//.agents\/skills\/orch\/scripts\/worktree-push/$script}"
  fi
  output="$(ORCH_WORKTREE_BIN="$WORKTREE" workflow_command "$command" 2>>"$root/publish.err")" || rc=$?
  head="$(git -C "$wt" rev-parse HEAD)"
  jq -cn --argjson rc "$rc" --arg head "$head" --arg old "$item_head" \
    --arg remote "$(git --git-dir="$root/origin.git" rev-parse --verify refs/heads/ken-1 2>/dev/null || true)" \
    --arg base "$base_now" --arg after "$(git --git-dir="$root/origin.git" rev-parse release)" \
    --argjson record "$(cd "$wt" && "$STATE" get KEN-1)" \
    --argjson map "$([[ -e "$map" ]] && echo true || echo false)" \
    --argjson validated "$([[ -e "$wt/tmp/validated" ]] && echo true || echo false)" \
    --arg receipt "$(sed -n 's/^delivery: //p' <<<"$output")" \
    '{rc:$rc,published:($remote==$head),base_unchanged:($base==$after),
      reconciled:($record.fixed_items[0].commit==$head and $record.pr_comment_review.fixes[0].commit==$head),
      rewritten:($old!=$head),map:$map,validated:$validated,delivery:($receipt!="")}'
}

# The review handoff publishes a branch before review under both delivery
# modes. Restack uses the shipped rewrite authorization, not a synthetic map.
CHECKPOINT_CASES='unset-fresh|unset|fresh|checkpoint|0|true|false|false
pr-fresh|pr|fresh|checkpoint|0|true|false|false
base-fresh|push-base|fresh|checkpoint|0|true|false|false
pr-restack|pr|restack|checkpoint|0|true|true|false
base-restack|push-base|restack|checkpoint|0|true|true|false
base-push-rebase|push-base|push-rebase|checkpoint|0|true|true|false
base-unmapped|push-base|unmapped|checkpoint|1|false|false|true
base-unphased|push-base|fresh|branch|1|false|false|false'
while IFS='|' read -r name mode state phase want_rc published rewritten map; do
  observed="$(checkpoint_case "checkpoint-$name" "$LIVE" "$mode" "$state" "$phase")"
  expected="$(jq -cn --argjson rc "$want_rc" --argjson published "$published" \
    --argjson rewritten "$rewritten" --argjson map "$map" \
    '{rc:$rc,published:$published,base_unchanged:true,reconciled:true,rewritten:$rewritten,map:$map,validated:false,delivery:false}')"
  assert_eq "$observed" "$expected" "$name keeps the checkpoint at guarded branch publication"
done <<<"$CHECKPOINT_CASES"

# Disable the guarded transport on a disposable source copy. The same real
# published restack must then fail its published-head contract.
CHECKPOINT_CONTROL="$(mutant_scripts checkpoint-plain-push worktree-push)"
orch_fixture_shared_libs "${CHECKPOINT_CONTROL%/scripts}"
mutate_file "$CHECKPOINT_CONTROL/worktree-push" \
  '"$WORKTREE_BIN" push "$worktree_abs" ${push_args[@]+"${push_args[@]}"}' \
  '"$WORKTREE_BIN" push "$worktree_abs" --no-rebase ${push_args[@]+"${push_args[@]}"}'
observed="$(checkpoint_case checkpoint-control "$CHECKPOINT_CONTROL/worktree-push" push-base restack checkpoint)"
assert_eq "$observed" \
  '{"rc":1,"published":false,"base_unchanged":true,"reconciled":true,"rewritten":true,"map":false,"validated":false,"delivery":false}' \
  'control: plain transport cannot publish the restacked checkpoint'

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

# The native runner produces every candidate. Preparation changes commit
# metadata, so reuse must cover the tree and prepared base across that fold.
# Missing evidence is removed from real runs, never replaced with a pass.
publication_validation_case() { # NAME PUSH_SCRIPT VARIANT
  local name="$1" script="$2" variant="$3" first='' run='' native_output native_rc direct_cmd reused=false count='' full=false
  if [[ "$variant" == full-fallback ]]; then
    new_fixture "$name" push-base
  else
    new_fixture "$name" push-base range
  fi
  git -C "$wt" commit -q --allow-empty -m 'fix(KEN-1): finish review'
  item_head="$(git -C "$wt" rev-parse HEAD)"
  case "$variant" in
    no-native|full-fallback) ;;
    unrecorded)
      direct_cmd="$(cd "$wt" && "$REPO_ROOT/skills/orch/scripts/orch-env" DEV_VALIDATE_RANGE_CMD "")" || return 1
      (cd "$wt" && DEV_VALIDATE_BASE="$before" "$BASH" -c "$direct_cmd")
      ;;
    *)
      [[ "$variant" != failed ]] || : > "$wt/tmp/fail"
      native_rc=0
      native_output="$("$REPO_ROOT/skills/orch/scripts/dev-validate-run" --worktree "$wt" --validate-mode range --base "$before" --attached --poll 1)" || native_rc=$?
      first="$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' <<<"$native_output")"
      [[ -n "$first" ]] || { printf '%s\n' "$native_output" >&2; return 1; }
      if [[ "$variant" == failed ]]; then
        [[ "$native_rc" != 0 ]] || return 1
      else
        [[ "$native_rc" == 0 ]] || return 1
      fi
      case "$variant" in
        missing-cmd|missing-paths|missing-start) rm -- "$first/${variant#missing-}" ;;
        changed-tree)
          printf 'fix\n' > "$wt/fix"
          git -C "$wt" add fix
          git -C "$wt" commit -qm 'fix(KEN-1): change validated tree'
          ;;
        changed-base)
          git -C "$main" commit -q --allow-empty -m 'docs: advance base'
          git -C "$main" push -q origin release
          ;;
      esac
      ;;
  esac
  prepare_step "$script"
  [[ "$rc" == 0 ]] || return 1
  if [[ "$variant" == reuse ]]; then
    assert_eq "$(git -C "$wt" rev-parse 'HEAD^{tree}')" "$(sed -n 's/^tree=//p' "$first/start")" 'preparation retains the natively tested tree'
    assert_eq "$([[ "$prepared_head" != "$item_head" ]] && echo changed || echo same)" changed 'preparation rewrites the tested head'
  fi
  transport_step "$script"
  run="$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' <<<"$output")"
  [[ -n "$run" ]] || { printf '%s\n' "$output" >&2; return 1; }
  if [[ -n "$first" && -f "$run/start" ]] && grep -Fxq "pass-run=$first" "$run/start"; then reused=true; fi
  [[ ! -f "$wt/tmp/range-count" ]] || count="$(cat "$wt/tmp/range-count")"
  [[ ! -f "$wt/tmp/full-count" ]] || full=true
  publication_observed="$rc|$count|$reused|$full|$([[ "$(git --git-dir="$root/origin.git" rev-parse release)" == "$prepared_head" ]] && echo true || echo false)"
  if [[ "$variant" != full-fallback ]]; then
    assert_eq "$(cat "$wt/tmp/range-base")" "$prepared_base" "$variant uses the prepared base"
  fi
  if [[ "$reused" == false ]]; then
    assert_contains "$(cat "$run/runner")" 'runner=attached' "$variant keeps native validation attached"
  fi
  if [[ "$variant" == classification-fallback ]]; then
    assert_contains "$output" 'class-fallback=classifier-absent' 'unavailable classification cannot reuse native proof'
  fi
}

# This installation lacks harness-ci, a supported conservative native route.
FALLBACK_SCRIPTS="$(mutant_scripts publication-unavailable-classifier)"
orch_fixture_shared_libs "${FALLBACK_SCRIPTS%/scripts}"
# variant|exit|range command launches|native reuse|full command ran|published
PUBLICATION_VALIDATION_CASES='reuse|0|r|true|false|true
no-native|0|r|false|false|true
unrecorded|0|rr|false|false|true
changed-tree|0|rr|false|false|true
changed-base|0|rr|false|false|true
missing-cmd|0|rr|false|false|true
missing-paths|0|rr|false|false|true
missing-start|0|rr|false|false|true
classification-fallback|0|rr|false|false|true
failed|1|rr|false|false|false
full-fallback|0||false|false|true'
while IFS='|' read -r variant want; do
  validation_script="$LIVE"
  [[ "$variant" != classification-fallback ]] || validation_script="$FALLBACK_SCRIPTS/worktree-push"
  publication_validation_case "validation-$variant" "$validation_script" "$variant"
  assert_eq "$publication_observed" "$want" "$variant preserves native publication validation" "$root/publish.err"
done <<<"$PUBLICATION_VALIDATION_CASES"

# Restore the unwanted full request only on a disposable copy. The native
# reuse row must detect the extra full command, not merely a successful push.
VALIDATION_CONTROL="$(mutant_scripts publication-full-request worktree-push)"
orch_fixture_shared_libs "${VALIDATION_CONTROL%/scripts}"
mutate_file "$VALIDATION_CONTROL/worktree-push" \
  '--validate-mode range --base "$prepared_before" --attached' '--attached'
publication_validation_case validation-full-control "$VALIDATION_CONTROL/worktree-push" reuse
assert_eq "$publication_observed" '0|r|false|true|true' 'control: default-full publication loses native range reuse'

# Separate tool shells can use only the visible common-root output. The
# silent row reproduces the previous shipped command as a must-fail control.
for completion_case in visible:0 silent:127; do
  completion_mode="${completion_case%%:*}"
  new_fixture "completion-$completion_mode" push-base
  completion_expected_rc="${completion_case##*:}"
  completion_command="$ROOT_COMMAND"
  completion_expected_root="$main"
  completion_expected_call=called
  if [[ "$completion_mode" == silent ]]; then
    printf -v completion_command 'if ! MAIN_REPO_ROOT="$(%s)"; then\n  exit 1\nfi' "$ROOT_COMMAND"
    completion_expected_root=''
    completion_expected_call=absent
  fi
  completion_root="$(workflow_command "$completion_command")"
  completion_rc=0
  workflow_command "$COMPLETE_COMMAND" 2>"$root/completion.err" || completion_rc=$?
  assert_eq "$completion_root" "$completion_expected_root" "$completion_mode root output binds the next command"
  assert_eq "$completion_rc" "$completion_expected_rc" "$completion_mode completion runs in a separate fresh shell" "$root/completion.err"
  assert_eq "$([[ -e "$root/linear-call" ]] && echo called || echo absent)" "$completion_expected_call" "$completion_mode reaches only the resolved completion owner"
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
