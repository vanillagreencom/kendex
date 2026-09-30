#!/usr/bin/env bash
# Runs from the default-branch checkout. It rebuilds the rolling branch from
# that checkout, never executes the remote rolling branch, and pushes only
# after the shared classifier measures the complete diff. Only render arms.
# Output records: refresh-state=current pr=none class=none, or
# refresh-state=unchanged|pushed pr=NUMBER class=CLASS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
: "${GH_REPO:?GH_REPO names the running repository}"
: "${GH_TOKEN:?GH_TOKEN must be the repository-scoped app installation token}"
: "${REFRESH_APP_SLUG:?REFRESH_APP_SLUG names that app}"
if [ "$#" -gt 0 ]; then
  printf 'refresh-error=arguments value=%s\n' "$#" >&2
  exit 2
fi
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
git checkout -B kendex/refresh "$base"
export KENDEX_UI=plain
refresh_status=0
refresh_output="$(kendex refresh --scope project --yes --leave 2>&1)" || refresh_status=$?
printf '%s\n' "$refresh_output"
if [ "$refresh_status" -ne 0 ]; then
  printf 'refresh-error=refresh value=%s\n' "$refresh_status" >&2
  exit "$refresh_status"
fi
# refresh has no JSON report. Fall back to blocked.rs's plain conflicts
# section and holds.rs's records; verify cannot report discarded edits.
# ledger.rs counts distinct kind/name items, not rows or harnesses.
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
  kendex refresh --scope project --yes --leave --discard-edits
fi
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
"$SCRIPT_DIR/adopt-refresh.sh" --templates-dir "$ROOT/.agents/skills/review-gate/templates" --workflow-edit-report "$TMP/workflow-edits"
workflow_edits="$(cat "$TMP/workflow-edits")"
settings_report=""
# The release-installed parser must judge its own settings, including on a
# first install. It reads and prints data without the refresh app credential.
# Only the preserved default-branch code consumes its output or publishes.
if [ -e "$ROOT/.agents/skills/orch" ] || [ -L "$ROOT/.agents/skills/orch" ]; then
  if ! env -i PATH="$PATH" HOME="$HOME" bash -s -- "$SCRIPT_DIR" "$ROOT" >"$TMP/settings.json" <<'SETTINGS_PARSE'
set -euo pipefail
source "$1/lib/settings.sh"
source "$2/.agents/skills/orch/scripts/lib/kendex-env.sh"
source "$2/.agents/skills/orch/scripts/lib/overseer-launch.sh"
KENDEX_ENV_FILE="$(rg_setting KENDEX_ENV_FILE "" "")"
kendex_private_env_file private_file "$2"
preference="$(rg_setting ORCH_OVERSEER_PREFERENCE "$OL_DEFAULT_PREFERENCE" "$private_file")"
parse_status=0
ol_preference_entries "$preference" || parse_status=$?
[ "$parse_status" -le 1 ] || exit "$parse_status"
jq -cn --argjson refused_count "${#OL_REFUSED_ENTRIES[@]}" --args \
  '{refused: $ARGS.positional[:$refused_count], deprecated: $ARGS.positional[$refused_count:]}' \
  -- ${OL_REFUSED_ENTRIES[@]+"${OL_REFUSED_ENTRIES[@]}"} \
  ${OL_DEPRECATED_ENTRIES[@]+"${OL_DEPRECATED_ENTRIES[@]}"}
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
        keys == ["deprecated", "refused"] and
        (.refused | type == "array") and (.deprecated | type == "array") and
        all(.refused[], .deprecated[]; type == "string"))
    ' <<<"$line" >/dev/null; then
      settings_output=invalid
    fi
  done <"$TMP/settings.json"
  if [ "$settings_lines" -ne 1 ] || [ "$settings_output" = invalid ]; then
    printf 'refresh-error=settings-output value=%s\n' "$ROOT/.agents/skills/orch" >&2
    exit 1
  fi
  settings_report="$(python3 "$SCRIPT_DIR/refresh-report.py" --settings <"$TMP/settings.json")"
else
  printf 'refresh-settings=orch-absent value=%s\n' "$ROOT/.agents/skills/orch"
fi
kendex verify --scope project
git add -A
if git diff --cached --quiet; then
  if [ -n "$pr" ]; then
    gh pr close "$pr" --repo "$GH_REPO"
  fi
  printf 'refresh-state=current pr=none class=none\n'
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
class_output="$("$SCRIPT_DIR/../../harness-ci/scripts/change-class" --event pull_request --base "$base" --head "$head" --repo "$ROOT" 2>&1)" || class_result=$?
printf '%s\n' "$class_output" >&2
class=""
class_line=""
while IFS= read -r line; do
  case "$line" in
    change_class=*) class="${line#change_class=}" ;;
    'class: class='*) class_line="$line" ;;
  esac
done <<<"$class_output"
# change-class also emits standard as a fallback. Publication requires its
# leading class and measured fields to agree with stdout, not path/cause text.
if [ "$class_result" -ne 0 ] || [ -z "$class" ] || [[ "$class_line" != "class: class=$class measured=true "* ]]; then
  printf 'refresh-error=read value=class\n' >&2
  exit 1
fi
if [ "$class" = render ]; then
  merge_note='Render equality is verified. The refresh workflow arms auto-merge.'
else
  merge_note='Auto-merge is disabled. A repository maintainer reviews and merges this pull request through the normal review and CI gates.'
  if [ -n "$pr" ]; then
    gh pr merge "$pr" --repo "$GH_REPO" --disable-auto
  fi
fi
printf -v body 'Generated kendex updates.\n\nChange class: `%s`.\n\nClassifier:\n```text\n%s\n```\n\n%s\n' "$class" "$class_line" "$merge_note"
if [ -n "$workflow_edits" ]; then
  printf -v body '%s\n%s\n' "$body" "$workflow_edits"
fi
if [ -n "$conflict_count" ]; then
  printf -v body '%s\nOverwritten hand-edited items (from refresh):\n%s' "$body" "$held_items"
fi
if [ -n "$settings_report" ]; then
  printf -v body '%s\n%s\n' "$body" "$settings_report"
fi
if [ "$state" = pushed ]; then
  git push "--force-with-lease=refs/heads/kendex/refresh:$old" origin HEAD:refs/heads/kendex/refresh
fi
if [ -z "$pr" ]; then
  pr="$(gh api --method POST "repos/$GH_REPO/pulls" -f head=kendex/refresh -f base="$default" -f title='chore: refresh kendex renders' -f body="$body" --jq .number)"
else
  gh api --method PATCH "repos/$GH_REPO/pulls/$pr" -f body="$body" >/dev/null
fi
if [ "$class" = render ]; then
  gh pr merge "$pr" --repo "$GH_REPO" --auto --squash --match-head-commit "$head"
fi
printf 'refresh-state=%s pr=%s class=%s\n' "$state" "$pr" "$class"
