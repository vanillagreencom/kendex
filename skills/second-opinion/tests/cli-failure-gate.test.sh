#!/usr/bin/env bash
# Regression test for the second-opinion CLI-failure gate (vstack#809).
#
# When the external CLI fails to produce ANY review — it exits non-zero
# (quota/auth/network), times out, or returns nothing on a zero exit — the
# wrapper used to exit 0 with no artifact and no sidecar (or a generic exit 1),
# so a caller trusting the documented exit-code contract recorded success with
# no external opinion, invisibly, exactly when the lane was down. The fix routes
# these into the no-verdict class (like the no-scope/no-review gates): review/
# audit modes preserve whatever partial output exists as <output>.failed.json,
# echo the CLI's own error text on stderr, and exit EXIT_CLI_FAILED (5). This
# stays distinct from exit 4 (a model that answered but unusably) and does not
# apply to challenge/quick, which keep the generic exit 1.
#
# Drives the real script with a fake target CLI (no network). The stub is
# named `claude` and placed on PATH so the script's `command -v` validation
# passes; its exit code, stdout, stderr, and an optional sleep (for the timeout
# path) are controlled by env vars, and it records each invocation so the
# no-retry expectation on a hard failure can be asserted.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SECOND_OPINION="$REPO_ROOT/skills/second-opinion/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
skip() { printf '  skip  %s\n' "$1"; }

# Fixtures that create a failure by REMOVING write permission prove nothing as
# root, which ignores the mode bits entirely — the denial never happens and the
# assertions pass over a run that took the success path. Skipped out loud, so
# a root CI runner reports missing coverage rather than false coverage.
CAN_DENY_BY_MODE=true
[[ "$(id -u)" == "0" ]] && CAN_DENY_BY_MODE=false

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to exist: %s\n' "$file" >&2
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ ! -e "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to NOT exist: %s\n' "$file" >&2
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  # -e: a needle that begins with `-` (a flag name in an error message) would
  # otherwise be parsed by grep as its own options.
  if [[ -f "$file" ]] && grep -Fq -e "$needle" "$file"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file %s to contain: %s\n' "$file" "$needle" >&2
    if [[ -f "$file" ]]; then
      echo "        --- file contents ---" >&2
      sed -n '1,40p' "$file" >&2
    else
      echo "        (file does not exist)" >&2
    fi
  fi
}

# --- Fake target CLI ----------------------------------------------------------
# Behaviour is env-driven: STUB_RC (exit code), STUB_STDOUT (what it prints),
# STUB_STDERR (its error text, the "cause"), STUB_SLEEP (seconds, for the
# timeout path). Increments an on-disk counter so a hard-failure run can assert
# the wrapper did NOT proceed to the JSON-recovery retry. Named `claude` on PATH.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
n=$((n + 1))
printf '%s' "$n" > "$STUB_COUNTER"
cat > /dev/null            # drain the prompt on stdin
# Turn a directory read-only mid-run: the wrapper's own temp files already
# exist, so this reaches only the record allocation that happens after the CLI.
[[ -n "${STUB_LOCK_DIR:-}" ]] && chmod 0500 "$STUB_LOCK_DIR"
[[ "${STUB_SLEEP:-0}" != "0" ]] && sleep "$STUB_SLEEP"
[[ -n "${STUB_STDERR:-}" ]] && printf '%s\n' "$STUB_STDERR" >&2
[[ -n "${STUB_STDOUT:-}" ]] && printf '%s' "$STUB_STDOUT"
exit "${STUB_RC:-0}"
SH
chmod +x "$STUB"

# --- Throwaway git repo for --cwd --------------------------------------------
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
git -C "$WORK" checkout -q -b scope-branch
# Uncommitted change so `--range HEAD` yields a non-empty diff — the scope gate
# (vstack#652) refuses to run a review over an empty diff.
printf 'world\n' >> "$WORK/file.txt"

COUNTER="$TMP_ROOT/counter"

# The exact usage-limit shape from the incident report.
QUOTA_ERR="ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits."

# run_mode <mode> <extra-args...> then env passed via caller — returns rc.
# Runs `second-opinion <mode>` with the stub as target, resetting the counter.
run_review() {
  printf '0' > "$COUNTER"
  local out="$1" errf="$2" mode="${3:-review}"; shift 3 || true
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" "$mode" --range HEAD --cwd "$WORK" --output "$out" "$@" \
      >/dev/null 2>"$errf"
  rc=$?
  set -e
  return "$rc"
}

mkdir -p "$TMP_ROOT/out"

# --- Scenario 1: external CLI exits non-zero (quota) --------------------------
echo "=== scenario 1: non-zero CLI exit (usage limit) exits 5, .failed.json, cause named ==="
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
STUB_RC=1 STUB_STDERR="$QUOTA_ERR" run_review "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "5" "non-zero CLI exit yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s1_out" "non-zero CLI exit writes no --output artifact"
assert_file_exists "$s1_out.failed.json" "non-zero CLI exit preserves <output>.failed.json"
assert_file_contains "$s1_out.failed.json" "hit your usage limit" "sidecar captures the CLI's own cause text"
assert_file_contains "$s1_out.failed.json" "exited with code 1" "sidecar records the failure reason"
assert_file_contains "$s1_err" "hit your usage limit" "stderr surfaces the quota cause, not a bare code"
assert_file_contains "$s1_err" "refusing to write a review artifact" "stderr error JSON explains the refusal"
assert_eq "$(cat "$COUNTER")" "1" "hard CLI failure does not proceed to the recovery retry"

