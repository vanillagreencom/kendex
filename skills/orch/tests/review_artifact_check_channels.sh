#!/usr/bin/env bash
# The check's OWN MACHINERY, as opposed to the measurement gates it runs: the
# three channels a gate answers on, what happens when jq or mktemp cannot run at
# all, and the rule that no mode exits without a parseable result. Split from
# review_artifact_check_measurement.sh — these hold whatever the gates measure.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

assert_substr() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected substring: %s\n        in:                 %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# expect_valid <artifact-path> <desc> — accepting-direction assertion that
# survives a mutant. A bare `out="$("$CHECK" ...)"` aborts the whole run under
# set -e the moment a guard starts over-rejecting, which truncates the suite
# instead of naming what broke; the accepting direction is exactly where that
# matters, because it is what pins WHICH number a guard reads.
expect_valid() {
  local path="$1" desc="$2" out rc=0
  set +e
  out="$("$CHECK" --file "$path")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "$desc"
}

# expect_glob_valid <worktree> <agent> <boundary> <expected-path> <desc>
expect_glob_valid() {
  local wt="$1" ag="$2" bound="$3" want="$4" desc="$5" out rc=0
  set +e
  out="$("$CHECK" "$wt" "$ag" "$bound")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.path' <<<"$out")" "$want" "$desc"
}

echo "=== review-artifact-check: gate channels and availability ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
delegated_at=1750000000
REAL_JQ="$(command -v jq)"

# A clean artifact and a zero-sample one, the two inputs every case below needs.
zs_ok="$worktree/tmp/review-external-20260815-050505.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' > "$zs_ok"
zs_mut="$worktree/tmp/review-external-20260815-010101.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"validated: mutation: killed 0/0; stability: 10/10 at 16 threads"}' > "$zs_mut"

# --- a gate that could not run is never silence (vstack#1497 review) ---
# Both gate helpers used to signal "no problem" with an empty string, so a jq
# failure — a torn read of a non-atomically written artifact — was
# indistinguishable from a clean artifact, and --wait's `out="$(glob_check)"`
# capture suspends errexit for the whole body, turning it into ok=true.
SHIM_DIR="$TMP_ROOT/jqshim"
mkdir -p "$SHIM_DIR"
REAL_JQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:zero-sample"*) echo "jq: error (at file): simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$SHIM_DIR/jq"
chmod +x "$SHIM_DIR/jq"

set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" --file "$zs_mut")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a jq failure in a gate exits 1, not 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file a gate that could not run reports ok=false"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file a gate that could not run reports reason=invalid"
assert_substr "$(jq -r '.detail' <<<"$out")" "simulated torn read" "--file the gate failure carries jq's own diagnostic"
# jq's REAL status, not a wrapper sentinel: jq's 2 means a usage or system error
# and 5 means the program failed on the input, so a collapsed code names the
# wrong cause on every gate failure.
assert_substr "$(jq -r '.detail' <<<"$out")" "jq exited 5" "--file the gate failure reports jq's real exit status"

# ...and the --wait driver, where the capture-and-|| shape hid it
gwt="$TMP_ROOT/gatefail"
mkdir -p "$gwt/tmp"
printf '{"agent":"gf","verdict":"pass","summary":"mutation: killed 0/0; stability: 10/10 at 16 threads"}' > "$gwt/tmp/review-gf-20260101-000001.json"
set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" "$gwt" gf 0 --wait 4 --interval 1 2>/dev/null)"
rc=$?
set -e
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--wait does NOT return ok=true when a gate could not run"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--wait reports the gate failure as invalid"
assert_eq "$rc" "1" "--wait exits 1 on a gate failure"

