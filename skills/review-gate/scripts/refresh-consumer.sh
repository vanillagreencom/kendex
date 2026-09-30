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
kendex refresh --scope project --yes --leave
"$SCRIPT_DIR/adopt-refresh.sh" --templates-dir "$ROOT/.agents/skills/review-gate/templates"
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