# --- Scenario 2: zero exit but empty stdout ----------------------------------
echo "=== scenario 2: zero exit, empty response exits 5, .failed.json, cause named ==="
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
STUB_RC=0 STUB_STDOUT="" STUB_STDERR="$QUOTA_ERR" run_review "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "5" "empty response on a zero exit yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s2_out" "empty response writes no --output artifact"
assert_file_exists "$s2_out.failed.json" "empty response preserves <output>.failed.json"
assert_file_contains "$s2_out.failed.json" "empty response" "sidecar records the empty-response reason"
assert_file_contains "$s2_out.failed.json" "hit your usage limit" "empty-response sidecar still captures the stderr cause"
assert_file_contains "$s2_err" "hit your usage limit" "empty-response stderr surfaces the cause"

# --- Scenario 3: timeout is a CLI failure too --------------------------------
echo "=== scenario 3: timeout exits 5 with .failed.json ==="
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" \
  SECOND_OPINION_TIMEOUT=1 \
  STUB_COUNTER="$COUNTER" \
  STUB_SLEEP=5 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s3_out" \
    >/dev/null 2>"$s3_err"
rc3=$?
set -e
assert_eq "$rc3" "5" "timeout yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s3_out" "timeout writes no --output artifact"
assert_file_exists "$s3_out.failed.json" "timeout preserves <output>.failed.json"
assert_file_contains "$s3_out.failed.json" "timed out after 1s" "sidecar records the timeout reason"

# --- Scenario 4: success path is untouched -----------------------------------
echo "=== scenario 4: a valid response still writes the artifact, no sidecar ==="
GOOD_JSON='{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
s4_out="$TMP_ROOT/out/review4.json"
s4_err="$TMP_ROOT/s4.stderr"
rc4=0
STUB_RC=0 STUB_STDOUT="$GOOD_JSON" run_review "$s4_out" "$s4_err" || rc4=$?
assert_eq "$rc4" "0" "success path still exits 0"
assert_file_exists "$s4_out" "success path writes the --output artifact"
assert_file_absent "$s4_out.failed.json" "success path writes no .failed.json sidecar"

# --- Scenario 5: challenge/quick are NOT in the no-verdict class -------------
# A CLI failure in a non-review mode keeps the generic exit 1 and writes no
# .failed.json — the exits-3/4/5 contract is review/audit-only.
echo "=== scenario 5: quick-mode CLI failure keeps generic exit 1, no .failed.json ==="
s5_out="$TMP_ROOT/out/quick5.txt"
s5_err="$TMP_ROOT/s5.stderr"
rc5=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" \
  STUB_COUNTER="$COUNTER" \
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" --output "$s5_out" \
    >/dev/null 2>"$s5_err"
rc5=$?
set -e
assert_eq "$rc5" "1" "quick-mode CLI failure keeps the generic exit 1"
assert_file_absent "$s5_out.failed.json" "quick mode writes no .failed.json (review/audit-only contract)"

echo

# --- Scenario 6: failure reported on stdout with empty stderr ------------------
# The Claude CLI prints its quota-limit message to stdout and exits non-zero with
# an empty stderr. The cause block used to read only stderr, so it came out empty
# and a capped lane was indistinguishable from a broken one. The cause now falls
# back to the stdout tail, tagged as the stdout source.
echo "=== scenario 6: non-zero exit, cause on stdout, empty stderr names the stdout cause ==="
s6_out="$TMP_ROOT/out/review6.json"
s6_err="$TMP_ROOT/s6.stderr"
rc6=0
STUB_RC=1 STUB_STDOUT="$QUOTA_ERR" STUB_STDERR="" run_review "$s6_out" "$s6_err" || rc6=$?
assert_eq "$rc6" "5" "stdout-reported failure yields EXIT_CLI_FAILED (5)"
assert_file_exists "$s6_out.failed.json" "stdout-reported failure preserves <output>.failed.json"
assert_eq "$(jq -r '.cause_source' "$s6_out.failed.json")" "claude stdout" "sidecar tags the cause as the stdout source"
assert_file_contains "$s6_out.failed.json" "hit your usage limit" "sidecar cause is populated from stdout, not empty"
assert_file_contains "$s6_err" "hit your usage limit" "stderr surfaces the stdout-reported cause, not a bare code"
assert_file_contains "$s6_err" "cause (claude stdout)" "printed cause block names the stdout source"