# The same collapse exists on the PREDICATE side, where jq exit 1 (the answer
# is "no") and exit >=2 (the gate could not answer) would otherwise both read
# as "no problem". A jq that breaks only the no-review gate must not let the
# artifact fall through to some later gate's verdict.
PRED_SHIM="$TMP_ROOT/jqshim-pred"
mkdir -p "$PRED_SHIM"
printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:no-review"*) echo "jq: error: simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$PRED_SHIM/jq"
chmod +x "$PRED_SHIM/jq"
zs_pred="$worktree/tmp/review-external-20260815-091919.json"
printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$zs_pred"
set +e
out="$(PATH="$PRED_SHIM:$PATH" "$CHECK" --file "$zs_pred")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a broken predicate gate exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file a broken predicate gate reports invalid, not a later gate's verdict"
assert_substr "$(jq -r '.detail' <<<"$out")" "simulated torn read" "--file the predicate failure carries jq's own diagnostic"

# ...and with real jq the same artifact reports the predicate's real answer
set +e
out="$("$CHECK" --file "$zs_pred")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "with real jq the predicate answers no_review"

# CONTROLS. The shim must be selective, or "invalid" above would just be jq
# being broken for everything: an artifact rejected by an EARLIER gate still
# reports that gate's own reason under the same shim.
zs_shim_ctl="$worktree/tmp/review-external-20260815-090909.json"
printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$zs_shim_ctl"
set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" --file "$zs_shim_ctl")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "the shim breaks only the zero-sample gate; earlier gates still answer"

# ...and with real jq the same artifact and invocation report the real verdicts.
expect_valid "$zs_ok" "with real jq the clean artifact is valid, not invalid"
set +e
out="$("$CHECK" "$gwt" gf 0 --wait 4 --interval 1 2>/dev/null)"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--wait with real jq still reports the real rejection"

# --- jq's stderr never reaches the answer channel ---
# gate_filter merged stderr into stdout, so ANY jq diagnostic that leaves the
# exit status alone became the gate's finding. JQ_COLORS=zz is a documented jq
# variable that prints "Failed to set $JQ_COLORS" and exits 0: every artifact
# checked in that environment was rejected with a wrong cause, and the same
# string was echoed back as a FABRICATED instrument-failure declaration.
STDERR_SHIM="$TMP_ROOT/jqshim-stderr"
mkdir -p "$STDERR_SHIM"
printf '#!/usr/bin/env bash\necho "chatty jq: a diagnostic that changes no exit status" >&2\nexec %s "$@"\n' "$REAL_JQ" > "$STDERR_SHIM/jq"
chmod +x "$STDERR_SHIM/jq"

zs_chatty="$worktree/tmp/review-external-20260815-095959.json"
printf '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement in scope","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$zs_chatty"
set +e
out="$(PATH="$STDERR_SHIM:$PATH" "$CHECK" --file "$zs_chatty")"
rc=$?
set -e
assert_eq "$rc" "0" "--file a clean artifact still validates under a jq that writes to stderr"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file a stderr diagnostic is not read as a finding"
assert_eq "$(jq -r 'has("measurement_failed")' <<<"$out")" "false" "--file a stderr diagnostic is not echoed as a fabricated declaration"

# the real variable from the report, not just a hand-built shim
set +e
out="$(JQ_COLORS=zz "$CHECK" --file "$zs_chatty" 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "0" "--file JQ_COLORS=zz does not turn a clean artifact into a rejection"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "--file JQ_COLORS=zz leaves the verdict alone"
assert_eq "$(jq -r 'has("measurement_failed")' <<<"$out")" "false" "--file JQ_COLORS=zz fabricates no declaration"

# ...and a REAL rejection is still reported under the same chatty jq, so the
# fix is channel separation and not a gate that stopped answering.
set +e
out="$(PATH="$STDERR_SHIM:$PATH" "$CHECK" --file "$zs_mut")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a real rejection survives a chatty jq"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file the chatty jq does not mask a genuine zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "killed 0/0" "--file the detail is the gate's finding, not jq's chatter"

