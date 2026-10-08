#!/usr/bin/env bash
# Runs with the consumer's default-branch checkout as the working directory,
# from the kendex release tree the shared workflow checked out. It rebuilds the rolling branch from the
# checkout and never executes the remote rolling branch. It requests auto-merge
# after GitHub shows the published head. SKILL.md defines the arm outcomes.
# Output records: refresh-state=current pr=none class=none, or
# refresh-state=unchanged|pushed pr=NUMBER class=CLASS, or
# refresh-state=unarmed pr=NUMBER pushed=REVISION head=REVISION, or
# refresh-state=deferred reason=queued|merged|closed|branch-gone. A consumer
# whose render did not run also gets
# refresh-render=skipped package=bot-instructions cause=absent|unconfigured.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load from the trusted runner before refresh replaces its installed files.
source "$SCRIPT_DIR/../skills/review-gate/scripts/lib/arm-published-head.sh"
templates="$SCRIPT_DIR"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
: "${GH_REPO:?GH_REPO names the running repository}"
: "${GH_TOKEN:?GH_TOKEN must be the repository-scoped app installation token}"
: "${REFRESH_APP_SLUG:?REFRESH_APP_SLUG names that app}"
if ! clean="$(git status --porcelain)"; then
  printf 'refresh-error=read value=clean\n' >&2
  exit 1
fi
[ -z "$clean" ] || { printf 'refresh-error=dirty value=%s\n' "$ROOT" >&2; exit 1; }
if ! default="$(gh api "repos/$GH_REPO" --jq .default_branch)"; then
  printf 'refresh-error=read value=default\n' >&2
  exit 1
fi
[ -n "$default" ] && [ "$default" != null ] || { printf 'refresh-error=default-branch value=missing\n' >&2; exit 1; }
base="$(git rev-parse HEAD)"
# Private consumer repositories need the app credential for every git read.
gh auth setup-git
git fetch --no-tags origin "$default"
if ! expected="$(git rev-parse FETCH_HEAD)"; then
  printf 'refresh-error=read value=expected\n' >&2
  exit 1
fi
[ "$base" = "$expected" ] || { printf 'refresh-error=default-moved value=%s\n' "$expected" >&2; exit 1; }
prs="$(gh api --paginate "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:kendex/refresh&per_page=100" --jq '.[].number')"
count=0
pr=""
while IFS= read -r number; do
  [ -n "$number" ] || continue
  count=$((count + 1)); pr="$number"
done <<<"$prs"
[ "$count" -le 1 ] || { printf 'refresh-error=multiple-pulls value=%s\n' "$count" >&2; exit 1; }
remote="$(git ls-remote --heads origin refs/heads/kendex/refresh)"
old="${remote%%[[:space:]]*}"
if [ -n "$old" ]; then
  git fetch --no-tags origin refs/heads/kendex/refresh
