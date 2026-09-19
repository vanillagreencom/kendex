#!/usr/bin/env bash
# The summary the three batch-mutation commands render after their writes:
# resolve-thread, unresolve-thread and dismiss-review each close with one jq
# filter that reports `success` from the failed count, and the exit status is
# read back from that `success` so it reports the mutations rather than the
# rendering.
#
# jq 1.7 parses `key: a == b` inside `{}` as a syntax error, so an
# unparenthesized comparison there aborts the command after every mutation has
# already landed. Not every jq build reads that object value the same way, so the
# must-fail control below probes the running jq for what it does with the bare
# form rather than assuming the compile error, and a byte-level guard beside it
# is what proves the shipped filter still carries the parentheses on a build
# that accepts either form.
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

# want_of TAIL — the output a command must print, from TAIL, a row's
# `rc|out|err|calls` expectation. The forward table and every must-fail control
# below read their expectation through here, so a control can never compare
# against a spelling no forward row asserts.
want_of() {
  local rc out err calls field
  IFS='|' read -r rc out err calls <<<"$1"
  for field in "$rc" "$out" "$err" "$calls"; do
    [[ "$field" != "" ]] || {
      printf 'an expectation with an empty field asserts nothing: %s\n' "$1" >&2
      exit 1
    }
  done
  printf 'rc=%s out=%s err=%s calls=%s' "$rc" "$out" "$err" "$calls"
}