# --- no mode exits without a parseable result ---
# emit needs jq too, so when jq is unavailable the script used to exit 127 with
# empty stdout (or, in --wait, a blank line): a caller reading .ok got a parse
# error rather than a refusal.
NOJQ_BIN="$TMP_ROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
for b in bash env dirname mktemp rm tr stat date sleep ls cat sed grep basename touch mkdir printf; do
  bp="$(command -v "$b" 2>/dev/null)" && ln -sf "$bp" "$NOJQ_BIN/$b"
done
if [[ -n "$(PATH="$NOJQ_BIN" command -v jq 2>/dev/null || printf '')" ]]; then
  fail "the no-jq fixture PATH still resolves jq"
else
  nojq_wt="$TMP_ROOT/nojq-wt"
  mkdir -p "$nojq_wt/tmp"
  cp "$zs_chatty" "$nojq_wt/tmp/review-nojq-20260101-000001.json"
  nojq_case() {
    local label="$1"
    shift
    local out rc=0
    set +e
    out="$(PATH="$NOJQ_BIN" "$CHECK" "$@" 2>/dev/null)"
    rc=$?
    set -e
    assert_eq "$rc" "1" "no jq: $label exits 1, not 127"
    assert_eq "$(jq -r '.ok' <<<"$out" 2>/dev/null || printf 'unparseable')" "false" "no jq: $label prints a parseable rejection"
    assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "no jq: $label reports reason=invalid"
  }
  nojq_case "--file mode" --file "$zs_chatty"
  nojq_case "glob mode" "$nojq_wt" nojq 0
  nojq_case "--wait mode" "$nojq_wt" nojq 0 --wait 2 --interval 1

  # a jq that is PRESENT but fails every call takes the same route: the entry
  # probe passes, so this exercises emit's own fallback rather than the probe.
  BROKEN_BIN="$TMP_ROOT/brokenjq-bin"
  mkdir -p "$BROKEN_BIN"
  cp -a "$NOJQ_BIN/." "$BROKEN_BIN/"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN_BIN/jq"
  chmod +x "$BROKEN_BIN/jq"
  set +e
  out="$(PATH="$BROKEN_BIN" "$CHECK" --file "$zs_chatty" 2>/dev/null)"
  rc=$?
  set -e
  assert_eq "$rc" "1" "a jq that fails every call exits 1"
  assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "a jq that fails every call still prints a parseable rejection"
fi

# --- an accept path that could not emit an acceptance is not an acceptance ---
# emit catching a failed `jq -n` and printing a rejection is only half the job:
# the caller has to learn the answer changed. Printing `ok:false` while exiting
# 0 is this issue's own defect class inside the emitter added to close it, and
# every caller that branches on exit status — orch's waiters, review-pr.md
# § 3.1, submit-pr.md § 1, the reviewer self-check — reads that 0 as accepted.
# Asserted in ALL THREE modes: the rule lived in --wait alone.
ACCEPT_SHIM="$TMP_ROOT/jqshim-accept"
mkdir -p "$ACCEPT_SHIM"
# Fails only emit's own invocation, so every gate still answers and the artifact
# genuinely passes — the ONLY thing that fails is saying so.
printf '#!/usr/bin/env bash\nif [ "$1" = "-n" ]; then exit 4; fi\nexec %s "$@"\n' "$REAL_JQ" > "$ACCEPT_SHIM/jq"
chmod +x "$ACCEPT_SHIM/jq"
awt="$TMP_ROOT/acceptwt"
mkdir -p "$awt/tmp"
accept_art="$awt/tmp/review-acc-20260101-000001.json"
printf '{"agent":"acc","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$accept_art"