fi
# GitHub owns the queue and may merge the rolling pull request and delete its
# branch at any moment. The read at run start skips a run whose pull request
# the queue already holds; only a read after GitHub refuses a write, or the
# refusal itself, can establish the lifecycle at that write. Sets reason to
# merged, closed, queued, armed, branch-gone or active for the pull request
# in pr; a failed or malformed read exits.
refresh_lifecycle() {
  local has_pr=false push_state
  if [ -n "$pr" ]; then has_pr=true; fi
  if ! push_state="$(gh api graphql -f owner="${GH_REPO%%/*}" -f repo="${GH_REPO#*/}" \
    -F number="${pr:-0}" -F hasPR="$has_pr" \
    -f query='query($owner: String!, $repo: String!, $number: Int!, $hasPR: Boolean!) { repository(owner: $owner, name: $repo) { ref(qualifiedName: "refs/heads/kendex/refresh") { target { oid } } pullRequest(number: $number) @include(if: $hasPR) { state isInMergeQueue autoMergeRequest { enabledAt } } } }')"; then
    printf 'refresh-error=push-state value=query\n' >&2
    exit 1
  fi
  if ! reason="$(jq -er -s --argjson has_pr "$has_pr" --arg old "$old" '
    if length != 1 then error("expected one response") else .[0] end |
    if (.errors // [] | length) != 0 then error("GraphQL errors") else .data.repository end |
    if type != "object" or (has("ref") | not) or
      (.ref != null and (.ref.target.oid | type != "string" or length == 0)) or
      ($has_pr and (.pullRequest | type != "object" or
        (has("state") and has("isInMergeQueue") and has("autoMergeRequest") | not) or
        (.state != "OPEN" and .state != "MERGED" and .state != "CLOSED") or
        (.isInMergeQueue | type != "boolean") or
        (.autoMergeRequest != null and (.autoMergeRequest.enabledAt | type != "string" or length == 0))))
    then error("incomplete refresh state") else . end |
    if .pullRequest.state == "MERGED" then "merged"
    elif .pullRequest.state == "CLOSED" then "closed"
    elif .pullRequest.isInMergeQueue == true then "queued"
    elif .pullRequest.autoMergeRequest != null then "armed"
    elif .ref == null and $old != "" then "branch-gone"
    else "active" end
  ' <<<"$push_state")"; then
    printf 'refresh-error=push-state value=output\n' >&2
    exit 1
  fi
}
# GitHub refuses a push to a branch the queue holds. A queued, merged or
# closed pull request ends the run before any refresh, push, body update or
# auto-merge change. An armed one is disarmed first: the arm survives a push,
# and the queue does not re-check approval, so the old arm could merge the
# new head before its review. The arm after publication re-arms that head.
if [ -n "$pr" ]; then
  refresh_lifecycle
  if [ "$reason" = armed ] && ! gh pr merge "$pr" --repo "$GH_REPO" --disable-auto; then
    refresh_lifecycle
    case "$reason" in
      queued | merged | closed) ;;
      *)
        printf 'refresh-error=disarm pr=%s value=%s\n' "$pr" "$reason" >&2
        exit 1 ;;
    esac
  fi
  case "$reason" in
    queued | merged | closed)
      printf 'refresh-state=deferred reason=%s\n' "$reason"
      exit 0 ;;
  esac
fi
git checkout -B kendex/refresh "$base"
export KENDEX_UI=plain
refresh_status=0
# --prune takes what the catalog retired; a plain refresh keeps it. kendex
# 1.11.0 adds the flag, and the release this runs under can predate
# it, so it is passed where the installed kendex lists it; 1.12.0 drops the
# probe.
refresh_help="$(kendex help refresh 2>/dev/null || true)"
case "$refresh_help" in
  *--prune*) refresh_output="$(kendex refresh --scope project --yes --leave --prune 2>&1)" || refresh_status=$? ;;
  *) refresh_output="$(kendex refresh --scope project --yes --leave 2>&1)" || refresh_status=$? ;;
esac
printf '%s\n' "$refresh_output"
if [ "$refresh_status" -ne 0 ]; then
  printf 'refresh-error=refresh value=%s\n' "$refresh_status" >&2
  exit "$refresh_status"
fi
# refresh has no JSON report. Fall back to blocked.rs's plain conflicts
# section and holds.rs's records; verify cannot report discarded edits.
# ledger.rs counts distinct kind/name items, not rows or harnesses.
# setting_notes collects the change-class lines that name a consumer
# setting; a run with no render change runs no classifier and reports none.
# retired_items collects the line refresh prints for each item its catalog
# retired, keyed by the item's name and the catalog, its migration last.
setting_notes=()
retired_items=""
retired_pattern='^[^ :]+: retired by '
held_items=""
held_keys=$'\n'
held_count=0
conflict_count=""
conflict_section=no
ledger_pattern=' · skipped ([1-9][0-9]*) items? on conflict( · |$)'
while IFS= read -r line; do
  case "$line" in
    conflicts:) conflict_section=yes; continue ;;
    '    '*) continue ;;
    '  '*)
      if [ "$conflict_section" = yes ]; then
        case "$line" in
          *': edited on disk and changed upstream — keep your edits as a fork, or apply with edits discarded' | \
          *': edited on disk since install — keep it as a fork, or apply with edits discarded' | \
          *': its files were edited on disk after another tool installed them — keep the edits as a fork, or apply with edits discarded' | \
          *': changed upstream and on disk — kendex cannot tell your edits from the update; keep it as a fork or apply with edits discarded') ;;
          *)
            printf 'refresh-error=conflict-record value=%s\n' "${line#  }" >&2
            exit 1 ;;
        esac
        held_items="$held_items- ${line#  }