# --- Scenario 7: stdout-mode records live in the artifact home ---------------
# Without --output the preserved failure record has no sibling to sit beside;
# it goes to SECOND_OPINION_ARTIFACT_DIR (default tmp/second-opinion under
# --cwd), never to shared system temp. Relative values resolve under --cwd;
# absolute values are taken as-is.
echo "=== scenario 7: stdout-mode .failed record lands in the artifact home, not TMPDIR ==="
s7_err="$TMP_ROOT/s7.stderr"
s7_tmp="$TMP_ROOT/tmpdir7"
mkdir -p "$s7_tmp"
rc7=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s7_tmp" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s7_err"
rc7=$?
set -e
assert_eq "$rc7" "5" "stdout-mode CLI failure still exits 5"
s7_rec=$(ls "$WORK"/tmp/second-opinion/review-claude-failed.* 2>/dev/null | head -1 || true)
[[ -n "$s7_rec" ]] && pass "failure record written under <cwd>/tmp/second-opinion" || fail "no failure record under <cwd>/tmp/second-opinion"
assert_file_contains "$s7_err" "$WORK/tmp/second-opinion/review-claude-failed." "stderr names the record's project-local path"
assert_eq "$(ls "$s7_tmp" | wc -l | tr -d ' ')" "0" "nothing is left in TMPDIR by a stdout-mode failure"
s7_mode=$(stat -c%a "$WORK/tmp/second-opinion" 2>/dev/null || stat -f%Lp "$WORK/tmp/second-opinion")
assert_eq "$s7_mode" "700" "artifact home is owner-only"

s7_alt="$TMP_ROOT/alt-home"
rm -rf "$WORK/tmp/second-opinion"
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s7_tmp" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  SECOND_OPINION_ARTIFACT_DIR="$s7_alt" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s7_err"
set -e
[[ -n "$(ls "$s7_alt"/review-claude-failed.* 2>/dev/null)" ]] && pass "SECOND_OPINION_ARTIFACT_DIR relocates the record" || fail "SECOND_OPINION_ARTIFACT_DIR not honored"
assert_file_absent "$WORK/tmp/second-opinion" "default home untouched when SECOND_OPINION_ARTIFACT_DIR is set"

# --- Scenario 8: record placement never changes the outcome ------------------
# An artifact home that cannot be created (or that resolves through a symlink
# inside the reviewed repo) falls back to a plain temp file, loudly; the exit
# code and the CLI's cause text — what the record exists to carry — survive.
echo "=== scenario 8: uncreatable artifact home -> temp fallback, exit 5 and cause kept ==="
s8_err="$TMP_ROOT/s8.stderr"
s8_tmp="$TMP_ROOT/tmpdir8"
mkdir -p "$s8_tmp"
rc8=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s8_tmp" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  SECOND_OPINION_ARTIFACT_DIR="/proc/no-such-home/second-opinion" \
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s8_err"
rc8=$?
set -e
assert_eq "$rc8" "5" "uncreatable artifact home keeps EXIT_CLI_FAILED (5)"
assert_file_contains "$s8_err" "artifact home not creatable" "fallback is named on stderr"
assert_file_contains "$s8_err" "record kept in system temp instead" "fallback location is named"
assert_file_contains "$s8_err" "hit your usage limit" "the CLI's cause text still reaches stderr"
s8_rec=$(ls "$s8_tmp" 2>/dev/null | head -1 || true)
[[ -n "$s8_rec" ]] && pass "record fell back to TMPDIR" || fail "no fallback record in TMPDIR"

echo "=== scenario 9: a relative artifact home must be exactly <cwd>/<setting> — nothing is created elsewhere ==="
# run9 <artifact-dir-setting>: stdout-mode review whose CLI fails, so a record
# is written; both streams captured. reset9 gives each case a clean tmp/.
s9_err="$TMP_ROOT/s9.stderr"
s9_tmp="$TMP_ROOT/tmpdir9"
reset9() {
  rm -rf "$WORK/tmp" "$s9_tmp"
  mkdir -p "$s9_tmp" "$WORK/tmp"
}
run9() {
  set +e
  PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" \
    SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
    SECOND_OPINION_ARTIFACT_DIR="$1" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s9_err"
  rc9=$?
  set -e
}
fallback_used() { [[ -n "$(ls "$s9_tmp" 2>/dev/null | head -1 || true)" ]]; }

# (a) symlink whose target is INSIDE the repo: still not the named path
mkdir -p "$WORK/elsewhere"
reset9
ln -s "$WORK/elsewhere" "$WORK/tmp/second-opinion"
run9 tmp/second-opinion
assert_eq "$rc9" "5" "(a) symlink-to-inside keeps EXIT_CLI_FAILED (5)"
assert_file_contains "$s9_err" "artifact home rejected (symlink inside the reviewed repo" "(a) symlink-to-inside is rejected loudly"
assert_eq "$(find "$WORK/elsewhere" | wc -l | tr -d ' ')" "1" "(a) nothing lands under the symlink target"
fallback_used && pass "(a) record fell back to TMPDIR" || fail "(a) no fallback record in TMPDIR"
rm -rf "$WORK/elsewhere"

# (b) a plain relative path escaping --cwd
s9_out="$TMP_ROOT/outside-b"
rm -rf "$s9_out"
reset9
run9 "../$(basename "$s9_out")/second-opinion"
assert_eq "$rc9" "5" "(b) escaping path keeps EXIT_CLI_FAILED (5)"
assert_file_contains "$s9_err" 'artifact home rejected (escapes the reviewed repo (component "..")' "(b) .. component is rejected lexically"
assert_file_absent "$s9_out" "(b) no directory is created outside --cwd"
fallback_used && pass "(b) record fell back to TMPDIR" || fail "(b) no fallback record in TMPDIR"