accept_mode_case() {
  local label="$1"
  shift
  local out rc=0
  set +e
  out="$(PATH="$ACCEPT_SHIM:$PATH" "$CHECK" "$@" 2>/dev/null)"
  rc=$?
  set -e
  assert_eq "$rc" "1" "$label: a valid artifact whose acceptance could not be emitted exits 1, not 0"
  assert_eq "$(jq -r '.ok' <<<"$out" 2>/dev/null || printf 'unparseable')" "false" "$label: it prints ok=false"
  assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "$label: it reports reason=invalid"
}
accept_mode_case "--file mode" --file "$accept_art"
accept_mode_case "glob mode" "$awt" acc 0
accept_mode_case "--wait mode" "$awt" acc 0 --wait 3 --interval 1

# MUST-FAIL CONTROLS: with real jq the same artifact is accepted in each mode,
# so the three assertions above are the shim's doing and not a check that
# refuses everything.
accept_control() {
  local label="$1"
  shift
  local out rc=0
  set +e
  out="$("$CHECK" "$@" 2>/dev/null)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$label: with a working emit the same artifact is accepted"
  assert_eq "$(jq -r '.ok' <<<"$out")" "true" "$label: with a working emit it reports ok=true"
}
accept_control "--file mode" --file "$accept_art"
accept_control "glob mode" "$awt" acc 0
accept_control "--wait mode" "$awt" acc 0 --wait 3 --interval 1

# --- --wait never exits 0 without an acceptance behind it ---
# Capturing glob_check's stdout suspends errexit for its body, so a path that
# failed part-way still returns 0. Construct exactly that: a jq that works for
# every gate but fails emit's own `jq -n`, so the accept path falls through to
# the jq-free emitter and glob_check returns 0 carrying a REJECTION. Without the
# guard the driver prints that body under exit 0 — an approval exit code on a
# refusal.
EMIT_SHIM="$TMP_ROOT/jqshim-emit"
mkdir -p "$EMIT_SHIM"
printf '#!/usr/bin/env bash\nif [ "$1" = "-n" ]; then exit 4; fi\nexec %s "$@"\n' "$REAL_JQ" > "$EMIT_SHIM/jq"
chmod +x "$EMIT_SHIM/jq"
ewt="$TMP_ROOT/emitwt"
mkdir -p "$ewt/tmp"
printf '{"agent":"ew","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$ewt/tmp/review-ew-20260101-000001.json"
set +e
out="$(PATH="$EMIT_SHIM:$PATH" "$CHECK" "$ewt" ew 0 --wait 3 --interval 1 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "1" "--wait exits 1 when the accept path could not emit an acceptance"
assert_eq "$(jq -r '.ok' <<<"$out" 2>/dev/null || printf 'unparseable')" "false" "--wait reports ok=false rather than an exit-0 refusal"
assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "--wait reports the emit failure as invalid"

# MUST-FAIL CONTROL: the same shim, the same artifact, real jq — accepted.
set +e
out="$("$CHECK" "$ewt" ew 0 --wait 3 --interval 1 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "0" "--wait with a working emit accepts the same artifact"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--wait with a working emit reports ok=true"

# --- the last-resort emitter cannot emit unparseable JSON ---
# emit_unavailable interpolates its detail into a JSON literal with no encoder
# available, on purpose: it runs when jq or mktemp has already failed. The
# details it carries are jq's stderr and mktemp's failure text — exactly the
# strings full of newlines and tabs, which JSON cannot carry raw. Asserted by
# PARSING the output, not by matching substrings: a substring check would pass
# on the broken form.
emit_probe="$TMP_ROOT/emit-probe.sh"
cat > "$emit_probe" <<PROBE
source "$REPO_ROOT/skills/orch/scripts/lib/review-artifact-gates.sh"
emit_unavailable "\$1"
PROBE
emit_case() {
  local name="$1" detail="$2" out
  set +e
  out="$(bash "$emit_probe" "$detail" 2>/dev/null)"
  set -e
  local parsed="unparseable"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 && parsed="parses"
  assert_eq "$parsed" "parses" "emit_unavailable output parses as JSON: $name"
  assert_eq "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null || printf 'unparseable')" "false" "emit_unavailable reports ok=false: $name"
  assert_eq "$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null || printf 'unparseable')" "invalid" "emit_unavailable reports reason=invalid: $name"
}
emit_case "a plain message" "nothing special here"
emit_case "a newline" "$(printf 'jq: error at line 3\nCannot iterate over null')"
emit_case "a tab" "$(printf 'jq: parse error:\tunexpected token')"
emit_case "a carriage return" "$(printf 'mktemp: failed\rretrying')"
emit_case "all three plus DEL" "$(printf 'a\nb\tc\rd\177e')"
emit_case "a double quote" 'mktemp: cannot create "/nonexistent/tmp.XXXX"'
emit_case "a backslash" 'jq: error: bad escape \q in string'
emit_case "every hazard at once" "$(printf 'jq: \\ error "here"\nand\tthere\rgone\177')"