"
        item="${line#  }"
        item="${item%: *}"
        item="${item% for *}"
        case "$held_keys" in
          *$'\n'"$item"$'\n'*) ;;
          *) held_keys="$held_keys$item"$'\n'; held_count=$((held_count + 1)) ;;
        esac
      fi ;;
    *) conflict_section=no ;;
  esac
  if [[ "$line" =~ $retired_pattern ]]; then
    retired_items="$retired_items$line"$'\n'
  fi
  case "$line" in
    *' · skipped '*' on conflict'*)
      if [ -n "$conflict_count" ] || ! [[ "$line" =~ $ledger_pattern ]]; then
        printf 'refresh-error=conflict-ledger value=%s\n' "$line" >&2
        exit 1
      fi
      conflict_count="${BASH_REMATCH[1]}" ;;
  esac
done <<<"$refresh_output"
if [ -n "$conflict_count" ] || [ "$held_count" -ne 0 ]; then
  if [ "${conflict_count:-0}" != "$held_count" ]; then
    printf 'refresh-error=conflict-count value=%s held=%s\n' "${conflict_count:-0}" "$held_count" >&2
    exit 1
  fi
  printf 'refresh-error=render-edited value=%s\n' "$held_count" >&2
  printf '%s' "$held_items" >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
# refresh keeps the files of a declaration deleted from kendex.toml by hand;
# apply moves them to the trash as diffs of this pull request. A leftover
# edited on disk is held, not trashed, and the verify below fails on it.
apply_status=0
kendex apply --scope project --yes --leave || apply_status=$?
if [ "$apply_status" -ne 0 ]; then
  printf 'refresh-error=apply value=%s\n' "$apply_status" >&2
  exit 1
fi
# The refresh above skips the bot-instructions render: the arming record that
# licenses it lives in a git directory, and this fresh checkout's has none.
# The consumer's check judges the pull request with the refreshed package, so
# this run asks kendex to render once, which locates the package wherever the
# install put it and writes no record. The invocation is the licence, spent
# in a checkout this run discards, and it runs with no credential. The
# package refuses a manifest with no [bot-instructions] table as
# unconfigured, which leaves that consumer unrendered. The refresh is staged
# first because the render reads the index for the tree's subtrees; the
# later git add -A takes what it writes and removes.
git add -A
render_status=0
render_output=""
render_skip=""
render_output="$(env -i PATH="$PATH" HOME="$HOME" KENDEX_UI=plain kendex bot-instructions-render 2>&1)" || render_status=$?
printf '%s\n' "$render_output"
case "$render_status" in
  0) if grep -qxF 'bot-instructions-render=absent' <<<"$render_output"; then render_skip=absent; fi ;;
  2) if grep -qx 'bot-instructions: unconfigured=.*' <<<"$render_output"; then render_skip=unconfigured; fi ;;
esac
if [ -n "$render_skip" ]; then
  printf 'refresh-render=skipped package=bot-instructions cause=%s\n' "$render_skip"
elif [ "$render_status" -ne 0 ]; then
  printf 'refresh-error=bot-instructions-render value=%s\n' "$render_status" >&2
  exit 1