# (c) symlinked parent pointing at a NOT-YET-EXISTING outside path: mkdir -p
# would have created it through the link
s9_ghost="$TMP_ROOT/ghost-c"
rm -rf "$s9_ghost"
reset9
ln -s "$s9_ghost" "$WORK/tmp/link-parent"
run9 tmp/link-parent/second-opinion
assert_eq "$rc9" "5" "(c) symlinked parent keeps EXIT_CLI_FAILED (5)"
assert_file_contains "$s9_err" "artifact home rejected (symlink inside the reviewed repo at $WORK/tmp/link-parent)" "(c) symlinked parent is rejected loudly"
assert_file_absent "$s9_ghost" "(c) no external directory is created through the symlinked parent"
fallback_used && pass "(c) record fell back to TMPDIR" || fail "(c) no fallback record in TMPDIR"

# (d) the post-creation rule: --cwd itself reached through a symlink still
# resolves the home under the PHYSICAL root and is accepted
s9_link_cwd="$TMP_ROOT/work-link"
rm -f "$s9_link_cwd"
ln -s "$WORK" "$s9_link_cwd"
rm -rf "$WORK/tmp" "$s9_tmp"; mkdir -p "$s9_tmp"
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$s9_link_cwd" >/dev/null 2>"$s9_err"
set -e
[[ -n "$(ls "$WORK"/tmp/second-opinion/review-claude-failed.* 2>/dev/null | head -1 || true)" ]] \
  && pass "(d) control: symlinked --cwd resolves the home under the physical root" \
  || fail "(d) control: symlinked --cwd wrongly rejected"
grep -q "artifact home rejected" "$s9_err" && fail "(d) control: symlinked --cwd produced a rejection"
rm -f "$s9_link_cwd"
rm -rf "$WORK/tmp"

# (e)/(f) the ordinary spellings of the same directory. A trailing slash and a
# leading ./ are how operators write a relative path; neither leaves the
# checkout, and both must land in the named home rather than being read as an
# empty or `.` component and sent to system temp with an escape reason nobody
# can act on.
for s9_spelling in "tmp/second-opinion/" "./tmp/second-opinion" ".//tmp/second-opinion" "tmp/./second-opinion" "tmp/second-opinion/."; do
  reset9
  run9 "$s9_spelling"
  assert_eq "$rc9" "5" "($s9_spelling) still exits EXIT_CLI_FAILED (5)"
  [[ -n "$(ls "$WORK"/tmp/second-opinion/review-claude-failed.* 2>/dev/null | head -1 || true)" ]] \
    && pass "($s9_spelling) record lands in the intended home" \
    || fail "($s9_spelling) record did not land under $WORK/tmp/second-opinion"
  grep -q "artifact home rejected" "$s9_err" && fail "($s9_spelling) wrongly rejected"
  fallback_used && fail "($s9_spelling) fell back to TMPDIR instead of the named home" \
    || pass "($s9_spelling) no system-temp fallback"
done

# (g) both spellings of the repo root share one accurate reason — neither is an
# escape, and a wrong diagnostic is what sends an operator looking for a
# containment bug that is not there.
for s9_root in "." "./"; do
  reset9
  run9 "$s9_root"
  assert_eq "$rc9" "5" "($s9_root) still exits EXIT_CLI_FAILED (5)"
  assert_file_contains "$s9_err" "names the reviewed repo root" "($s9_root) is diagnosed as the repo root"
  grep -q "escapes the reviewed repo" "$s9_err" && fail "($s9_root) is wrongly diagnosed as an escape"
  fallback_used && pass "($s9_root) record fell back to TMPDIR" || fail "($s9_root) no fallback record"
done

# (h) `~/…` is the spelling vstack's other path settings accept, and a settings
# file is not shell input — unexpanded it would create a directory literally
# named `~` inside the reviewed checkout.
s9_home="$TMP_ROOT/fakehome"
rm -rf "$s9_home"; mkdir -p "$s9_home"
reset9
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" HOME="$s9_home" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  SECOND_OPINION_ARTIFACT_DIR="~/so-records" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s9_err"
rc9=$?
set -e
assert_eq "$rc9" "5" "(~/so-records) still exits EXIT_CLI_FAILED (5)"
[[ -n "$(ls "$s9_home"/so-records/review-claude-failed.* 2>/dev/null | head -1 || true)" ]] \
  && pass "(~/so-records) expands to \$HOME" \
  || fail "(~/so-records) record did not land under $s9_home/so-records"
assert_file_absent "$WORK/~" "(~/so-records) no literal ~ directory in the reviewed checkout"
assert_file_absent "$s9_home/so-records/.gitignore" "an operator-named home outside the checkout is not given a .gitignore"

# bare `~` expands to $HOME too, and must not seed $HOME/.gitignore with `*`
reset9
rm -rf "$s9_home"; mkdir -p "$s9_home"
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" HOME="$s9_home" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  SECOND_OPINION_ARTIFACT_DIR="~" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s9_err"
set -e
[[ -n "$(ls "$s9_home"/review-claude-failed.* 2>/dev/null | head -1 || true)" ]] \
  && pass "(~) expands to \$HOME" || fail "(~) record did not land in $s9_home"
assert_file_absent "$s9_home/.gitignore" "a bare ~ home never seeds \$HOME/.gitignore"

# ~user is not expanded and must not become a literal directory either
reset9
set +e
PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" \
  SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  SECOND_OPINION_ARTIFACT_DIR="~someuser/records" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s9_err"
set -e
assert_file_contains "$s9_err" "~user expansion is not supported" "~user is refused, not taken literally"
assert_file_absent "$WORK/~someuser" "~user leaves no literal directory in the reviewed checkout"

