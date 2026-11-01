#!/usr/bin/env bash
# The repository queue selector change-class runs where every other queue
# rule reads false: the command the base commit's HARNESS_CI_QUEUE_SELECTOR
# names, asked about the verdict's class, the docs verdict, the changed paths
# and the event, out of a private checkout of the base commit. A non-empty
# list in its named output keeps the change in the queue, `[]` leaves the
# answer as it was, and every failure reads queue-only.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

# The fixture's selector: one job per changed path under slow/ or named
# docs/slow*, each spelling the inputs it was asked with and the base tree's
# marker, and after it another output, an empty list, which a reader blind
# to the output's name would take in its place. A
# path under fail/ exits 3, one under garbled/ writes no list, and a caller's
# environment reaching it exits 4.
SELECTOR='#!/usr/bin/env bash
set -euo pipefail
[ -z "${LEAKED:-}" ] || exit 4
marker="$(cat tree-marker)"
list=""
while IFS= read -r path; do
  case "$path" in
    fail/*) exit 3 ;;
    garbled/*) printf "jobs=garbled\n" >>"$GITHUB_OUTPUT"; exit 0 ;;
    slow/* | docs/slow*) list="${list:+$list,}\"$CHANGE_CLASS:$DOCS_ONLY:$EVENT:$marker:$path\"" ;;
  esac
done <<<"$CHANGED_PATHS"
printf "jobs=[%s]\nother=[]\n" "$list" >>"$GITHUB_OUTPUT"'

repo="$(new_repo queue-selector)"
mkdir -p "$repo/ci"
printf '%s\n' "$SELECTOR" >"$repo/ci/select"
chmod +x "$repo/ci/select"
printf 'base\n' >"$repo/tree-marker"
commit_paths "$repo" baseline seed.txt
seed="$(git -C "$repo" rev-parse HEAD)"

# A base commit whose settings declare the queue list GLOBS, empty unless
# given, beside SELECTOR, or no selector where SELECTOR is `-`. Each names a
# per-push reason, the opt-back the queue list and selector are read under.
selector_base() { # SELECTOR [GLOBS] -> prints the base commit
  git -C "$repo" checkout -q -B base-case "$seed"
  printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "selector suite"\nHARNESS_CI_QUEUE_PATHS = "%s"\n' "${2:-}" >"$repo/kendex.settings.toml"
  [ "$1" = - ] || printf 'HARNESS_CI_QUEUE_SELECTOR = "%s"\n' "$1" >>"$repo/kendex.settings.toml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "settings base"
  git -C "$repo" rev-parse HEAD
}
declared_base="$(selector_base "ci/select jobs")"
plain_base="$(selector_base -)"
absent_base="$(selector_base "ci/missing jobs")"
bare_base="$(selector_base "ci/select")"
climbing_base="$(selector_base "../select jobs")"
listed_base="$(selector_base "ci/select jobs" "infra/*")"

# LINES lines of content appended under PATH.
write_lines() { # PATH COUNT
  local n=0
  mkdir -p "$repo/$(dirname "$1")"
  while [ "$n" -lt "$2" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$repo/$1"
  done
}

# The queue-only line of one row: EDITS, each PATH=COUNT, committed on BASE
# and judged against it at ROW_EVENT, with ROW_ENV, when set, as one
# NAME=VALUE the classifier runs with.
ROW_ENV=""
ROW_EVENT=pull_request
run_row() { # CLASSIFIER BASE EDITS...
  local classifier="$1" row_base="$2" edit
  shift 2
  git -C "$repo" checkout -q -B case "$row_base"
  git -C "$repo" clean -qfd
  for edit in "$@"; do write_lines "${edit%=*}" "${edit##*=}"; done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "row"
  env ${ROW_ENV:+"$ROW_ENV"} "$classifier" --repo "$repo" --event "$ROW_EVENT" \
    --base "$row_base" --head HEAD 2>&1 >/dev/null | sed -n 's/^queue-only: //p'
}

# label | expected queue-only line | edits | base | environment | event
TABLE='a path the selector names is queue-only|queue_only=true cause=queue-selection selector=ci/select output=jobs value=["micro:false:pull_request:base:slow/run.sh"]|slow/run.sh=2|declared_base|
a path the selector names no job for answers as without a selector|queue_only=false cause=no-queue-path|runtime/product.ts=2|declared_base|
a repository that declares no selector answers as before|queue_only=false cause=no-queue-path|slow/run.sh=2|plain_base|
the selector is asked about a trivial class and its docs verdict|queue_only=true cause=queue-selection selector=ci/select output=jobs value=["trivial:true:pull_request:base:docs/slow.md"]|docs/slow.md=2|declared_base|
the selector is asked about a class refused before the docs verdict|queue_only=true cause=queue-selection selector=ci/select output=jobs value=["standard:false:pull_request:base:slow/run.sh"]|hooks/guard.sh=2 slow/run.sh=2|declared_base|
the base commit'"'"'s selector judges where the branch changes it|queue_only=true cause=queue-selection selector=ci/select output=jobs value=["micro:false:pull_request:base:slow/run.sh"]|ci/select=2 tree-marker=2 slow/run.sh=2|declared_base|
the selector runs without the caller'"'"'s environment|queue_only=true cause=queue-selection selector=ci/select output=jobs value=["micro:false:pull_request:base:slow/run.sh"]|slow/run.sh=2|declared_base|LEAKED=1
a selector named in the process environment alone never runs|queue_only=false cause=no-queue-path|slow/run.sh=2|plain_base|HARNESS_CI_QUEUE_SELECTOR=ci/select jobs
a failing selector is queue-only|queue_only=true cause=queue-selector-failed selector=ci/select detail=exit-3|fail/x=2|declared_base|
a selector output that is no list is queue-only|queue_only=true cause=queue-selector-failed selector=ci/select detail=output-unreadable|garbled/x=2|declared_base|
a selector the base does not hold is queue-only|queue_only=true cause=queue-selector-failed selector=ci/missing detail=command-absent|runtime/product.ts=2|absent_base|
a selector setting naming no output is queue-only|queue_only=true cause=queue-selector-failed detail=setting-malformed|runtime/product.ts=2|bare_base|
a selector outside the repository is queue-only|queue_only=true cause=queue-selector-failed detail=setting-malformed|runtime/product.ts=2|climbing_base|
a path the repository list names answers before the selector runs|queue_only=true cause=repository-queue-path path=infra/deploy.sh glob=infra/*|infra/deploy.sh=2|listed_base|
a push runs no selector|queue_only=false cause=no-queue-path|slow/run.sh=2|declared_base||push'

# The row of TABLE whose label is LABEL, as `expected|edits|base|env|event`.

rows=0
while IFS='|' read -r label expected edits row_base ROW_ENV ROW_EVENT; do
  rows=$((rows + 1))
  ROW_EVENT="${ROW_EVENT:-pull_request}"
  # shellcheck disable=SC2086
  assert_eq "$label" "$expected" "$(run_row "$CHANGE_CLASS" "${!row_base}" $edits)"
done <<<"$TABLE"
ROW_ENV=""
ROW_EVENT=pull_request
require_rows queue-selector "$rows"

# The suite's must-fail control: a planted copy that never calls the selector
# answers the row it holds otherwise.
planted="$(mutant no-call change-class '  [ "$QUEUE_ONLY" = true ] || queue_selection "$1"' -)"
control_label="a path the selector names is queue-only"
control_row=""
while IFS='|' read -r label expected edits row_base env row_event; do
  [ "$label" != "$control_label" ] || control_row="$edits|$row_base|$env|$row_event"
done <<<"$TABLE"
[ -n "$control_row" ] || { echo "FAIL: no row labelled '$control_label'" >&2; exit 1; }
IFS='|' read -r edits row_base ROW_ENV ROW_EVENT <<<"$control_row"
ROW_EVENT="${ROW_EVENT:-pull_request}"
# shellcheck disable=SC2086
assert_eq "control no-call for: $control_label" "queue_only=false cause=no-queue-path" \
  "$(run_row "$planted" "${!row_base}" $edits)"

report queue-selector