fi
"$SCRIPT_DIR/adopt-refresh.sh" --templates-dir "$templates"
# The release-installed parser must judge its own settings, including on a
# first install. It reads and prints data without the refresh app credential.
# Only this script in the kendex release tree consumes its output or publishes. Without orch the
# parse still scans the committed [env] table, which needs only this
# package's settings library.
orch=present
if [ ! -e "$ROOT/.agents/skills/orch" ] && [ ! -L "$ROOT/.agents/skills/orch" ]; then
  orch=absent
  printf 'refresh-settings=orch-absent value=%s\n' "$ROOT/.agents/skills/orch"
fi
if ! env -i PATH="$PATH" HOME="$HOME" bash -s -- "$SCRIPT_DIR" "$ROOT" "$orch" >"$TMP/settings.json" <<'SETTINGS_PARSE'
set -euo pipefail
source "$1/../skills/review-gate/scripts/lib/settings.sh"
OL_REFUSED_ENTRIES=()
OL_DEPRECATED_ENTRIES=()
if [ "$3" = present ]; then
  source "$2/.agents/skills/orch/scripts/lib/kendex-env.sh"
  source "$2/.agents/skills/orch/scripts/lib/overseer-launch.sh"
  KENDEX_ENV_FILE="$(rg_setting KENDEX_ENV_FILE "" "")"
  kendex_private_env_file private_file "$2"
  preference="$(rg_setting ORCH_OVERSEER_PREFERENCE "$OL_DEFAULT_PREFERENCE" "$private_file")"
  parse_status=0
  ol_preference_entries "$preference" || parse_status=$?
  [ "$parse_status" -le 1 ] || exit "$parse_status"