# a tilde home with HOME unset has nothing to expand to and must say so rather
# than build a path out of the empty string
for s9_tilde in "~" "~/so-records"; do
  reset9
  set +e
  env -u HOME PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s9_tmp" \
    SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
    SECOND_OPINION_ARTIFACT_DIR="$s9_tilde" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s9_err"
  rc9=$?
  set -e
  assert_eq "$rc9" "5" "($s9_tilde, HOME unset) still exits EXIT_CLI_FAILED (5)"
  assert_file_contains "$s9_err" "HOME is not set" "($s9_tilde, HOME unset) names the missing HOME"
  assert_file_absent "$WORK/~" "($s9_tilde, HOME unset) no literal ~ directory appears"
  fallback_used && pass "($s9_tilde, HOME unset) record fell back to TMPDIR" \
    || fail "($s9_tilde, HOME unset) no fallback record"
done

# (j) the ignore seeding may only ever touch a directory THIS RUN created.
# A pre-existing home is the operator's — possibly a tracked directory with a
# curated .gitignore, and possibly holding a planted symlink.
s9_pre="$WORK/pre-existing"
# (j1) curated tracked .gitignore is untouched, and the tree stays clean
reset9
rm -rf "$s9_pre"; mkdir -p "$s9_pre"
printf 'build/\n' > "$s9_pre/.gitignore"
git -C "$WORK" add -f pre-existing/.gitignore >/dev/null 2>&1
git -C "$WORK" -c commit.gpgsign=false -c user.email=t@e -c user.name=t commit -q -m pre >/dev/null 2>&1
run9 pre-existing
assert_eq "$(cat "$s9_pre/.gitignore")" "build/" "a curated .gitignore in a pre-existing home is untouched"
assert_eq "$(git -C "$WORK" status --porcelain -- pre-existing/.gitignore | wc -l | tr -d ' ')" "0" \
  "the curated .gitignore is not modified in git's eyes"
# (j2) a pre-existing home with no .gitignore gets none
reset9
rm -rf "$s9_pre"; mkdir -p "$s9_pre"
run9 pre-existing
assert_file_absent "$s9_pre/.gitignore" "a pre-existing home is not given a .gitignore"
# (j3) a DANGLING .gitignore symlink must not become an arbitrary-file write.
# `-e` reads false for a dangling link, so an existence test would have followed
# it; only the created-only gate plus the noclobber (O_EXCL) write refuse it.
s9_target="$TMP_ROOT/attacker-target"
reset9
rm -rf "$s9_pre" "$s9_target"; mkdir -p "$s9_pre"
ln -s "$s9_target" "$s9_pre/.gitignore"
run9 pre-existing
assert_file_absent "$s9_target" "a dangling .gitignore symlink creates nothing at its target"
assert_eq "$(readlink "$s9_pre/.gitignore")" "$s9_target" "the symlink itself is left alone"
rm -rf "$s9_pre"
git -C "$WORK" rm -q --cached pre-existing/.gitignore >/dev/null 2>&1 || true
git -C "$WORK" -c commit.gpgsign=false -c user.email=t@e -c user.name=t commit -q -m unpre >/dev/null 2>&1 || true

# (i) the artifact home is git-ignored on creation, so records never dirty the
# reviewed working tree
reset9
run9 tmp/second-opinion
assert_file_exists "$WORK/tmp/second-opinion/.gitignore" "artifact home is seeded with a .gitignore"
assert_eq "$(cat "$WORK/tmp/second-opinion/.gitignore")" "*" ".gitignore ignores everything in the home"
assert_eq "$(git -C "$WORK" status --porcelain -- tmp/second-opinion | wc -l | tr -d ' ')" "0" \
  "records under the artifact home do not show up as untracked changes"

reset9
rm -rf "$WORK/tmp"

echo "=== scenario 10: a no-verdict run never leaves a PREVIOUS run's artifact at --output ==="
# External review is advisory, so callers are told to continue past a non-zero
# exit. A stale pass artifact surviving at the designated --output is then read
# as this run's verdict — the fail-open the union path already prevented, on the
# single-lane path that is now the default.
S10_STALE='{"agent":"external-claude","timestamp":"2020-01-01T00:00:00Z","verdict":"pass","summary":"STALE ARTIFACT FROM A PREVIOUS RUN","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
# Every path this script can write under a designated --output. Each entry is
# independent data, not one behavior: seeding only some of them would leave a
# dropped or mistyped suffix in the rm list undetectable.
S10_SIDECARS="raw.txt retry.txt failed.json noreview.json incomplete.json"
S10_LANES="claude codex"

# seed_stale_family <output>: the artifact, its five sidecars, and the lane
# family the roster could have produced on an earlier run at the same path.
seed_stale_family() {
  local base="$1" suffix lane
  printf '%s\n' "$S10_STALE" > "$base"
  for suffix in $S10_SIDECARS; do printf '%s\n' "$S10_STALE" > "$base.$suffix"; done
  for lane in $S10_LANES; do
    printf '%s\n' "$S10_STALE" > "$base.$lane.json"
    for suffix in $S10_SIDECARS; do printf '%s\n' "$S10_STALE" > "$base.$lane.json.$suffix"; done
  done
}

