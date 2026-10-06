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
# given, beside SELECTOR, or no selector where SELECTOR is `-`.
selector_base() { # SELECTOR [GLOBS] -> prints the base commit
  git -C "$repo" checkout -q -B base-case "$seed"
  printf '[env]\nHARNESS_CI_QUEUE_PATHS = "%s"\n' "${2:-}" >"$repo/kendex.settings.toml"
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
row_of() { # LABEL
  local label expected edits row_base env row_event
  while IFS='|' read -r label expected edits row_base env row_event; do
    [ "$label" != "$1" ] || { printf '%s|%s|%s|%s|%s\n' "$expected" "$edits" "$row_base" "$env" "$row_event"; return 0; }
  done <<<"$TABLE"
  echo "FAIL: no row labelled '$1'" >&2
  exit 1
}

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

# One must-fail control per rule: a planted copy without that rule answers
# the row it holds otherwise.
control() { # ROW_LABEL EXPECTED NAME LINE REPLACEMENT [LINE REPLACEMENT]...
  local label="$1" expected="$2" name="$3" planted edits row_base
  shift 2
  planted="$(mutant "$@")"
  IFS='|' read -r _ edits row_base ROW_ENV ROW_EVENT <<<"$(row_of "$label")"
  ROW_EVENT="${ROW_EVENT:-pull_request}"
  # shellcheck disable=SC2086
  assert_eq "control $name for: $label" "$expected" "$(run_row "$planted" "${!row_base}" $edits)"
  ROW_ENV=""
  ROW_EVENT=pull_request
}
RUN_LINE='  (cd -- "$tree" && env -i PATH="$PATH" HOME="${HOME:-}" CHANGE_CLASS="$1" \'
control "a path the selector names is queue-only" \
  "queue_only=false cause=no-queue-path" \
  no-call change-class '  [ "$QUEUE_ONLY" = true ] || queue_selection "$1"' -
control "a path the selector names no job for answers as without a selector" \
  "queue_only=true cause=queue-selection selector=ci/select output=jobs value=[]" \
  empty-list change-class "    '[]')" "    '[]-never')"
control "a failing selector is queue-only" \
  "queue_only=false cause=queue-selector-failed selector=ci/select detail=exit-3" \
  failure-default change-class '  QUEUE_ONLY=true' '  :'
control "the selector runs without the caller's environment" \
  "queue_only=true cause=queue-selector-failed selector=ci/select detail=exit-4" \
  inherited-environment change-class "$RUN_LINE" \
  '  (cd -- "$tree" && env PATH="$PATH" HOME="${HOME:-}" CHANGE_CLASS="$1" \'
control "the selector is asked about a trivial class and its docs verdict" \
  'queue_only=true cause=queue-selection selector=ci/select output=jobs value=["standard:true:pull_request:base:docs/slow.md"]' \
  fixed-class change-class "$RUN_LINE" \
  '  (cd -- "$tree" && env -i PATH="$PATH" HOME="${HOME:-}" CHANGE_CLASS=standard \'
control "the selector is asked about a trivial class and its docs verdict" \
  'queue_only=true cause=queue-selection selector=ci/select output=jobs value=["trivial:false:pull_request:base:docs/slow.md"]' \
  fixed-docs change-class '    DOCS_ONLY="${docs#docs_only=}" CHANGED_PATHS="$paths" \' \
  '    DOCS_ONLY=false CHANGED_PATHS="$paths" \'
control "the selector is asked about a class refused before the docs verdict" \
  'queue_only=true cause=queue-selector-failed selector=ci/select detail=inputs-unreadable' \
  no-lazy-docs change-class \
  '    docs="$("$HARNESS_ONLY" --mode docs "${harness_args[@]}" --output /dev/null 2>/dev/null)" ||' \
  '    docs="" ||'
control "the base commit's selector judges where the branch changes it" \
  "queue_only=true cause=queue-selector-failed selector=ci/select detail=exit-127" \
  head-tree change-class \
  '  if [ -z "$BASE_REV" ] || ! private_checkout "$tree" "$BASE_REV" "$log"; then' \
  '  if [ -z "$BASE_REV" ] || ! private_checkout "$tree" "$head_rev" "$log"; then'
control "a selector named in the process environment alone never runs" \
  'queue_only=true cause=queue-selection selector=ci/select output=jobs value=["micro:false:pull_request:base:slow/run.sh"]' \
  environment-selector change-class \
  'unset HARNESS_CI_QUEUE_PATHS HARNESS_CI_QUEUE_SELECTOR' 'unset HARNESS_CI_QUEUE_PATHS'
control "a selector outside the repository is queue-only" \
  "queue_only=true cause=queue-selector-failed selector=../select detail=command-absent" \
  climbing change-class "    '' | /* | .. | ../* | */.. | */../*) name=\"\" ;;" "    '') name=\"\" ;;"
control "a path the repository list names answers before the selector runs" \
  "queue_only=false cause=no-queue-path" \
  unconditional-call change-class '  [ "$QUEUE_ONLY" = true ] || queue_selection "$1"' '  queue_selection "$1"'
control "a path the selector names is queue-only" \
  "queue_only=false cause=no-queue-path" \
  name-blind change-class '  if ! value="$(sed -n "s/^$name=//p" "$out" | tail -1)"; then' \
  '  if ! value="$(sed -n "s/^[a-z_]*=//p" "$out" | tail -1)"; then'
control "a push runs no selector" \
  'queue_only=true cause=queue-selection selector=ci/select output=jobs value=["standard:false:push:base:slow/run.sh"]' \
  every-event change-class '    *) return 0 ;;' '    *) ;;'

report queue-selector
