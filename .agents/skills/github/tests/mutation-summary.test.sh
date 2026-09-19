#!/usr/bin/env bash
# The summary the three batch-mutation commands render after their writes:
# resolve-thread, unresolve-thread and dismiss-review each close with one jq
# filter that reports `success` from the failed count, and the exit status is
# read back from that `success` so it reports the mutations rather than the
# rendering.
#
# jq parses `key: a == b` inside `{}` as a syntax error, so an unparenthesized
# comparison there aborts the command after every mutation has already landed.
# dismiss-review reached it on every dismissal, which is the shipped path that
# aborted: the orch review-pr-comments workflow runs `dismiss-review [PR] --bot`
# for a contested bot review. resolve-thread and unresolve-thread reached it only
# when one call carried two or more thread ids; both shipped call sites, in that
# same workflow and in merge-pr's post-merge thread read, pass a single id, which
# takes the single-thread branch instead.
#
# A row is `label|scenario|argv|rc|out|err|calls`:
#   scenario  which command runs and what the gh stub answers
#   argv      that command's arguments as written
#   rc        the exit status
#   out       stdout as compact JSON; `-` when empty
#   err       stderr's first line; `-` when empty
#   calls     every gh call by kind, in order (`auth`, `repo`, `graphql`,
#             `api:<path>`); `-` for none. This is where a row says the
#             mutations reached the API before the summary was rendered.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
COMMANDS="$REPO_ROOT/skills/github/scripts/commands"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# The lib derives PROJECT_ROOT through git at source time, so the working
# directory is a repository; gh is the staged fake.
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

ID_A="PRRT_kwDOaaaaaa"
ID_B="PRRT_kwDObbbbbb"
BOT="review-bot[bot]"
DISMISS_REFUSAL="HTTP 403: Not authorized to dismiss"

# COMMAND_DIR is where the script under test is read from, so a control can
# point the same rows at a mutated copy. RUN_ENV is what a scenario adds to the
# command's environment.
COMMAND_DIR="$COMMANDS"
COMMAND=""
RUN_ENV=()

# build SCENARIO — pick the command and stage every answer it will ask for.
build() {
  gh_stub_reset
  RUN_ENV=()
  case "$1" in
  resolve-two)
    COMMAND="resolve-thread.sh"
    gh_stub_answer api-graphql "$(jq -nc --arg a "$ID_A" --arg b "$ID_B" \
      '{data: {t0: {thread: {id: $a, isResolved: true}}, t1: {thread: {id: $b, isResolved: true}}}}')"
    ;;
  resolve-two-partial)
    COMMAND="resolve-thread.sh"
    gh_stub_answer api-graphql "$(jq -nc --arg a "$ID_A" --arg b "$ID_B" \
      '{data: {t0: {thread: {id: $a, isResolved: true}}, t1: {thread: {id: $b, isResolved: false}}}}')"
    ;;
  resolve-one)
    COMMAND="resolve-thread.sh"
    gh_stub_answer api-graphql "$(jq -nc --arg a "$ID_A" \
      '{data: {resolveReviewThread: {thread: {id: $a, isResolved: true}}}}')"
    ;;
  unresolve-two)
    COMMAND="unresolve-thread.sh"
    gh_stub_answer api-graphql "$(jq -nc --arg a "$ID_A" --arg b "$ID_B" \
      '{data: {t0: {thread: {id: $a, isResolved: false}}, t1: {thread: {id: $b, isResolved: false}}}}')"
    ;;
  unresolve-two-partial)
    COMMAND="unresolve-thread.sh"
    gh_stub_answer api-graphql "$(jq -nc --arg a "$ID_A" --arg b "$ID_B" \
      '{data: {t0: {thread: {id: $a, isResolved: false}}, t1: {thread: {id: $b, isResolved: true}}}}')"
    ;;
  dismiss-two)
    COMMAND="dismiss-review.sh"
    RUN_ENV=(GH_BOT_USERNAME="$BOT")
    # Staged before the reviews listing: the dismissal path contains
    # `/reviews` too, and the stub takes the first selector that matches.
    gh_stub_answer 'api:/dismissals' '{}'
    gh_stub_answer 'api:/reviews' "$(jq -nc --arg bot "$BOT" \
      '[{id: 555, state: "CHANGES_REQUESTED", user: {login: $bot}},
        {id: 556, state: "CHANGES_REQUESTED", user: {login: $bot}}]')"
    ;;
  dismiss-two-refused)
    build dismiss-two
    RUN_ENV=(GH_BOT_USERNAME="$BOT")
    gh_stub_fail 'api:/dismissals' 1 "$DISMISS_REFUSAL"
    ;;
  *)
    printf 'unknown scenario: %s\n' "$1" >&2
    exit 2
    ;;
  esac
}