# assert_family_cleared <output> <label> [keep-suffix]: every seeded path is
# gone, except one suffix this run legitimately rewrote.
assert_family_cleared() {
  local base="$1" label="$2" keep="${3:-}" suffix lane
  assert_file_absent "$base" "$label: stale pass artifact cleared"
  for suffix in $S10_SIDECARS; do
    [[ "$suffix" == "$keep" ]] && continue
    assert_file_absent "$base.$suffix" "$label: stale .$suffix cleared"
  done
  for lane in $S10_LANES; do
    assert_file_absent "$base.$lane.json" "$label: stale $lane lane artifact cleared"
    for suffix in $S10_SIDECARS; do
      assert_file_absent "$base.$lane.json.$suffix" "$label: stale $lane .$suffix cleared"
    done
  done
}

# (a) single-lane provider failure
s10_out="$TMP_ROOT/out/review10.json"
s10_err="$TMP_ROOT/s10.stderr"
seed_stale_family "$s10_out"
rc10=0
STUB_RC=1 STUB_STDERR="$QUOTA_ERR" run_review "$s10_out" "$s10_err" || rc10=$?
assert_eq "$rc10" "5" "(a) provider failure over a stale artifact still exits 5"
assert_family_cleared "$s10_out" "(a)" failed.json
assert_file_exists "$s10_out.failed.json" "(a) this run's own failure record is still written"
assert_file_contains "$s10_out.failed.json" "hit your usage limit" "(a) the failure record is this run's, not the stale one"

# (b) target-selection refusal, before any invocation
s10b_out="$TMP_ROOT/out/review10b.json"
s10b_err="$TMP_ROOT/s10b.stderr"
seed_stale_family "$s10b_out"
printf '0' > "$COUNTER"
rc10b=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CODEX_MODEL=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" SECOND_OPINION_CODEX_CMD="$STUB" STUB_COUNTER="$COUNTER" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s10b_out" \
    >/dev/null 2>"$s10b_err"
rc10b=$?
set -e
assert_eq "$rc10b" "1" "(b) same-model roster still refuses with exit 1"
assert_eq "$(cat "$COUNTER")" "0" "(b) refusal invokes no CLI"
assert_family_cleared "$s10b_out" "(b)"

# (b2) the pre-flight exits clear too — once the invocation parses, exit 1 does
# not split into clearing and non-clearing halves.
s10d_out="$TMP_ROOT/out/review10d.json"
for s10d_bad in --timeout=abc --bogus; do
  seed_stale_family "$s10d_out"
  set +e
  PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s10d_out" "$s10d_bad" \
      >/dev/null 2>"$TMP_ROOT/s10d.stderr"
  rc10d=$?
  set -e
  assert_eq "$rc10d" "1" "($s10d_bad) exits 1"
  assert_family_cleared "$s10d_out" "($s10d_bad)"
done

# (b3) a lane artifact belonging to a target the roster no longer names is
# still a complete, schema-valid review with its own verdict — the guarantee is
# written without an exception for renamed or retired targets. But a sibling
# outside the roster is not a path this run writes, so its NAME cannot authorize
# deleting it: `<output>.notes.json` is both a legal-looking lane name and an
# ordinary user file. Only content that is a review this skill emitted qualifies.
s10e_out="$TMP_ROOT/out/review10e.json"
s10e_err="$TMP_ROOT/s10e.stderr"
seed_stale_family "$s10e_out"
printf '%s\n' "$S10_STALE" > "$s10e_out.retired-model.json"
printf '%s\n' "$S10_STALE" > "$s10e_out.retired-model.json.failed.json"
printf '%s\n' "$S10_STALE" > "$s10e_out.orphan-lane.json.raw.txt"   # sidecar with no artifact
# bystanders: the caller's own files under the same prefix. The first two share
# the exact NAME SHAPE of a lane artifact and differ only in content — the case
# a name-only rule destroys.
printf 'MY IMPORTANT NOTES\n'    > "$s10e_out.notes.json"
printf '{"foo":1,"bar":[2,3]}\n' > "$s10e_out.data.json"
printf 'MINE\n' > "$s10e_out.bak"
printf 'MINE\n' > "$s10e_out.notes.md"
printf 'MINE\n' > "${s10e_out}X"
printf 'MINE\n' > "$s10e_out.two.words.json"
rc10e=0
STUB_RC=1 STUB_STDERR="$QUOTA_ERR" run_review "$s10e_out" "$s10e_err" || rc10e=$?
assert_eq "$rc10e" "5" "(b3) the run over a retired lane artifact still exits 5"
assert_file_absent "$s10e_out.retired-model.json" "(b3) a retired target's lane artifact is cleared"
assert_file_absent "$s10e_out.retired-model.json.failed.json" "(b3) the retired lane's sidecar is cleared"
assert_file_exists "$s10e_out.notes.json" "(b3) a same-shaped name holding non-JSON text survives"
assert_file_exists "$s10e_out.data.json" "(b3) a same-shaped name holding unrelated JSON survives"
assert_eq "$(cat "$s10e_out.notes.json")" "MY IMPORTANT NOTES" "(b3) the surviving user file is untouched"
# An orphaned sidecar has no artifact to prove authorship, and a .raw.txt holds
# raw model prose rather than a verdict — nothing here can be read as a pass, so
# it is left alone rather than deleted on the strength of its name.
assert_file_exists "$s10e_out.orphan-lane.json.raw.txt" "(b3) an orphaned sidecar with no verifying artifact survives"
assert_file_exists "$s10e_out.bak" "(b3) bystander .bak survives"
assert_file_exists "$s10e_out.notes.md" "(b3) bystander .notes.md survives"
assert_file_exists "${s10e_out}X" "(b3) bystander with no separating dot survives"
assert_file_exists "$s10e_out.two.words.json" "(b3) a middle segment that is not a legal target name survives"

