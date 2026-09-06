#!/usr/bin/env bash
# The check's OWN MACHINERY, as opposed to the measurement gates it runs: the
# three channels a gate answers on (exit status, stdout, stderr), what happens
# when jq or mktemp cannot run at all, and the rule that no mode exits without
# a parseable result. Split from review_artifact_check_measurement.sh, which
# holds whatever the gates measure.
#
# One table: each row stages one artifact body in a fresh worktree, runs the
# check under one jq (real, or a shim that breaks one thing) in one mode
# (--file, glob, --wait), and asserts once. A row's `expect` names the result
# fields it pins and `observe` reads exactly those; a missing key reads ABSENT.
# The second table drives the last-resort emitter directly with the strings
# JSON cannot carry raw.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REAL_JQ="$(command -v jq)"

# body NAME — the artifact bodies the rows stage, by name. Every body passes
# every gate under real jq except `zeroed` (the zero-sample gate refuses it)
# and `noreview` (the no-review predicate refuses it).
body() {
  case "$1" in
    measured) printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' ;;
    zeroed) printf '{"agent":"reviewer-test","verdict":"pass","summary":"validated: mutation: killed 0/0; stability: 10/10 at 16 threads"}' ;;
    noreview) printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' ;;
    clean) printf '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement in scope","blockers":[],"suggestions":[],"qa_metadata":{}}' ;;
    *) echo "body: unknown name $1" >&2; exit 1 ;;
  esac
}

# --- the jq shims ------------------------------------------------------------
# Each breaks ONE thing and hands everything else to the real jq, so a row's
# verdict under a shim is the shim's doing and a neighbouring row under real
# jq is its must-fail control.
shim() {
  local dir="$TMP_ROOT/jqshim-$1"
  mkdir -p "$dir"
  case "$1" in
    # a torn read of a non-atomically written artifact, in the zero-sample gate
    torn_zs) printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:zero-sample"*) echo "jq: error (at file): simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$dir/jq" ;;
    # the same, in a PREDICATE gate, where exit 1 means "no" and >=2 "could not answer"
    torn_pred) printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:no-review"*) echo "jq: error: simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$dir/jq" ;;
    # the same, in the .verdict read itself: jq -e is that read's spelling
    torn_verdict) printf '#!/usr/bin/env bash\nif [ "$1" = "-e" ]; then echo "jq: error: simulated torn read" >&2; exit 5; fi\nexec %s "$@"\n' "$REAL_JQ" > "$dir/jq" ;;
    # a diagnostic on stderr that leaves the exit status alone
    chatty) printf '#!/usr/bin/env bash\necho "chatty jq: a diagnostic that changes no exit status" >&2\nexec %s "$@"\n' "$REAL_JQ" > "$dir/jq" ;;
    # fails only emit's own `jq -n`: every gate answers, the artifact passes,
    # and the ONLY thing that fails is saying so
    noemit) printf '#!/usr/bin/env bash\nif [ "$1" = "-n" ]; then exit 4; fi\nexec %s "$@"\n' "$REAL_JQ" > "$dir/jq" ;;
    *) echo "shim: unknown name $1" >&2; exit 1 ;;
  esac
  chmod +x "$dir/jq"
}
for s in torn_zs torn_pred torn_verdict chatty noemit; do shim "$s"; done

# A PATH with everything the check needs except jq.
NOJQ_BIN="$TMP_ROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
for b in bash env dirname mktemp rm tr stat date sleep ls cat sed grep basename touch mkdir printf; do
  bp="$(command -v "$b" 2>/dev/null)" && ln -sf "$bp" "$NOJQ_BIN/$b"
done
if [[ -n "$(PATH="$NOJQ_BIN" command -v jq 2>/dev/null || printf '')" ]]; then
  echo "the no-jq fixture PATH still resolves jq; the no-jq rows would pin nothing" >&2
  exit 1
fi

# --- harness -----------------------------------------------------------------

RUN_SEQ=0
fresh_run() {
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  WT="$RUN/wt"
  mkdir -p "$WT/tmp"
  F="$WT/tmp/review-r-20260101-000001.json"
  ERR="$RUN/stderr"
}

# run_check JQ MODE — OUT is the JSON, RC the exit. JQ names the environment
# the check runs under; MODE the invocation over the staged artifact.
run_check() {
  local args
  case "$2" in
    file) args=(--file "$F") ;;
    glob) args=("$WT" r 0) ;;
    wait) args=("$WT" r 0 --wait 3 --interval 1) ;;
    *) echo "run_check: unknown mode $2" >&2; exit 1 ;;
  esac
  set +e
  case "$1" in
    real) OUT=$("$CHECK" "${args[@]}" 2>"$ERR") ;;
    torn_zs|torn_pred|torn_verdict|chatty|noemit) OUT=$(PATH="$TMP_ROOT/jqshim-$1:$PATH" "$CHECK" "${args[@]}" 2>"$ERR") ;;
    # JQ_COLORS=zz is a documented jq variable that prints "Failed to set
    # $JQ_COLORS" and exits 0: the real spelling of the chatty shim
    colors) OUT=$(JQ_COLORS=zz "$CHECK" "${args[@]}" 2>"$ERR") ;;
    none) OUT=$(PATH="$NOJQ_BIN" "$CHECK" "${args[@]}" 2>"$ERR") ;;
    notmp) OUT=$(TMPDIR=/nonexistent-dir-for-review-artifact-check "$CHECK" "${args[@]}" 2>"$ERR") ;;
    tmpok) OUT=$(TMPDIR="$TMP_ROOT" "$CHECK" "${args[@]}" 2>"$ERR") ;;
    *) echo "run_check: unknown jq $1" >&2; exit 1 ;;
  esac
  RC=$?
  set -e
}