run_table() {
  local title="$1" rows="$2" label scenario argv tail want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label scenario argv tail <<<"$row"
    for field in "$label" "$scenario" "$argv" "$tail"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    want="$(want_of "$tail")"
    build "$scenario"
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

# assert_killed GOT FORWARD MUTANT LABEL — the mutated command's output is not
# what the forward row requires, and is what this mutation produces.
#
# The first half is the kill: the very comparison that passes against the
# shipped command fails against the mutant, so the forward row is established as
# the thing that catches the defect rather than merely described. The second
# half pins what the mutation changed, so a mutant broken some other way is not
# counted as the kill.
assert_killed() {
  local got="$1" forward="$2" mutant="$3" label="$4"
  if [[ "$got" == "$forward" ]]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        the forward row still passes against the mutant: %s\n' \
      "$label" "$got"
    return
  fi
  assert_eq "$got" "$mutant" "$label"
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

# The three partial-batch rows' expectations, named because the drop_status_read
# controls below have to fail against these very strings. A control carrying its
# own copy would, once a row changed, compare against a spelling no row asserts,
# and would then be satisfied by any output at all.
PARTIAL_RESOLVE="1|$RESOLVED_PARTIAL|-|$THREAD_CALLS"
PARTIAL_UNRESOLVE="1|$UNRESOLVED_PARTIAL|-|$THREAD_CALLS"
PARTIAL_DISMISS="1|$DISMISS_REFUSED|-|$DISMISS_CALLS"

run_table "the summary renders, and the exit status reports the mutations" "\
resolve-thread with two ids names both as resolved|resolve-two|$ID_A $ID_B|0|$RESOLVED_TWO|-|$THREAD_CALLS
resolve-thread with one id keeps the single-thread answer|resolve-one|$ID_A|0|$RESOLVED_ONE|-|$THREAD_CALLS
unresolve-thread with two ids names both as unresolved|unresolve-two|$ID_A $ID_B|0|$UNRESOLVED_TWO|-|$THREAD_CALLS
dismiss-review names both dismissals|dismiss-two|23 --bot|0|$DISMISSED_TWO|-|$DISMISS_CALLS
one thread left unresolved is named under failed and exits 1|resolve-two-partial|$ID_A $ID_B|$PARTIAL_RESOLVE
one thread left resolved is named under failed and exits 1|unresolve-two-partial|$ID_A $ID_B|$PARTIAL_UNRESOLVE
a refused dismissal is named under failed and exits 1|dismiss-two-refused|23 --bot|$PARTIAL_DISMISS
"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/commands"
cp -R "$REPO_ROOT/skills/github/scripts/lib" "$MUTANT_DIR/lib"

# replace_first LINE OLD NEW — LINE with its first literal OLD replaced by NEW.
# Returns 1, printing nothing, when LINE does not carry OLD.
#
# The search walks offsets and compares with `=` inside `[[ ]]`, which is string
# equality and not pattern matching. Nothing here is a glob, a BRE or an ERE, so
# the `[`, `]` and `.` that two of the three OLD strings carry are just
# characters. LINE is one line of a script, so the walk is short.
replace_first() {
  local line="$1" old="$2" new="$3" span="${#2}" stop i=0
  stop=$(( ${#1} - span ))
  while [ "$i" -le "$stop" ]; do
    if [[ "${line:i:span}" = "$old" ]]; then
      printf '%s' "${line:0:i}$new${line:$((i + span))}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# mutate FILE OLD NEW — write FILE with its one literal OLD replaced by NEW,
# then establish that the edit is in the file that will run.
#
# A mutation that quietly does not land turns a must-fail control into a row
# that passes on the unmutated script, and two rounds of this suite shipped
# exactly that. So the substitution uses no tool whose dialect differs between
# the ubuntu and macOS runner images, and every step names itself when it fails:
#
#   - `${content//"$old"/"$new"}` is not used. Under Bash 3.2 the replacement's
#     inner quotes are not removed, so the mutant carried the unparenthesized
#     text as a jq STRING — a filter that compiles and renders a string where
#     the control expects a compile error.
#   - sed is not used: two OLD strings carry `[`, `]` and `.`, which a BRE reads
#     as metacharacters, and `sed -i` takes a mandatory suffix on BSD sed.
#   - awk is not used: its literals have to arrive through ENVIRON or `-v`, and
#     the macOS image ships a different awk from the ubuntu one.
#   - Only grep, head, tail, cmp, cp, chmod and printf run here, each with POSIX
#     options that BSD and GNU spell the same. The substitution itself is
#     replace_first, which is Bash and nothing else.
#   - The mutated bytes are copied onto FILE and the execute bit set again,
#     rather than moved over it, which drops the mode.
#
# The proof that the edit landed is `cmp`: the mutated bytes differ from the
# staged bytes, and FILE no longer carries OLD. Counting NEW would establish
# nothing on its own — unparenthesize's NEW is a substring of its OLD, and
# drop_status_read's NEW is a colon.
mutate() {
  local file="$1" old="$2" new="$3" hit count lineno line mutated
  hit="$(grep -F -n -- "$old" "$file" || true)"
  count="$(printf '%s' "$hit" | grep -c . || true)"
  [[ "$count" == "1" ]] || {
    printf 'control: %s carries %s line(s) with the live form, not 1\n' "$file" "$count" >&2
    exit 2
  }
  lineno="${hit%%:*}"
  line="${hit#*:}"

  mutated="$(replace_first "$line" "$old" "$new")" || {
    printf 'control: the live form is not a literal substring of %s line %s\n' \
      "$file" "$lineno" >&2
    exit 2
  }

  cp "$file" "$TMP_ROOT/mutate.staged"
  {
    if [ "$lineno" -gt 1 ]; then
      head -n "$((lineno - 1))" "$TMP_ROOT/mutate.staged"
    fi
    printf '%s\n' "$mutated"
    tail -n "+$((lineno + 1))" "$TMP_ROOT/mutate.staged"
  } >"$TMP_ROOT/mutated"

  cmp -s "$TMP_ROOT/mutate.staged" "$TMP_ROOT/mutated" && {
    printf 'control: the mutation left %s byte-identical; the replacement never landed\n' \
      "$file" >&2
    exit 2
  }
  cp "$TMP_ROOT/mutated" "$file"
  chmod +x "$file"

  count="$(grep -F -c -- "$old" "$file" || true)"
  [[ "$count" == "0" ]] || {
    printf 'control: %s still carries the live form %s time(s) after the mutation\n' \
      "$file" "$count" >&2
    exit 2
  }
  [[ -x "$file" ]] || {
    printf 'control: %s is not executable after the mutation\n' "$file" >&2
    exit 2
  }
}

# bare FORM — FORM without its outer parentheses. The affixes are variables so
# the patterns carry no quotes of their own.
bare() {
  local open='(' close=')' inner
  inner="${1#$open}"
  printf '%s' "${inner%$close}"
}

# unparenthesize FILE LIVE — LIVE with its outer parentheses dropped.
unparenthesize() {
  mutate "$1" "$2" "$(bare "$2")"
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

# The comparison each summary filter parenthesizes, as shipped. The thread
# commands share a form; dismiss-review counts refused entries instead.
LIVE_THREAD='(($failed | length) == 0)'
LIVE_DISMISS='(([.[] | select(.ok == false)] | length) == 0)'

# jq_reads FORM — true when the running jq compiles FORM as an object value.
# `empty |` leaves the object unevaluated, so a runtime error over the null
# input cannot be mistaken for a grammar refusal, and `failed` is bound because
# an unbound variable is a compile error on every build.
jq_reads() {
  jq -n --argjson failed '[]' "empty | {success: $1, rest: 1}" >/dev/null 2>&1
}

# live_count FILE FORM — how many lines of FILE carry FORM.
live_count() {
  grep -F -c -- "$2" "$1" || true
}

echo "=== the shipped summary filter parenthesizes its comparison ==="
# The guard that holds on every jq build. A revert of the fix drops the count to
# 0 here, and the mutation below refuses with exit 2 for the same reason.
assert_eq "$(live_count "$COMMANDS/resolve-thread.sh" "$LIVE_THREAD")" 1 \
  "resolve-thread carries the parenthesized comparison once"
assert_eq "$(live_count "$COMMANDS/unresolve-thread.sh" "$LIVE_THREAD")" 1 \
  "unresolve-thread carries the parenthesized comparison once"
assert_eq "$(live_count "$COMMANDS/dismiss-review.sh" "$LIVE_DISMISS")" 1 \
  "dismiss-review carries the parenthesized comparison once"

echo "=== must-fail controls: the unparenthesized comparison ==="
# Drop the parentheses that make the comparison a value, keeping the rest of
# each summary filter. On a jq that refuses the bare object value, every row
# above reddens the way the field did: the mutations have landed, jq dies at
# compile time, and the command exits 3 having printed no summary at all. On a
# jq that reads the bare form, the mutant is that jq's equivalent of the shipped
# filter and renders the same summary; the row then holds the mutated command
# reaching the API and rendering, and the guard above holds the parentheses.
stage_mutants
unparenthesize "$MUTANT_DIR/commands/resolve-thread.sh" "$LIVE_THREAD"
unparenthesize "$MUTANT_DIR/commands/unresolve-thread.sh" "$LIVE_THREAD"
unparenthesize "$MUTANT_DIR/commands/dismiss-review.sh" "$LIVE_DISMISS"

JQ_ERR="jq-syntax-error-at-=="

# mutant_want LIVE OUT CALLS — the row the command mutated from LIVE produces on
# the running jq.
mutant_want() {
  if jq_reads "$(bare "$1")"; then
    want_of "0|$2|-|$3"
  else
    want_of "3|-|$JQ_ERR|$3"
  fi
}

for LIVE_FORM in "$LIVE_THREAD" "$LIVE_DISMISS"; do
  if jq_reads "$(bare "$LIVE_FORM")"; then
    printf '  note: this jq reads `%s` as an object value, so that mutant renders the live summary instead of dying\n' \
      "$(bare "$LIVE_FORM")"
  fi
done

COMMAND_DIR="$MUTANT_DIR/commands"
build resolve-two
assert_eq "$(run "$ID_A $ID_B")" "$(mutant_want "$LIVE_THREAD" "$RESOLVED_TWO" "$THREAD_CALLS")" \
  "must-fail control: resolve-thread resolves both threads, then the mutated summary filter decides the rest"
build unresolve-two
assert_eq "$(run "$ID_A $ID_B")" "$(mutant_want "$LIVE_THREAD" "$UNRESOLVED_TWO" "$THREAD_CALLS")" \
  "must-fail control: unresolve-thread unresolves both threads, then the mutated summary filter decides the rest"
build dismiss-two
assert_eq "$(run '23 --bot')" "$(mutant_want "$LIVE_DISMISS" "$DISMISSED_TWO" "$DISMISS_CALLS")" \
  "must-fail control: dismiss-review dismisses both reviews, then the mutated summary filter decides the rest"

echo "=== must-fail controls: the exit status stops reading the summary ==="
# The other half of the rule: stop reading `success` back into the exit status.
# Each row runs the mutant against the expectation its forward row asserts and
# requires that expectation to fail, which is the kill; the mutation it leaves
# behind is the same summary under exit 0, so the tail each row pins is its
# forward tail with the status replaced.
stage_mutants
drop_status_read "$MUTANT_DIR/commands/resolve-thread.sh"
drop_status_read "$MUTANT_DIR/commands/unresolve-thread.sh"
drop_status_read "$MUTANT_DIR/commands/dismiss-review.sh"

build resolve-two-partial
assert_killed "$(run "$ID_A $ID_B")" \
  "$(want_of "$PARTIAL_RESOLVE")" "$(want_of "0|${PARTIAL_RESOLVE#*|}")" \
  "must-fail control: an unresolved thread reads as a success"
build unresolve-two-partial
assert_killed "$(run "$ID_A $ID_B")" \
  "$(want_of "$PARTIAL_UNRESOLVE")" "$(want_of "0|${PARTIAL_UNRESOLVE#*|}")" \
  "must-fail control: a thread left resolved reads as a success"
build dismiss-two-refused
assert_killed "$(run '23 --bot')" \
  "$(want_of "$PARTIAL_DISMISS")" "$(want_of "0|${PARTIAL_DISMISS#*|}")" \
  "must-fail control: a refused dismissal reads as a success"
COMMAND_DIR="$COMMANDS"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