# ...and the sweep runs before argument validation, so an invocation that never
# gets past a bad flag must not destroy them either.
s10e2_out="$TMP_ROOT/out/review10e2.json"
printf 'MY IMPORTANT NOTES\n' > "$s10e2_out.notes.json"
printf '%s\n' "$S10_STALE"    > "$s10e2_out.retired-model.json"
set +e
PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
  STUB_COUNTER="$COUNTER" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s10e2_out" --bogus \
    >/dev/null 2>"$TMP_ROOT/s10e2.stderr"
rc10e2=$?
set -e
assert_eq "$rc10e2" "1" "(b3) a bad-flag run still exits 1"
assert_file_exists "$s10e2_out.notes.json" "(b3) a bad-flag run does not destroy a user's sibling"
assert_file_absent "$s10e2_out.retired-model.json" "(b3) a bad-flag run still clears a real retired lane artifact"

# (b4) the prefix scan must hold for the two hostile --output shapes the rest of
# the file already guards: a leading '-' (which rm/mkdir would read as flags —
# hence `--` everywhere) and glob metacharacters in the caller's own path (the
# scan quotes the prefix, so `[1]` matches literally instead of as a class).
for s10f_name in "-dash-review.json" "review[1].json"; do
  s10f_out="$TMP_ROOT/out/$s10f_name"
  rm -f -- "$TMP_ROOT/out/"*review*.json* 2>/dev/null || true
  printf '%s\n' "$S10_STALE" > "$s10f_out"
  # A RETIRED name, so only the prefix scan can clear it — a roster name would
  # be cleared by the enumerated pass and prove nothing about the scan.
  printf '%s\n' "$S10_STALE" > "$s10f_out.retired-model.json"
  printf 'MINE\n' > "$s10f_out.bak"
  rc10f=0
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" run_review "$s10f_out" "$TMP_ROOT/s10f.stderr" || rc10f=$?
  assert_eq "$rc10f" "5" "($s10f_name) still exits 5"
  assert_file_absent "$s10f_out" "($s10f_name) stale artifact cleared"
  assert_file_absent "$s10f_out.retired-model.json" "($s10f_name) the scan still reaches a retired lane artifact"
  assert_file_exists "$s10f_out.bak" "($s10f_name) bystander survives"
  rm -f -- "$s10f_out.bak" "$s10f_out.failed.json"
done

