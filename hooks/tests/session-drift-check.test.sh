#!/usr/bin/env bash
# Tests for the session-drift-check hook.
#
# The hook is a thin adapter over `kendex check --quiet`. What it decides is
# which arm the check's exit code chose, and that is a value on its keyed
# lines: `drift=found`, `check=incomplete` or `check=could-not-run`, with
# `exit=<code>` beside the two that name one. The rows pin those and the hook's
# own exit status. The context text under them is written for a model to read
# and its wording is pinned nowhere — no program parses it, so pinning it would
# be pinning prose. How many lines of it were written is pinned, because an
# instruction with no keyed line of its own is held by nothing else. The
# mapping rows drive the hook with a fake `kendex` on PATH that replays a
# scripted exit code and output, so no real install is consulted.
#
# A row is `label|fake rc|fake out|keyed`:
#   fake rc   the exit status the fake kendex returns
#   fake out  the fake's output by word (fake_out maps it); `-` for none
#   keyed     the hook's own keyed lines, in order, joined by `;`; `-` when it
#             writes none. A `line=` value renders as `line=<n>`: the row pins
#             that the failing line is reported, not which line it was
# Every row also asserts the hook's exit 0, the argv `check --quiet`, and that
# stderr is empty — this hook writes to stdout, the session-start context
# channel, and nothing else.
#
# The other table is the notice the hook writes when the kendex command is
# absent. Its rows point the hook at a project and a platform and pin the five
# values it reports: what became of reading this project's manifest, which
# file that was, the packages and bundles it declares, the route that installs
# the command, and the generated trees nothing may hand-edit. A row pins the
# guidance under them by line count alone, because the sentences are written
# for a model and every fact one of them carries stands on a keyed line above
# it. One assertion beside the rows pins that each manifest state writes its
# own sentence, without pinning any of the three. Two further lanes hold the
# hook's two hand-copied enumerations to the Rust constants they mirror.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-print hook) can be run against these same
# assertions.
set -euo pipefail
# A suite run from a git hook inherits these, and they take precedence over
# `git -C`: left set, the fixture repository below would be written into the
# repository the hook fired in.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/session-drift-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
ARGS_LOG="$TMP_ROOT/kendex.args"
CWD_LOG="$TMP_ROOT/kendex.cwd"

# Fake kendex: records its argv and cwd, prints $FAKE_OUT to stderr (the real
# human report goes to stderr), exits $FAKE_RC.
cat >"$BIN_DIR/kendex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ARGS_LOG"
pwd >>"$FAKE_CWD_LOG"
if [ -n "${FAKE_OUT:-}" ]; then
  printf '%s\n' "$FAKE_OUT" >&2
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$BIN_DIR/kendex"

REPORT=$'kendex drift — project scope:\n  1 outdated — run `kendex refresh` to update:\n    ! orch (skill)'
# How many lines the fake's report occupies, derived from the fixture rather
# than written twice: a row pins that the whole report reached stdout.
REPORT_LINES=$(printf '%s\n' "$REPORT" | wc -l | tr -d '[:space:]')

# The fake's output by word.
fake_out() {
  case "$1" in
    -) : ;;
    report) printf '%s' "$REPORT" ;;
    unevaluated) printf '%s' $'source comparison needed:\n  skill '\''orch'\'': source changed since evaluation; not yet re-evaluated\nNext: kendex refresh --yes in this checkout to refresh project packages.' ;;
    could-not-check) printf '%s' $'could not check:\n  manifest: expected a table' ;;
    error-inside-a-line) printf '%s' $'could not check:\n  source github.com/x/y unreachable since 2026-08-01: error: cannot lock ref' ;;
    Error-line) printf '%s' 'Error: loading lock file' ;;
    usage-error) printf '%s' $'error: unexpected argument \'--bogus\' found\n\nUsage: kendex check --quiet' ;;
    fatal) printf '%s' 'kendex: fatal' ;;
    # A report that spells a keyed line of its own. What the hook relays is
    # data, and data cannot forge the hook's contract: the keyed block is the
    # leading run, so this line is relayed text and nothing more.
    forged) printf '%s' $'1 outdated — run `kendex refresh` to update:\nsession-drift-check: exit=99' ;;
    *) printf 'unknown fake output word: %s\n' "$1" >&2; exit 1 ;;
  esac
}