out_text() {
  local text
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  jq -c . <<<"$text" 2>/dev/null || printf '%s' "$text" | paste -s -d ';' -
}

err_text() {
  local text
  text="$(head -n 1 "$TMP_ROOT/stderr")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  # jq's parser wording and the program line number are its internals, not a
  # contract, and the suite runs on whatever jq the ubuntu and macos runner
  # images ship. A compile error reduces to the part every build states: it is
  # a syntax error, and `==` is what it choked on. A build that words even that
  # differently prints its raw line here and fails loudly.
  case "$text" in
    "jq: error: syntax error"*"unexpected =="*)
      printf 'jq-syntax-error-at-=='
      return
      ;;
  esac
  printf '%s' "$text"
}

# The stub logs one line per call, so a call carrying a multi-line GraphQL
# query — the single-thread branch builds one — spans several. A line whose
# first word is not a gh subcommand is one of those continuations and is
# dropped: an unstaged first word never reaches the log as a call, because the
# stub refuses it.
calls() {
  local line out=""
  while IFS= read -r line; do
    case "$line" in
      "auth status"*) out="$out,auth" ;;
      "repo view"*) out="$out,repo" ;;
      "api graphql"*) out="$out,graphql" ;;
      "api "*) line="${line#api }"; out="$out,api:${line%% *}" ;;
    esac
  done < <(gh_stub_calls)
  [[ "$out" != "" ]] && printf '%s' "${out#,}" || printf -- '-'
}

run() {
  local rc=0
  local -a argv
  # shellcheck disable=SC2206
  argv=($1)
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$COMMAND_DIR/$COMMAND" "${argv[@]}" \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s' "$rc" "$(out_text)" "$(err_text)" "$(calls)"
}