# (b5) the cleanup traps run rm on mktemp paths, so a TMPDIR whose name starts
# with '-' makes every one of those paths start with '-' too. Without the `--`
# separator rm parses them as flags, the removal silently fails behind its
# `|| true`, and the run leaks its prompt and stderr temp files.
#
# TMPDIR must be RELATIVE for this: an absolute one yields /…/-dashtmp/tmp.X,
# which begins with '/' and rm parses happily. Run from a scratch cwd so the
# relative name resolves there and mktemp hands back `-dashtmp/tmp.X`.
s10g_base="$TMP_ROOT/dashrun"
rm -rf -- "$s10g_base"; mkdir -p -- "$s10g_base/-dashtmp"
s10g_out="$TMP_ROOT/out/review10g.json"
rm -f -- "$s10g_out" "$s10g_out.failed.json"
printf '0' > "$COUNTER"
set +e
( cd "$s10g_base" && PATH="$TMP_ROOT/bin:$PATH" TMPDIR="-dashtmp" \
    SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
    STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s10g_out" \
      >/dev/null 2>"$TMP_ROOT/s10g.stderr" )
rc10g=$?
set -e
assert_eq "$rc10g" "5" "(b5) a dash-leading TMPDIR still exits 5"
assert_eq "$(find "$s10g_base/-dashtmp" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "(b5) the cleanup traps leave no temp files behind under a dash-leading TMPDIR"

# (c) control: a successful run over a stale artifact replaces it
s10c_out="$TMP_ROOT/out/review10c.json"
s10c_err="$TMP_ROOT/s10c.stderr"
printf '%s\n' "$S10_STALE" > "$s10c_out"
rc10c=0
STUB_RC=0 STUB_STDOUT="$GOOD_JSON" run_review "$s10c_out" "$s10c_err" || rc10c=$?
assert_eq "$rc10c" "0" "(c) control: success path still exits 0"
assert_eq "$(jq -r '.summary' "$s10c_out")" "Clean" "(c) control: artifact is this run's review, not the stale one"

echo "=== scenario 11: an uncreatable --output parent is a named pre-flight error ==="
# The clearing block has to create the parent before it can clear inside it. A
# bare `mkdir: cannot create directory` under set -e would be a failure mode
# the exit-code contract does not name.
s11_err="$TMP_ROOT/s11.stderr"
if $CAN_DENY_BY_MODE; then
  s11_ro="$TMP_ROOT/readonly-parent"
  rm -rf "$s11_ro"; mkdir -p "$s11_ro"; chmod 0500 "$s11_ro"
  printf '0' > "$COUNTER"
  rc11=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s11_ro/sub/review.json" \
      >/dev/null 2>"$s11_err"
  rc11=$?
  set -e
  chmod 0700 "$s11_ro"
  assert_eq "$rc11" "1" "uncreatable --output parent exits 1"
  assert_file_contains "$s11_err" "cannot create the --output parent directory" "the cause is named, not a bare mkdir error"
  assert_eq "$(cat "$COUNTER")" "0" "uncreatable --output parent invokes no CLI"
else
  skip "uncreatable --output parent: running as root, a mode-denied directory is still writable"
fi

# A DIRECTORY at --output can never become the artifact, and the clearing's rm
# would report it as a bare "Is a directory". Not mode-dependent, so it runs
# everywhere.
s11d="$TMP_ROOT/out/review11d.json"
rm -rf "$s11d"; mkdir -p "$s11d"
printf '0' > "$COUNTER"
rc11d=0
set +e
PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
  STUB_COUNTER="$COUNTER" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s11d" >/dev/null 2>"$s11_err"
rc11d=$?
set -e
assert_eq "$rc11d" "1" "a directory at --output exits 1"
assert_file_contains "$s11_err" "--output is a directory" "the directory cause is named"
grep -q "Is a directory" "$s11_err" && fail "a directory at --output leaks a bare rm error"
assert_eq "$(cat "$COUNTER")" "0" "a directory at --output invokes no CLI"
rmdir "$s11d"

echo "=== scenario 11b: an unclearable previous artifact is a named cause, not a bare rm error ==="
# The clearing runs before anything else, so a directory that denies write makes
# `rm` fail — under set -e that would abort with `rm: cannot remove …` and no
# statement of what the run was doing or why it stopped.
s11b_err="$TMP_ROOT/s11b.stderr"
if $CAN_DENY_BY_MODE; then
  s11b_dir="$TMP_ROOT/ro-out"
  rm -rf "$s11b_dir"; mkdir -p "$s11b_dir"
  printf '%s\n' '{"verdict":"pass","summary":"STALE"}' > "$s11b_dir/review.json"
  chmod 0500 "$s11b_dir"
  printf '0' > "$COUNTER"
  rc11b=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s11b_dir/review.json" \
      >/dev/null 2>"$s11b_err"
  rc11b=$?
  set -e
  chmod 0700 "$s11b_dir"
  assert_eq "$rc11b" "1" "an unclearable previous artifact exits 1"
  assert_file_contains "$s11b_err" "cannot clear a previous run's artifact" "the clearing failure is a named cause"
  assert_file_contains "$s11b_err" "$s11b_dir/review.json" "the named cause carries the path"
  assert_file_contains "$s11b_err" "Permission denied" "the named cause keeps rm's own actionable reason"
  assert_eq "$(cat "$COUNTER")" "0" "an unclearable artifact invokes no CLI"
else
  skip "unclearable previous artifact: running as root, a mode-denied directory is still writable"
fi

# The parent-directory error must carry its reason too — a named error the
# operator cannot act on is only half the fix.
if $CAN_DENY_BY_MODE; then
  s11c_ro="$TMP_ROOT/readonly-parent2"
  rm -rf "$s11c_ro"; mkdir -p "$s11c_ro"; chmod 0500 "$s11c_ro"
  set +e
  PATH="$TMP_ROOT/bin:$PATH" SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s11c_ro/sub/review.json" \
      >/dev/null 2>"$s11b_err"
  set -e
  chmod 0700 "$s11c_ro"
  assert_file_contains "$s11b_err" "cannot create the --output parent directory" "the parent failure is still a named cause"
  assert_file_contains "$s11b_err" "Permission denied" "the parent failure keeps mkdir's own reason"
else
  skip "uncreatable --output parent reason: running as root, a mode-denied directory is still writable"
fi

echo "=== scenario 12: no writable location at all keeps the exit class and the cause ==="
# The artifact home and system temp can both refuse (read-only, full). An
# unguarded final mktemp would die under set -e at exit 1, losing both the
# record AND the documented no-verdict classification the run was carrying.
# The wrapper needs temp space of its own for the prompt, so TMPDIR cannot
# start read-only: the stub locks it once its own files exist, leaving only the
# record allocation to fail.
s12_err="$TMP_ROOT/s12.stderr"
if $CAN_DENY_BY_MODE; then
  s12_tmp="$TMP_ROOT/tmpdir12"
  rm -rf "$s12_tmp" "$WORK/tmp"; mkdir -p "$s12_tmp"
  printf '0' > "$COUNTER"
  rc12=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$s12_tmp" \
    SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" STUB_COUNTER="$COUNTER" \
    SECOND_OPINION_ARTIFACT_DIR="/proc/no-such-home/second-opinion" \
    STUB_LOCK_DIR="$s12_tmp" STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$s12_err"
  rc12=$?
  set -e
  chmod 0700 "$s12_tmp"
  assert_eq "$rc12" "5" "unstorable record keeps EXIT_CLI_FAILED (5)"
  assert_file_contains "$s12_err" "no writable location for the record" "the storage loss is stated"
  assert_file_contains "$s12_err" "hit your usage limit" "the provider cause still reaches stderr"
  assert_file_contains "$s12_err" "refusing to write a review artifact" "the error JSON is still emitted"
else
  skip "unstorable record: running as root, a mode-denied TMPDIR is still writable"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