fi
# List committed [env] values that pin Fable or Astra, and every committed
# [env] setting as key and value pairs for the retired-settings match; the
# report warns and changes no exit. A comment, another table and a private
# override are not committed [env] values.
deprecated_models=()
committed=()
if [ -f kendex.settings.toml ]; then
  table="$(rg_env_table kendex.settings.toml)"
  assignment='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*"([^"]*)"'
  shopt -s nocasematch
  while IFS= read -r line; do
    [[ $line =~ $assignment ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    committed+=("$key" "$value")
    if [[ $value == *gpt-6-astra* || $value == *fable* ]]; then
      deprecated_models+=("$key = \"$value\"")
    fi
  done <<<"$table"
fi
jq -cn --argjson refused_count "${#OL_REFUSED_ENTRIES[@]}" \
  --argjson deprecated_count "${#OL_DEPRECATED_ENTRIES[@]}" \
  --argjson models_count "${#deprecated_models[@]}" --args \
  '($refused_count + $deprecated_count) as $models_start |
   ($models_start + $models_count) as $committed_start |
   {refused: $ARGS.positional[:$refused_count],
    deprecated: $ARGS.positional[$refused_count:$models_start],
    deprecated_models: $ARGS.positional[$models_start:$committed_start],
    committed: ($ARGS.positional[$committed_start:] |
      [range(0; length; 2) as $i | {(.[$i]): .[$i + 1]}] | add // {})}' \
  -- ${OL_REFUSED_ENTRIES[@]+"${OL_REFUSED_ENTRIES[@]}"} \
  ${OL_DEPRECATED_ENTRIES[@]+"${OL_DEPRECATED_ENTRIES[@]}"} \
  ${deprecated_models[@]+"${deprecated_models[@]}"} \
  ${committed[@]+"${committed[@]}"}
SETTINGS_PARSE
then
  printf 'refresh-error=settings-extraction value=%s\n' "$ROOT/.agents/skills/orch" >&2
  exit 1
fi
# The parser exports the existing report object as one compact JSON line.
# Refused entries can contain arbitrary text; validation checks data shape,
# never re-implements the preference grammar.
settings_lines=0
settings_output=valid
while IFS= read -r line || [ -n "$line" ]; do
  settings_lines=$((settings_lines + 1))
  if [ "$settings_lines" -ne 1 ] || ! jq -e -s '
    length == 1 and (.[0] | type == "object" and
      keys == ["committed", "deprecated", "deprecated_models", "refused"] and
      (.refused | type == "array") and (.deprecated | type == "array") and
      (.deprecated_models | type == "array") and (.committed | type == "object") and
      all(.refused[], .deprecated[], .deprecated_models[], .committed[]; type == "string"))
  ' <<<"$line" >/dev/null; then
    settings_output=invalid
  fi
done <"$TMP/settings.json"
if [ "$settings_lines" -ne 1 ] || [ "$settings_output" = invalid ]; then
  printf 'refresh-error=settings-output value=%s\n' "$ROOT/.agents/skills/orch" >&2
  exit 1
fi
# Sets settings_report from the parse and setting_notes. A failed report
# stops publication and auto-merge.
report_settings() {
  if ! settings_report="$(jq -c --args '. + {notes: $ARGS.positional}' -- ${setting_notes[@]+"${setting_notes[@]}"} <"$TMP/settings.json" |
    python3 "$SCRIPT_DIR/refresh-report.py" --settings)"; then
    printf 'refresh-error=settings-report value=%s\n' "$SCRIPT_DIR/refresh-report.py" >&2
    exit 1
  fi
}
kendex verify --scope project
if ! engine_version="$(kendex --version)"; then
  printf 'refresh-error=read value=engine-version\n' >&2
  exit 1
fi
printf -v version_report 'Engine version: `%s`.' "$engine_version"
git add -A
if git diff --cached --quiet; then
  report_settings
  if [ -n "$pr" ]; then
    gh pr close "$pr" --repo "$GH_REPO"
  fi
  printf 'refresh-state=current pr=none class=none\n'
  printf '%s\n' "$version_report" >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
  # A run with no render change opens no pull request; its settings report
  # still reaches the run summary.
  [ -z "$settings_report" ] || printf '\n%s\n' "$settings_report" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi
if ! tree="$(git write-tree)"; then
  printf 'refresh-error=read value=tree\n' >&2
  exit 1
fi
if [ -n "$old" ] && [ "$tree" = "$(git rev-parse "$old^{tree}")" ]; then
  # A new scheduled run must not replace an identical commit and reset CI.
  head="$old"
  state=unchanged
else
  user_id="$(gh api "users/${REFRESH_APP_SLUG}[bot]" --jq .id)"
  git config user.name "${REFRESH_APP_SLUG}[bot]"
  git config user.email "$user_id+${REFRESH_APP_SLUG}[bot]@users.noreply.github.com"
  # No consumer hook executes under the app token. Verification checks the
  # installed files; the repository's checks run on its pull request.
  git -c core.hooksPath=/dev/null commit -m 'chore: refresh kendex renders'
  head="$(git rev-parse HEAD)"
  state=pushed
fi
class_result=0
class_output="$("$SCRIPT_DIR/../skills/harness-ci/scripts/change-class" --event pull_request --base "$base" --head "$head" --repo "$ROOT" 2>&1)" || class_result=$?
printf '%s\n' "$class_output" >&2
class=""
class_line=""
while IFS= read -r line; do
  case "$line" in
    change_class=*) class="${line#change_class=}" ;;
    'class: class='*) class_line="$line" ;;
    # Every verdict carries a queue-only line; only these causes name the
    # repository's own settings.
    'setting-unset: '* | 'queue-only: '*' cause=queue-list-undeclared' | \
      'queue-only: '*' cause=queue-settings-unreadable') setting_notes+=("$line") ;;
  esac
done <<<"$class_output"
# An unmeasured standard verdict widens review and CI. Narrower classes still
# need measurement, with leading fields that agree with stdout.
if [ "$class_result" -ne 0 ] || [ -z "$class" ] ||
    { [[ "$class_line" != "class: class=$class measured=true "* ]] &&
      { [ "$class" != standard ] || [[ "$class_line" != "class: class=standard measured=false "* ]]; }; }; then
  printf 'refresh-error=read value=class\n' >&2
  exit 1