# ...and the message still says something: normalising must not empty it.
set +e
emit_out="$(bash "$emit_probe" "$(printf 'jq: error at line 3\nCannot iterate over null')" 2>/dev/null)"
set -e
assert_substr "$(printf '%s' "$emit_out" | jq -r '.detail')" "Cannot iterate over null" "the normalised detail still carries jq's words"
assert_substr "$(printf '%s' "$emit_out" | jq -r '.detail')" "jq: error at line 3" "the normalised detail still carries the first line"
# Counted with grep, not with a jq regex: `[\u0000-\u001f]` inside a jq string
# is a literal character set (it matches the "u" in "null"), so that spelling
# reports a control character in a string that has none.
assert_eq "$(printf '%s' "$emit_out" | jq -r '.detail' | LC_ALL=C grep -o '[[:cntrl:]]' | wc -l | tr -d ' ')" "0" "the normalised detail carries no control characters"

# --- the check answers even when it cannot create its error channel ---
# The gates' error file is made at SOURCE time, before any mode runs and before
# the jq-free emitter was reachable. mktemp failing there exited empty with
# status 1 — the same status a legitimate rejection uses.
set +e
out="$(TMPDIR=/nonexistent-dir-for-review-artifact-check "$CHECK" --file "$zs_ok" 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "1" "an unusable TMPDIR exits 1"
assert_eq "$(jq -r '.ok' <<<"$out" 2>/dev/null || printf 'unparseable')" "false" "an unusable TMPDIR still prints a parseable rejection"
assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "an unusable TMPDIR reports reason=invalid"
assert_substr "$(jq -r '.detail' <<<"$out" 2>/dev/null || printf '')" "mktemp" "the TMPDIR rejection names its real cause, not jq"

# every mode, not just --file
set +e
out="$(TMPDIR=/nonexistent-dir-for-review-artifact-check "$CHECK" "$worktree" reviewer-zs "$delegated_at" 2>/dev/null)"
rc=$?
set -e
assert_eq "$rc" "1" "an unusable TMPDIR exits 1 in glob mode"
assert_eq "$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')" "invalid" "an unusable TMPDIR prints a parseable rejection in glob mode"

# MUST-FAIL CONTROL: a writable TMPDIR leaves the same artifact valid.
set +e
out="$(TMPDIR="$TMP_ROOT" "$CHECK" --file "$zs_ok")"
rc=$?
set -e
assert_eq "$rc" "0" "a writable TMPDIR leaves the same artifact valid"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "a writable TMPDIR reports the real verdict"

# NOT ASSERTED: the INT/TERM traps beside the EXIT trap. On the bash this suite
# runs under, a --wait watchdog killed with SIGTERM already cleans up through
# the EXIT trap alone, so removing the signal traps changes nothing observable
# and any assertion here would pass for the wrong reason. The traps are kept as
# correct-by-construction for shells that do not run EXIT on a signal; they are
# deliberately unpinned rather than pinned by a test that cannot fail.

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