run_table() {
  local title="$1" rows="$2" label scenario argv rc out err want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label scenario argv rc out err want <<<"$row"
    for field in "$label" "$scenario" "$argv" "$rc" "$out" "$err" "$want"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    build "$scenario"
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$err calls=$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

RESOLVED_TWO="{\"success\":true,\"resolved\":[\"$ID_A\",\"$ID_B\"],\"failed\":[]}"
RESOLVED_ONE="{\"success\":true,\"resolved\":[\"$ID_A\"],\"failed\":[]}"
UNRESOLVED_TWO="{\"success\":true,\"unresolved\":[\"$ID_A\",\"$ID_B\"],\"failed\":[]}"
DISMISSED_TWO="{\"success\":true,\"dismissed\":[{\"review_id\":555,\"user\":\"$BOT\",\"state\":\"DISMISSED\"},{\"review_id\":556,\"user\":\"$BOT\",\"state\":\"DISMISSED\"}],\"failed\":[]}"

# The inverse of each row above: a batch whose mutations did not all land names
# them under `failed` with success false and exits 1, the status every other
# failure path in these three scripts already returns.
RESOLVED_PARTIAL="{\"success\":false,\"resolved\":[\"$ID_A\"],\"failed\":[\"$ID_B\"]}"
UNRESOLVED_PARTIAL="{\"success\":false,\"unresolved\":[\"$ID_A\"],\"failed\":[\"$ID_B\"]}"
REFUSED_ENTRY="\"user\":\"$BOT\",\"error\":\"$DISMISS_REFUSAL\""
DISMISS_REFUSED="{\"success\":false,\"dismissed\":[],\"failed\":[{\"review_id\":555,$REFUSED_ENTRY},{\"review_id\":556,$REFUSED_ENTRY}]}"

THREAD_CALLS="auth,graphql"
DISMISS_CALLS="repo,auth,api:repos/owner/repo/pulls/23/reviews,api:repos/owner/repo/pulls/23/reviews/555/dismissals,api:repos/owner/repo/pulls/23/reviews/556/dismissals"

run_table "the summary renders, and the exit status reports the mutations" "\
resolve-thread with two ids names both as resolved|resolve-two|$ID_A $ID_B|0|$RESOLVED_TWO|-|$THREAD_CALLS
resolve-thread with one id keeps the single-thread answer|resolve-one|$ID_A|0|$RESOLVED_ONE|-|$THREAD_CALLS
unresolve-thread with two ids names both as unresolved|unresolve-two|$ID_A $ID_B|0|$UNRESOLVED_TWO|-|$THREAD_CALLS
dismiss-review names both dismissals|dismiss-two|23 --bot|0|$DISMISSED_TWO|-|$DISMISS_CALLS
one thread left unresolved is named under failed and exits 1|resolve-two-partial|$ID_A $ID_B|1|$RESOLVED_PARTIAL|-|$THREAD_CALLS
one thread left resolved is named under failed and exits 1|unresolve-two-partial|$ID_A $ID_B|1|$UNRESOLVED_PARTIAL|-|$THREAD_CALLS
a refused dismissal is named under failed and exits 1|dismiss-two-refused|23 --bot|1|$DISMISS_REFUSED|-|$DISMISS_CALLS
"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/commands"
cp -R "$REPO_ROOT/skills/github/scripts/lib" "$MUTANT_DIR/lib"

# mutate FILE OLD NEW — replace the literal OLD with NEW, asserting the file
# carried exactly one OLD and carries none after. OLD's count is what
# establishes the edit for both callers, and it is the only count that can:
# unparenthesize's NEW is a substring of its OLD, so counting NEW would read 1
# either way.
mutate() {
  local file="$1" old="$2" new="$3" content before after
  before="$(grep -F -c -- "$old" "$file")"
  [[ "$before" == "1" ]] || {
    printf 'control: %s carries %s occurrences of the live form, not 1\n' "$file" "$before" >&2
    exit 2
  }
  content="$(cat "$file")"
  printf '%s\n' "${content//"$old"/"$new"}" >"$file"
  after="$(grep -F -c -- "$old" "$file" || true)"
  [[ "$after" == "0" ]] || {
    printf 'control: %s still carries the live form after the mutation\n' "$file" >&2
    exit 2
  }
}

# unparenthesize FILE LIVE — LIVE with its outer parentheses dropped.
unparenthesize() {
  local bare="${2#(}"
  mutate "$1" "$2" "${bare%)}"
}

# drop_status_read FILE — the summary is still rendered and printed, but its
# `success` no longer reaches the exit status.
drop_status_read() {
  mutate "$1" '[ "$(jq -r '"'"'.success'"'"' <<<"$summary")" = "true" ] || exit 1' ':'
}

stage_mutants() {
  cp "$COMMANDS/resolve-thread.sh" "$COMMANDS/unresolve-thread.sh" \
    "$COMMANDS/dismiss-review.sh" "$MUTANT_DIR/commands/"
}

echo "=== must-fail controls: the unparenthesized comparison ==="
# Drop the parentheses that make the comparison a value, keeping the rest of
# each summary filter. Every row above reddens, and it reddens the way the
# field did: the mutations have landed, jq dies at compile time, and the
# command exits 3 having printed no summary at all.
stage_mutants
unparenthesize "$MUTANT_DIR/commands/resolve-thread.sh" '(($failed | length) == 0)'
unparenthesize "$MUTANT_DIR/commands/unresolve-thread.sh" '(($failed | length) == 0)'
unparenthesize "$MUTANT_DIR/commands/dismiss-review.sh" '(([.[] | select(.ok == false)] | length) == 0)'

JQ_ERR="jq-syntax-error-at-=="

COMMAND_DIR="$MUTANT_DIR/commands"
build resolve-two
assert_eq "$(run "$ID_A $ID_B")" "rc=3 out=- err=$JQ_ERR calls=$THREAD_CALLS" \
  "must-fail control: resolve-thread resolves both threads, prints no summary and exits 3"
build unresolve-two
assert_eq "$(run "$ID_A $ID_B")" "rc=3 out=- err=$JQ_ERR calls=$THREAD_CALLS" \
  "must-fail control: unresolve-thread unresolves both threads, prints no summary and exits 3"
build dismiss-two
assert_eq "$(run '23 --bot')" "rc=3 out=- err=$JQ_ERR calls=$DISMISS_CALLS" \
  "must-fail control: dismiss-review dismisses both reviews, prints no summary and exits 3"

echo "=== must-fail controls: the exit status stops reading the summary ==="
# The other half of the rule: stop reading `success` back into the exit status.
# The three failure rows above redden, each reporting the mutations it lost as
# a success.
stage_mutants
drop_status_read "$MUTANT_DIR/commands/resolve-thread.sh"
drop_status_read "$MUTANT_DIR/commands/unresolve-thread.sh"
drop_status_read "$MUTANT_DIR/commands/dismiss-review.sh"

build resolve-two-partial
assert_eq "$(run "$ID_A $ID_B")" "rc=0 out=$RESOLVED_PARTIAL err=- calls=$THREAD_CALLS" \
  "must-fail control: an unresolved thread reads as a success"
build unresolve-two-partial
assert_eq "$(run "$ID_A $ID_B")" "rc=0 out=$UNRESOLVED_PARTIAL err=- calls=$THREAD_CALLS" \
  "must-fail control: a thread left resolved reads as a success"
build dismiss-two-refused
assert_eq "$(run '23 --bot')" "rc=0 out=$DISMISS_REFUSED err=- calls=$DISMISS_CALLS" \
  "must-fail control: a refused dismissal reads as a success"
COMMAND_DIR="$COMMANDS"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