fi
report_settings
merge_note='The refresh workflow waits for GitHub to show the published head before requesting auto-merge. If the head stays unseen, the run reports an unarmed warning. Check the run result for the arm outcome. The merge queue controls merging after auto-merge is enabled or this pull request is queued.'
printf -v body 'Generated kendex updates.\n\n%s\n\nChange class: `%s`.\n\nClassifier:\n```text\n%s\n```\n\n%s\n' "$version_report" "$class" "$class_line" "$merge_note"
if [ -n "$settings_report" ]; then
  printf -v body '%s\n%s\n' "$body" "$settings_report"
fi
if [ -n "$retired_items" ]; then
  printf -v body '%s\nRetired items:\n```text\n%s```\n' "$body" "$retired_items"
fi
if [ "$state" = pushed ]; then
  push_status=0
  git push "--force-with-lease=refs/heads/kendex/refresh:$old" origin HEAD:refs/heads/kendex/refresh 2>"$TMP/push-stderr" || push_status=$?
  cat -- "$TMP/push-stderr" >&2
  if [ "$push_status" -ne 0 ]; then
    if [ "$pr" = "" ]; then
      if ! pr="$(gh api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:kendex/refresh&sort=created&direction=desc&per_page=1" --jq '.[0].number // empty')"; then
        printf 'refresh-error=push-state value=pulls\n' >&2
        exit 1
      fi
    fi
    refresh_lifecycle
    # GitHub's GH006 refusal for a queued branch, as git relays it. The read
    # can still answer active after that refusal, so the refusal decides.
    # GitHub wraps the message, so the lines are joined before matching.
    if ! refusal="$(sed 's/^remote://' "$TMP/push-stderr" | tr -s ' \t\r\n' ' ')"; then
      printf 'refresh-error=read value=push-stderr\n' >&2
      exit 1
    fi
    case "$refusal" in
      *'GH006: Protected branch update failed'*'has been added to a merge queue. Branches that are queued for merging cannot be updated.'*)
        case "$reason" in active | armed) reason=queued ;; esac ;;
    esac
    # An armed or active pull request that GitHub has not taken leaves the
    # refusal unexplained, so the push failure stands.
    case "$reason" in
      queued | merged | closed | branch-gone)
        printf 'refresh-state=deferred reason=%s\n' "$reason"
        exit 0 ;;
    esac
    printf 'refresh-error=push value=%s\n' "$push_status" >&2
    exit 1
  fi
fi
if [ -z "$pr" ]; then
  pr="$(gh api --method POST "repos/$GH_REPO/pulls" -f head=kendex/refresh -f base="$default" -f title='chore: refresh kendex renders' -f body="$body" --jq .number)"
else
  gh api --method PATCH "repos/$GH_REPO/pulls/$pr" -f body="$body" >/dev/null
fi
arm_status=0
rg_arm_published_head "$GH_REPO" "$pr" "$head" squash || arm_status=$?
if [ "$arm_status" -ne 0 ]; then
  printf 'refresh-error=arm pr=%s pushed=%s head=%s value=%s\n' "$pr" "$head" "$RG_ARM_SEEN" "$arm_status" >&2
  exit "$arm_status"
fi
if [ "$RG_ARM_RESULT" = unmatched ]; then
  printf 'refresh-state=unarmed pr=%s pushed=%s head=%s\n' "$pr" "$head" "$RG_ARM_SEEN"
  printf '::warning title=refresh unarmed::pull request %s left unarmed: GitHub showed %s, pushed %s\n' "$pr" "$RG_ARM_SEEN" "$head"
  exit 0
fi
# gh can succeed on a merge-queue repository without enabling auto-merge.
refresh_lifecycle
case "$reason" in
  armed | queued | merged) ;;
  *)
    printf 'refresh-error=arm-state pr=%s pushed=%s value=%s\n' "$pr" "$head" "$reason" >&2
    exit 1 ;;
esac
printf 'refresh-state=%s pr=%s class=%s\n' "$state" "$pr" "$class"