# Run the hook with a SessionStart payload on stdin (source from $HOOK_SOURCE,
# default startup). Extra VAR=value args are passed through the environment.
# Captures stdout in $out and exit in $rc.
run_hook() {
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
    PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" "$@" \
    bash "$HOOK" <<<"{\"session_id\":\"s\",\"hook_event_name\":\"SessionStart\",\"source\":\"${HOOK_SOURCE:-startup}\"}" \
    2>/dev/null
  rc=$?
  set -e
}

# stdout lands in the file the shared reader reads, so every row is judged on
# the same bytes and by the same reader.
capture() {
  out="$(run_hook "$@"; echo "rc=$rc")"
  rc="${out##*rc=}"
  out="${out%rc=*}"
  printf '%s' "$out" >"$TMP_ROOT/stdout"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# The shared reader, for where the keyed lines are. This suite reads stdout
# rather than a stderr file, so it names the file and the hook at each call.
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The shared reader answers where the keyed lines are — the leading run, so a
# keyed line further down does not count — and this renders the one value that
# moves between runs. Reading them out of the whole output, anywhere they
# stood, is what let this suite pass without enforcing the contract at all.
keyed_of() { # -> the leading keyed values of the last run, line numbers hidden
  local block
  block="$(keyed_block "$TMP_ROOT/stdout" session-drift-check)"
  printf '%s' "$(printf '%s' "$block" | sed 's/line=[0-9][0-9]*/line=<n>/')"
}
# What the hook relays under those lines is written for a model, so a row says
# how much of it reached stdout, never what it said. A count rather than a
# truthiness bit: an instruction with no keyed line of its own — ask the user
# before running a workflow, never hand-edit a rendered tree — is pinned by
# nothing else, and `present` stays true while every one of them is deleted.
relayed_text() { # -> the last run's non-blank lines other than the keyed ones
  sed -e '/^session-drift-check: /d' -e '/^[[:space:]]*$/d' "$TMP_ROOT/stdout"
}
relayed_of() { # -> how many non-blank lines other than the keyed ones were written
  local rest
  rest="$(relayed_text)"
  if [ -z "$rest" ]; then
    printf '0'
  else
    printf '%s' "$(printf '%s\n' "$rest" | wc -l | tr -d '[:space:]')"
  fi
}

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

calls() {
  local text
  text="$(paste -s -d ';' "$ARGS_LOG")"
  [[ "$text" != "" ]] && printf '%s' "$text" || printf -- '-'
}

# One mapping row: the hook's exit, the fake's argv and the whole stdout,
# trailing newlines kept.
run_row() { # fake-rc fake-out-word
  local rc=0 fake text
  # A word fake_out refuses must end the run, not test the empty-output arm:
  # the substitution swallows its exit, so the status is carried out by hand.
  fake="$(fake_out "$2")" || { printf 'the fake output word could not be mapped: %s\n' "$2" >&2; return 1; }
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
    PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC="$1" FAKE_OUT="$fake" \
    bash "$HOOK" <<<'{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || rc=$?
  # The keyed lines only: the context text under them is for a model, and a
  # row that pinned it would pin prose. stderr is a channel this hook does not
  # write, so a row says it is empty rather than reading it.
  text="$(keyed_of)"
  [[ "$text" != "" ]] || text='-'
  printf 'rc=%s calls=%s keyed=%s stderr=%s' "$rc" "$(calls)" "$text" \
    "$([ -s "$TMP_ROOT/stderr" ] && printf 'wrote' || printf 'empty')"
}

run_table() {
  local title="$1" rows="$2" label fake_rc fake_word stdout fake_text want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label fake_rc fake_word stdout <<<"$row"
    for field in "$label" "$fake_rc" "$fake_word" "$stdout"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # The word is mapped once, here, where a refusal ends the run: inside the
    # substitutions below its exit would be swallowed and the row would test
    # the empty-output arm instead.
    fake_text="$(fake_out "$fake_word")" || { printf 'a row names a fake output word fake_out refuses: %s\n' "$row" >&2; exit 1; }
    got="$(run_row "$fake_rc" "$fake_word")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${HOOKS_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=0 calls=check --quiet keyed=$stdout stderr=empty" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

# The empty-output arm belongs to exit 2 alone: a signal or a timeout kills
# the check before it says anything, and the exit 3 row keeps the colon over
# a blank line, the same text the embedded and Pi hooks print. Each row's first
# line is the key and value: which arm the exit code chose.
run_table "the kendex check exit to the arm it chooses" "\
a clean install says nothing|0|-|-
drift found|1|report|drift=found
not yet evaluated is drift, never a failure|1|unevaluated|drift=found
a report that spells a keyed line of its own is relayed, not read as one|1|forged|drift=found
could not check: incomplete, and the code it chose from|2|could-not-check|check=incomplete;exit=2
an error: inside a report line is still a completed report|2|error-inside-a-line|check=incomplete;exit=2
exit 2 with no output is a failure to run, not an empty partial report|2|-|check=could-not-run;exit=2
an Error: line at exit 2 is a failure to run|2|Error-line|check=could-not-run;exit=2
a usage error: at exit 2 is a failure to run, never partial|2|usage-error|check=could-not-run;exit=2
exit 3 is a failure to run, and the code is the value|3|fatal|check=could-not-run;exit=3
exit 3 with no output chooses the same arm|3|-|check=could-not-run;exit=3
"
run_row 1 unevaluated >/dev/null
assert_eq "$(relayed_text)" "$(fake_out unevaluated)" "the final action line is relayed byte for byte"

echo "session-drift-check: unreadable stdin"
# Strict mode must not let a failed payload read abort the session start.
# A `cat` stub that fails stands in for a harness that hands the hook no
# readable stdin.
FAILCAT_BIN="$TMP_ROOT/failcat"
mkdir -p "$FAILCAT_BIN"
printf '#!/usr/bin/env bash\necho "cat: -: Input/output error" >&2\nexit 1\n' >"$FAILCAT_BIN/cat"
chmod +x "$FAILCAT_BIN/cat"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
  PATH="$FAILCAT_BIN:$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=1 FAKE_OUT="$REPORT" bash "$HOOK" </dev/null 2>"$TMP_ROOT/stderr")"
rc=$?
set -e
printf '%s' "$out" >"$TMP_ROOT/stdout"
assert_eq "$rc" 0 "exits 0 when the payload read fails"
# The read failure is reported under its own key on stdout, with cat's words
# below it, and nothing reaches the stream this hook does not write.
assert_eq "keyed=$(keyed_of) relayed=$(relayed_of)" "keyed=payload=unreadable relayed=$((REPORT_LINES + 2))" \
  "a failed payload read is reported under its own key"
assert_contains "$out" 'cat: -: Input/output error' "carrying the reader's own words"
assert_contains "$out" "$REPORT" "and the report still follows it"
assert_eq "$([ -s "$TMP_ROOT/stderr" ] && printf 'wrote' || printf 'empty')" empty \
  "and nothing reaches stderr, a channel this hook does not write"

echo "session-drift-check: environment switches"
capture FAKE_RC=1 FAKE_OUT="$REPORT" KENDEX_DRIFT_HOOK=off
assert_eq "$out" "" "KENDEX_DRIFT_HOOK=off silences the hook"
assert_eq "$(cat "$ARGS_LOG")" "" "KENDEX_DRIFT_HOOK=off never invokes kendex"

echo "session-drift-check: project directory"
mkdir -p "$TMP_ROOT/proj"
capture FAKE_RC=0 CLAUDE_PROJECT_DIR="$TMP_ROOT/proj"
assert_eq "$(cd "$TMP_ROOT/proj" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" "runs kendex inside CLAUDE_PROJECT_DIR"

echo "session-drift-check: inside a linked worktree"
# The fix a session in a linked worktree is shown is kendex's own: the project
# a project-scope write lands in is named there with `--project-path`, because
# a session running the block-worktree-refresh hook is refused that write with
# no target. This hook neither composes that line nor rewrites it, so what is
# pinned here is the pair that makes it right where it is read: the check is
# asked about the worktree, and what it answered reaches stdout as the bytes
# it wrote.
#
# The git setup documents that scenario. It drives no branch of this hook,
# which reads nothing about worktree-ness, so no assertion below depends on
# it. It runs under a fixture HOME, so the person's own git config decides
# nothing here.
GIT_HOME="$TMP_ROOT/git-home"
mkdir -p "$GIT_HOME"
printf '[user]\n\temail = t@t\n\tname = t\n[init]\n\tdefaultBranch = main\n' >"$GIT_HOME/.gitconfig"
fixture_git() { env HOME="$GIT_HOME" git "$@"; }
WT_MAIN="$TMP_ROOT/wt-main"
WT_LINKED="$TMP_ROOT/wt-linked"
fixture_git init -q "$WT_MAIN"
fixture_git -C "$WT_MAIN" commit -q --allow-empty -m init
fixture_git -C "$WT_MAIN" worktree add -q "$WT_LINKED" -b lane
WT_REPORT="stale:
  orch (skill) — fix: kendex apply --project-path '$WT_LINKED'"
capture FAKE_RC=1 FAKE_OUT="$WT_REPORT" CLAUDE_PROJECT_DIR="$WT_LINKED"
assert_eq "$(cd "$WT_LINKED" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" \
  "asks the check about the worktree, not the checkout it was added from"
assert_eq "keyed=$(keyed_of) relayed=$(relayed_text)" "keyed=drift=found relayed=$WT_REPORT" \
  "and relays the named-target fix byte for byte"

echo "session-drift-check: start reasons"
for src in resume compact; do
  HOOK_SOURCE=$src capture FAKE_RC=1 FAKE_OUT="$REPORT"
  assert_eq "$rc" 0 "source=$src exits 0"
  assert_eq "$out" "" "source=$src prints nothing"
  assert_eq "$(cat "$ARGS_LOG")" "" "source=$src never invokes kendex"
done
for src in startup clear; do
  HOOK_SOURCE=$src capture FAKE_RC=1 FAKE_OUT="$REPORT"
  assert_eq "keyed=$(keyed_of) relayed=$(relayed_of)" "keyed=drift=found relayed=$REPORT_LINES" \
    "source=$src relays the report"
done

echo "session-drift-check: the start reason is the payload's own top-level key"
# The payload is JSON, and only the TOP-LEVEL `source` is the start reason. A
# scan for the text takes whichever match comes first, so a nested object
# carrying the same key decided the hook's behaviour — silencing a fresh
# session's report, or replaying one on a resume.
run_raw() {
  local payload="$1"
  shift
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
    PATH="$1:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC=1 FAKE_OUT="$REPORT" bash "$HOOK" <<<"$payload" 2>/dev/null)"
  rc=$?
  set -e
  printf '%s' "$out" >"$TMP_ROOT/stdout"
}

run_raw '{"tool_input":{"source":"resume"},"source":"startup"}' "$BIN_DIR"
assert_eq "keyed=$(keyed_of) relayed=$(relayed_of)" "keyed=drift=found relayed=$REPORT_LINES" \
  "a nested source does not silence a fresh start"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "…and the check still runs"

run_raw '{"tool_input":{"source":"startup"},"source":"resume"}' "$BIN_DIR"
assert_eq "$out" "" "a nested source does not make a resume report"
assert_eq "$(cat "$ARGS_LOG")" "" "…and the check never runs on a resume"

# A string value carrying the same characters is text, not the key.
run_raw '{"cwd":"/tmp/\"source\": \"resume\"","source":"startup"}' "$BIN_DIR"
assert_eq "keyed=$(keyed_of) relayed=$(relayed_of)" "keyed=drift=found relayed=$REPORT_LINES" \
  "a quoted source inside another value is not the start reason"

echo "session-drift-check: a payload it cannot read"
# jq is the only reader. An unread payload cannot be shown to be a fresh start,
# so the report is skipped with the reason rather than repeated on every
# compact — and a session still starts either way.
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat command printf grep sed head env pwd; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOJQ_BIN/$tool"
done
ln -sf "$BIN_DIR/kendex" "$NOJQ_BIN/kendex"
# PATH exactly, not prefixed: run_raw appends the caller's own PATH, which
# leaves jq reachable and makes a no-jq claim untestable.
run_exact_path() { # payload PATH
  : >"$ARGS_LOG"
  : >"$CWD_LOG"
  set +e
  out="$(env -i HOME="$HOME" PATH="$2" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
    FAKE_RC=1 FAKE_OUT="$REPORT" "$(command -v bash)" "$HOOK" <<<"$1" 2>/dev/null)"
  rc=$?
  set -e
  printf '%s' "$out" >"$TMP_ROOT/stdout"
}
run_exact_path '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' "$NOJQ_BIN"
assert_eq "$rc" 0 "without jq the session still starts"
assert_eq "keyed=$(keyed_of)" 'keyed=missing-tools=jq' \
  "without jq the skip names jq rather than reading as a clean install"
assert_eq "$(cat "$ARGS_LOG")" "" "without jq the check never runs"

# A payload jq REFUSES takes the same lane: the failure exit is not "no such
# key", so it must not read as a fresh start.
run_raw '{"source":"resume"' "$BIN_DIR"
assert_eq "$rc" 0 "a payload jq cannot parse still exits 0"
assert_eq "keyed=$(keyed_of)" 'keyed=payload=invalid-json' \
  "…and the skip names the payload rather than reading as a fresh start"
assert_eq "$(cat "$ARGS_LOG")" "" "and the check never runs for it"

echo "session-drift-check: unusable project directory"
capture FAKE_RC=1 FAKE_OUT="$REPORT" CLAUDE_PROJECT_DIR="$TMP_ROOT/does-not-exist"
assert_eq "$rc" 0 "missing project dir exits 0"
assert_eq "keyed=$(keyed_of)" "keyed=path=$TMP_ROOT/does-not-exist" \
  "the unusable project directory is the value"
# The same probe, run here: the row asserts the hook replayed what cd actually
# said rather than a wording pinned by hand.
cd_said="$( (cd -- "$TMP_ROOT/does-not-exist") 2>&1 || true)"
assert_contains "$out" "${cd_said##*: }" "with cd's own words under it"
assert_eq "$(cat "$ARGS_LOG")" "" "missing project dir never invokes kendex"

echo "session-drift-check: dash-leading project directory"
# A relative project dir starting with `-` is a path, not a `cd` option.
mkdir -p "$TMP_ROOT/-dash"
: >"$ARGS_LOG"
: >"$CWD_LOG"
set +e
out="$(cd "$TMP_ROOT" && env -u KENDEX_DRIFT_HOOK \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  CLAUDE_PROJECT_DIR=-dash FAKE_RC=0 bash "$HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
printf '%s' "$out" >"$TMP_ROOT/stdout"
assert_eq "$rc" 0 "dash-leading project dir exits 0"
assert_eq "$out" "" "dash-leading project dir is entered, not parsed as an option"
assert_eq "$(cat "$ARGS_LOG")" "check --quiet" "dash-leading project dir still runs the check"
assert_eq "$(cd "$TMP_ROOT/-dash" && pwd -P)" "$(cd "$(cat "$CWD_LOG")" && pwd -P)" \
  "runs kendex inside the dash-leading project dir"

echo "session-drift-check: unexpected failure"
# Inject an unguarded failure into a COPY of the shipped hook. The strict-mode
# abort it triggers must still reach the agent as a diagnostic — a session that
# printed nothing would read as a clean install.
BROKEN_HOOK="$TMP_ROOT/broken-hook.sh"
awk '{ print } /^INPUT=/ { print "false" }' "$HOOK" >"$BROKEN_HOOK"
set +e
out="$(env -u CLAUDE_PROJECT_DIR -u KENDEX_DRIFT_HOOK \
  PATH="$BIN_DIR:$PATH" FAKE_ARGS_LOG="$ARGS_LOG" FAKE_CWD_LOG="$CWD_LOG" \
  FAKE_RC=0 bash "$BROKEN_HOOK" <<<'{"source":"startup"}' 2>/dev/null)"
rc=$?
set -e
printf '%s' "$out" >"$TMP_ROOT/stdout"
assert_eq "$rc" 0 "an unexpected failure still exits 0"
assert_eq "keyed=$(keyed_of)" 'keyed=exit=1;line=<n>' \
  "an unexpected failure reports the status it left and the line it reached, each its own key"

echo "session-drift-check: no kendex on PATH"
# Without the command nothing in the project can be checked, refreshed or
# removed, and the notice has to carry enough for the session to decide what
# to do: how many packages the project declares, the route that installs the
# command on this platform, and the generated trees that stay generated
# either way. All three are values on keyed lines and the rows pin them. The
# instructions under them — ask the user before running a workflow, never
# hand-edit a rendered tree — are written for a model, so a row says they
# reached stdout and never what they said, the same rule the mapping rows
# follow.
#
# The whole notice is written from shell builtins: the only commands reachable
# here are the two the hook needs to get this far, `cat` for the payload and
# `jq` to read it. A row that reached for a third would report a missing tool
# as a missing manifest, so the world is what pins that it reaches for none.
NOKENDEX_BIN="$TMP_ROOT/nokendex"
mkdir -p "$NOKENDEX_BIN"
for tool in cat jq; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOKENDEX_BIN/$tool"
done

# The projects the rows point the hook at. `declares` is an ordinary project,
# carrying one declaration of every counted kind beside tables that must not
# be counted: a name that begins with a counted kind, and a hook's own `env`
# sub-table. `catalog` is a source catalog: it publishes its kendex.toml and
# keeps its install state in the sibling file, so none of the three tables in
# the catalog file may reach the count — it holds three where the sibling
# holds two, so a row reading the wrong file reports the wrong number.
# `catalog-tight` is the same catalog with the spaceless spelling of the flag.
# `catalog-bare` is a catalog before anything is installed locally: its
# kendex.toml was read and the sibling holding install state is not there yet,
# so the file the notice names is the sibling, not the file it read.
# `bundles-only` declares one bundle and nothing else — `kendex add <bundle>`
# writes that table alone and leaves the members in the lock, so a project
# like it is not a project that declares nothing. `nested-flag` spells the
# catalog flag inside a table, where it belongs to that table and is not the
# root key a catalog sets. `bare` has no manifest at all.
PROJ_DECLARES="$TMP_ROOT/proj-declares"
PROJ_CATALOG="$TMP_ROOT/proj-catalog"
PROJ_CATALOG_TIGHT="$TMP_ROOT/proj-catalog-tight"
PROJ_BUNDLES="$TMP_ROOT/proj-bundles"
PROJ_NESTED_FLAG="$TMP_ROOT/proj-nested-flag"
PROJ_CATALOG_BARE="$TMP_ROOT/proj-catalog-bare"
PROJ_BARE="$TMP_ROOT/proj-bare"
PROJ_SEALED="$TMP_ROOT/proj-sealed"
mkdir -p "$PROJ_DECLARES" "$PROJ_CATALOG" "$PROJ_CATALOG_TIGHT" "$PROJ_BUNDLES" \
  "$PROJ_NESTED_FLAG" "$PROJ_CATALOG_BARE" "$PROJ_BARE" "$PROJ_SEALED"
cat >"$PROJ_DECLARES/kendex.toml" <<'EOF'
schema = 6

[sources.kendex]
repo = "vanillagreencom/kendex"

[agents.generalist]
source = "kendex"

[skills.orch]
source = "kendex"

[hooks.session-drift-check]
source = "kendex"

[hooks.session-drift-check.env]
KENDEX_DRIFT_HOOK = "on"

[commands.ship]
source = "kendex"

[mcp-servers.github]
source = "kendex"

[plugins."fmt@market"]
enabled = true

[bundles.workflow]
source = "kendex"

[agent-frontmatter.claude.generalist]
model = "opus"

[agent-skills]
generalist = ["orch"]
EOF
cat >"$PROJ_CATALOG/kendex.toml" <<'EOF'
is_source_catalog = true

[bundles.workflow]
skills = ["orch"]

[agents.published-by-the-catalog]
source = "kendex"

[skills.also-published-by-the-catalog]
source = "kendex"
EOF
cat >"$PROJ_CATALOG/kendex-local.toml" <<'EOF'
schema = 6

[skills.orch]
source = "."

[pi-extensions.pi-web-tools]
source = "."
EOF
# The same catalog, written without the spaces around the flag's `=`. Both
# spellings are TOML and the hook accepts both, so both are driven.
{
  echo 'is_source_catalog=true'
  tail -n +2 "$PROJ_CATALOG/kendex.toml"
} >"$PROJ_CATALOG_TIGHT/kendex.toml"
cp "$PROJ_CATALOG/kendex-local.toml" "$PROJ_CATALOG_TIGHT/kendex-local.toml"
# The same published file with no sibling beside it.
cp "$PROJ_CATALOG/kendex.toml" "$PROJ_CATALOG_BARE/kendex.toml"
cat >"$PROJ_BUNDLES/kendex.toml" <<'EOF'
schema = 6

[sources.kendex]
repo = "vanillagreencom/kendex"

[bundles.workflow]
source = "kendex"
EOF
cat >"$PROJ_NESTED_FLAG/kendex.toml" <<'EOF'
schema = 6

[sources.kendex]
repo = "vanillagreencom/kendex"
is_source_catalog = true

[skills.orch]
source = "kendex"
EOF
cp "$PROJ_DECLARES/kendex.toml" "$PROJ_SEALED/kendex.toml"
chmod 000 "$PROJ_SEALED/kendex.toml"

# One row's run: no kendex on PATH, pointed at a project, under a stated
# OSTYPE. bash keeps an OSTYPE the environment already carries, which is what
# lets one machine drive both install routes.
run_nokendex() { # project ostype
  set +e
  out="$(env -i HOME="$HOME" PATH="$NOKENDEX_BIN" OSTYPE="$2" CLAUDE_PROJECT_DIR="$1" \
    "$(command -v bash)" "$HOOK" <<<'{}' 2>"$TMP_ROOT/stderr")"
  rc=$?
  set -e
  printf '%s' "$out" >"$TMP_ROOT/stdout"
}

# The generated trees the notice names, spelled out here rather than read off
# the hook: an expectation derived from the list under test moves with it, and
# a row that moves pins nothing. What holds that list to MARKER_DIRS is the
# lane at the end of this file; this is what an agent actually receives.
NEVER_EDIT_WANT=".agents/,.claude/,.codex/,.pi/,.gemini/,.opencode/,.cursor/"
# How many lines of guidance the notice writes under its keyed lines: the
# skip sentence, what the project has riding on kendex, the install route,
# ask the user first, never hand-edit a rendered file, and the settings file a
# hand edit survives. None of those has a keyed line, so this count is the
# only thing that reddens when one of them is deleted.
GUIDANCE_LINES=6

CURL_ROUTE="curl -fsSL https://kendex.ai/install.sh | sh"
DOWNLOAD_ROUTE="https://kendex.ai/download"

# A row is `label|project|ostype|keyed`. `keyed` stands last, so the install
# route may hold the pipe that installs the command. `manifest=` carries what
# became of the read and `manifest-file=` which file it was, which is what the
# count means: both states that yield no count report `packages=unknown`, and
# only those values tell a read failure from a project that has no manifest of
# its own, and say which file a session should be looking for. A catalog's is
# the sibling, so the rows render the name per row rather than fixing one.
PLAIN_MANIFEST="kendex.toml"
CATALOG_MANIFEST="kendex-local.toml"
NOKENDEX_ROWS="\
an ordinary project counts one declaration per counted kind in its kendex.toml|$PROJ_DECLARES|linux-gnu|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=7;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
a source catalog counts the sibling holding its install state, not what it publishes|$PROJ_CATALOG|linux-gnu|missing-tools=kendex;manifest=read;manifest-file=$CATALOG_MANIFEST;packages=2;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
the catalog flag is read without spaces around its equals too|$PROJ_CATALOG_TIGHT|linux-gnu|missing-tools=kendex;manifest=read;manifest-file=$CATALOG_MANIFEST;packages=2;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
a catalog whose sibling does not exist yet has none of its own, not a read failure|$PROJ_CATALOG_BARE|linux-gnu|missing-tools=kendex;manifest=absent;manifest-file=$CATALOG_MANIFEST;packages=unknown;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
a project holding only a bundle declares that bundle, never nothing|$PROJ_BUNDLES|linux-gnu|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=1;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
the catalog flag is the root key, so one inside a table leaves the file alone|$PROJ_NESTED_FLAG|linux-gnu|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=1;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
a project with no manifest has no count, never a zero|$PROJ_BARE|linux-gnu|missing-tools=kendex;manifest=absent;manifest-file=$PLAIN_MANIFEST;packages=unknown;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT
an MSYS shell is sent to the download page, not to a pipe into sh|$PROJ_DECLARES|msys|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=7;install=$DOWNLOAD_ROUTE;never-edit=$NEVER_EDIT_WANT
a Cygwin shell takes the same route|$PROJ_DECLARES|cygwin|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=7;install=$DOWNLOAD_ROUTE;never-edit=$NEVER_EDIT_WANT
a win32 shell takes the same route|$PROJ_DECLARES|win32|missing-tools=kendex;manifest=read;manifest-file=$PLAIN_MANIFEST;packages=7;install=$DOWNLOAD_ROUTE;never-edit=$NEVER_EDIT_WANT
"
# A manifest present but unreadable is a read failure, and a project that has
# none is not: both report packages=unknown, and manifest= is what tells them
# apart. Root reads a mode-000 file, so the row runs where the mode means
# something.
if [ "$(id -u)" != 0 ]; then
  NOKENDEX_ROWS="$NOKENDEX_ROWS
a manifest that cannot be read is a read failure, not a project without one|$PROJ_SEALED|linux-gnu|missing-tools=kendex;manifest=unreadable;manifest-file=$PLAIN_MANIFEST;packages=unknown;install=$CURL_ROUTE;never-edit=$NEVER_EDIT_WANT"
else
  echo "  skip  a manifest that cannot be read is a read failure (running as root)"
fi

nokendex_before=$((PASS + FAIL))
while IFS= read -r row; do
  [[ "$row" != "" ]] || continue
  IFS='|' read -r label project ostype keyed <<<"$row"
  for field in "$label" "$project" "$ostype" "$keyed"; do
    [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  run_nokendex "$project" "$ostype"
  assert_eq \
    "rc=$rc keyed=$(keyed_of) guidance=$(relayed_of) stderr=$([ -s "$TMP_ROOT/stderr" ] && printf 'wrote' || printf 'empty')" \
    "rc=0 keyed=$keyed guidance=$GUIDANCE_LINES stderr=empty" "$label"
done <<<"$NOKENDEX_ROWS"
[[ "$((PASS + FAIL))" -gt "$nokendex_before" ]] || { echo "no missing-kendex row was asserted" >&2; exit 2; }

# The keyed manifest= value pins which state manifest_facts settled on. What
# the case under it does with that state is a separate claim, and this is what
# holds it: one sentence per state, none standing in for another. A session
# whose manifest exists but cannot be opened must not be told the file is not
# there, or an agent writes a new manifest instead of fixing a permission.
# Root reads a mode-000 file, so the unreadable run needs a non-root mode to
# mean anything. The wording stays unpinned; only that the three differ.
if [ "$(id -u)" != 0 ]; then
  run_nokendex "$PROJ_BARE" linux-gnu
  said_absent="$(relayed_text)"
  run_nokendex "$PROJ_SEALED" linux-gnu
  said_unreadable="$(relayed_text)"
  run_nokendex "$PROJ_DECLARES" linux-gnu
  said_read="$(relayed_text)"
  assert_eq "$([ "$said_absent" != "$said_unreadable" ] &&
    [ "$said_absent" != "$said_read" ] &&
    [ "$said_unreadable" != "$said_read" ] && printf 'differ' || printf 'same')" \
    differ "each manifest state writes its own sentence, none standing in for another"
else
  echo "  skip  each manifest state writes its own sentence (running as root)"
fi
chmod 700 "$PROJ_SEALED/kendex.toml"

echo "session-drift-check: the enumerations the hook copies out of Rust"
# The hook counts declarations and names generated trees because kendex, which
# owns both vocabularies, is what is missing. Each list in the hook is
# therefore a hand copy, and nothing in the hook holds it to its owner. These
# two lanes read the owners out of their own files and hold the copies to
# them, so a kind or a directory added in Rust reddens here.
#
# A source file that cannot be read ends the run. This suite renders nowhere
# (hooks/AGENTS.md) and runs only from this repository, so there is no tree in
# which it legitimately runs without crates/; the one event that removes one
# of these files, a refactor of its module, is the event most likely to move
# the vocabulary the lane polices. A skip here would be green in CI while the
# copy drifted.
CORE_SRC="$(cd "$TEST_DIR/../.." && pwd)/crates/core/src"
rust_list() { # FILE CONST -> the quoted entries of a `const NAME...[ ... ];`
  local file="$1" const="$2" entries
  [ -r "$file" ] || { printf 'the Rust source this suite reads could not be read at %s\n' "$file" >&2; exit 2; }
  entries="$(sed -n "/^const $const/,/^];/p" "$file" |
    sed -n 's/^[[:space:]]*"\([^"]*\)",$/\1/p')"
  # The floor: an extractor that matched nothing would agree with every copy,
  # so an empty read is this lane being broken, not Rust declaring no entries.
  [ -n "$entries" ] || { printf 'no %s entry could be read out of %s\n' "$const" "$file" >&2; exit 2; }
  printf '%s\n' "$entries"
}
sorted_words() { # -> its stdin, one word per line, sorted into one line
  tr ' ,' '\n\n' | sed '/^[[:space:]]*$/d' | sort | tr '\n' ' '
}

# The counted kinds are ITEM_TABLES plus `plugins`, which that list leaves out
# only because a plugin carries an enabled flag instead of a source.
kinds_want="$( (rust_list "$CORE_SRC/manifest/validate/items.rs" ITEM_TABLES; echo plugins) | sorted_words)"
kinds_got="$(sed -n 's/^COUNTED_KINDS="\(.*\)"$/\1/p' "$HOOK" | sorted_words)"
assert_eq "$kinds_got" "$kinds_want" \
  "the hook counts ITEM_TABLES plus plugins, and nothing else"

# The never-edit trees are MARKER_DIRS, spelled as directories.
dirs_want="$(rust_list "$CORE_SRC/discover.rs" MARKER_DIRS | sed 's|$|/|' | sorted_words)"
dirs_got="$(sed -n 's/^NEVER_EDIT="\(.*\)"$/\1/p' "$HOOK" | sorted_words)"
assert_eq "$dirs_got" "$dirs_want" \
  "the hook names every MARKER_DIRS tree, and no other"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