json() { jq -r "$@" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order. Plain names are JSON result fields, their spaces printed
# as `+`; a key the result does not carry reads ABSENT, and any field of an
# output that is not JSON reads UNPARSEABLE. `+` reads as a space in a needle
# too, so a literal plus cannot be pinned; no field carries one.
#   rc               exit status
#   parses           whether stdout is one JSON value
#   detail~<text>    whether the detail names <text>
#   cntrl            the number of control characters in the detail
observe() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      parses) value="$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo true || echo false)" ;;
      detail~*) needle="${name#detail~}"; value="$(json '.detail // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      # counted with grep, not a jq regex: a backslash-u control range inside a jq
      # string is a literal character set and matches the "u" in "null"
      cntrl) value="$(json '.detail // ""' | LC_ALL=C grep -o '[[:cntrl:]]' | wc -l | tr -d ' ')" ;;
      *) value="$(json "if has(\"$name\") then .$name else \"ABSENT\" end")"; value="${value// /+}" ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# check_table ROW... — `label^body^jq^mode^expect`, `^` because bodies carry
# `|`; one fresh worktree, one run, one assertion per row.
check_table() {
  local row label name which mode expect
  for row in "$@"; do
    IFS='^' read -r label name which mode expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'check_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    fresh_run
    body "$name" > "$F"
    run_check "$which" "$mode"
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

# emit_table ROW... — `label^detail^expect`: emit_unavailable is run in a child
# shell over the detail, `printf %%b` expanding its `\n`, `\t`, `\r` and
# `\177` escapes into the raw bytes jq's and mktemp's diagnostics carry.
# Sourcing the lib here would install its EXIT trap over this suite's.
emit_table() {
  local row label detail expect
  for row in "$@"; do
    IFS='^' read -r label detail expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'emit_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    fresh_run
    set +e
    OUT=$(bash -c 'source "$1/skills/orch/scripts/lib/review-artifact-gates.sh"; emit_unavailable "$2"' _ "$REPO_ROOT" "$(printf '%b' "$detail")" 2>"$ERR")
    RC=$?
    set -e
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== a gate that could not run is never silence, and never the answer channel ==="
# Both gate helpers would signal "no problem" with an empty string, so a jq
# failure was indistinguishable from a clean artifact; --wait's capture of
# glob_check suspended errexit for the whole body and turned it into ok=true.
# The detail carries jq's REAL status (2 is a usage or system error, 5 the
# program failing on the input), not a wrapper sentinel. The predicate side
# had the same collapse: exit 1 ("no") and exit >=2 ("could not answer") both
# read as "no problem", letting the artifact fall through to a later gate. A
# gate's stderr, on the other hand, is never a finding: gate_filter once merged
# it into stdout, so any diagnostic that left the exit status alone became a
# rejection with a wrong cause AND was echoed back as a fabricated declaration.
check_table \
  "--file: a torn read in a gate exits 1 as invalid, carrying jq's diagnostic and real status^zeroed^torn_zs^file^rc=1 ok=false reason=invalid detail~simulated+torn+read=true detail~jq+exited+5=true" \
  "--wait: the same torn read is not returned as ok=true^zeroed^torn_zs^wait^rc=1 ok=false reason=invalid" \
  "the shim breaks only the zero-sample gate: an earlier gate still answers under it^noreview^torn_zs^file^reason=no_review" \
  "control: with real jq --wait reports the real rejection^zeroed^real^wait^rc=1 reason=zero_sample" \
  "control: with real jq the clean artifact is valid^measured^real^file^rc=0 reason=valid" \
  "--file: a torn read in a predicate gate is invalid, not a later gate's verdict^noreview^torn_pred^file^rc=1 reason=invalid detail~simulated+torn+read=true" \
  "control: with real jq the predicate answers no_review^noreview^real^file^rc=1 reason=no_review" \
  "a torn read in the .verdict check itself is a gate failure, not a missing verdict^clean^torn_verdict^file^rc=1 reason=invalid detail~jq+exited+5=true detail~no+.verdict+field=false" \
  "a stderr diagnostic is neither a finding nor an echoed declaration^clean^chatty^file^rc=0 reason=valid measurement_failed=ABSENT" \
  "JQ_COLORS=zz, the real variable from the report, leaves the verdict alone^clean^colors^file^rc=0 reason=valid measurement_failed=ABSENT" \
  "a real rejection survives a chatty jq, its detail the gate's finding not the chatter^zeroed^chatty^file^rc=1 reason=zero_sample detail~killed+0/0=true"

echo "=== no mode exits without a parseable result ==="
# emit needs jq too, so with jq unavailable the script exited 127 with empty
# stdout (a blank line in --wait): a caller reading .ok got a parse error, not
# a refusal. An acceptance that could not be EMITTED is not an acceptance
# either: printing ok:false while exiting 0 is this defect class
# inside the emitter, and every caller that branches on exit status (orch's
# waiters, review-pr.md § 3.1, submit-pr.md § 1, the reviewer self-check)
# reads that 0 as accepted; the rule once lived in --wait alone, so all three
# modes pin it, each beside its real-jq control. The gates' error file is made
# at source time, before any mode runs, so every mode answers the same way:
# mktemp failing there exited empty with status 1, the status a legitimate
# rejection uses.
check_table \
  "no jq: --file exits 1, not 127, with a parseable rejection^clean^none^file^rc=1 parses=true ok=false reason=invalid" \
  "no jq: glob mode exits 1 with a parseable rejection^clean^none^glob^rc=1 parses=true ok=false reason=invalid" \
  "no jq: --wait exits 1 with a parseable rejection^clean^none^wait^rc=1 parses=true ok=false reason=invalid" \
  "--file: a valid artifact whose acceptance could not be emitted exits 1, not 0^clean^noemit^file^rc=1 parses=true ok=false reason=invalid" \
  "glob: the same^clean^noemit^glob^rc=1 parses=true ok=false reason=invalid" \
  "--wait: the same, an exit-0 refusal being the shape the capture once produced^clean^noemit^wait^rc=1 parses=true ok=false reason=invalid" \
  "control: --file with a working emit accepts the same artifact^clean^real^file^rc=0 ok=true" \
  "control: glob with a working emit accepts the same artifact^clean^real^glob^rc=0 ok=true" \
  "control: --wait with a working emit accepts the same artifact^clean^real^wait^rc=0 ok=true" \
  "an unusable TMPDIR exits 1 with a parseable rejection naming mktemp, not jq^measured^notmp^file^rc=1 parses=true ok=false reason=invalid detail~mktemp=true" \
  "control: a writable TMPDIR leaves the same artifact valid^measured^tmpok^file^rc=0 reason=valid"

echo "=== the last-resort emitter cannot emit unparseable JSON ==="
# emit_unavailable interpolates its detail into a JSON literal with no encoder
# available, on purpose: it runs when jq or mktemp has already failed. The
# details it carries are jq's stderr and mktemp's failure text, exactly the
# strings full of newlines and tabs that JSON cannot carry raw. Pinned by
# PARSING the output; a substring check would pass on the broken form. And
# normalising must not empty the message: the newline row keeps jq's words
# from both lines and carries no control character.
emit_table \
  "a plain message^nothing special here^parses=true ok=false reason=invalid" \
  "a newline: parses, and both lines survive^jq: error at line 3\\nCannot iterate over null^parses=true ok=false reason=invalid detail~jq:+error+at+line+3=true detail~Cannot+iterate+over+null=true cntrl=0" \
  "a tab^jq: parse error:\\tunexpected token^parses=true ok=false reason=invalid" \
  "a carriage return^mktemp: failed\\rretrying^parses=true ok=false reason=invalid" \
  "all three plus DEL^a\\nb\\tc\\rd\\177e^parses=true ok=false reason=invalid cntrl=0" \
  "a double quote^mktemp: cannot create \"/nonexistent/tmp.XXXX\"^parses=true ok=false reason=invalid" \
  "a backslash^jq: error: bad escape \\\\q in string^parses=true ok=false reason=invalid" \
  "every hazard at once^jq: \\\\ error \"here\"\\nand\\tthere\\rgone\\177^parses=true ok=false reason=invalid cntrl=0"

# NOT ASSERTED: the INT/TERM traps beside the EXIT trap. On the bash this suite
# runs under, a --wait watchdog killed with SIGTERM already cleans up through
# the EXIT trap alone, so removing the signal traps changes nothing observable
# and any assertion here would pass for the wrong reason. The traps are kept as
# correct-by-construction for shells that do not run EXIT on a signal; they are
# deliberately unpinned rather than pinned by a test that cannot fail. The
# same holds for the three exit-status guards behind the noemit rows: the
# explicit `|| exit 1` and `|| return 1` after an emit of an acceptance, and
# --wait's usable-result check. Each alone is redundant with the others and
# with errexit today, so deleting any one leaves every row green and only
# deleting them together reddens the --wait row; a once-failing emit cannot
# separate them, because --wait's confirm-once retry absorbs it. They are
# defence in depth against a refactor into a masking context, kept unpinned.

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
