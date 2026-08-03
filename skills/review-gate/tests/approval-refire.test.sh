#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/approval-refire.sh
# (the orch test skills/orch/tests/approval_refire.sh exercises the legacy orch
# copy; this one invokes the engine's own script, including its lib/settings.sh
# resolution layer).
#
# The refire runs against a STUBBED review-predicate.sh placed next to it (it
# resolves the predicate relative to itself), so these tests pin the
# convergence branches independently of predicate behavior:
#   r1.  awaiting, no gate status            -> posts pending, no rerun
#   r2.  awaiting, already pending w/ same   -> no-op (no POST)
#        description
#   r3.  changes-requested                   -> posts failure
#   r4.  approved, current status success    -> no-op (no POST, no rerun)
#   r5.  approved, PRIOR success on the sha  -> direct success post, NO rerun
#        (current pending)                      (success-needs-proof fast path)
#   r6.  approved, no prior success          -> full rerun of the head's
#                                               completed pull_request runs;
#                                               NO direct success post
#   r7.  approved, run at MAX_ATTEMPTS cap   -> left alone (no rerun), exit 0
#   r8.  approved, QUIESCE=0, run in         -> no rerun (next sweep pass), exit 0
#        progress
#   r9.  predicate read failure              -> exit 1, NO POST, NO rerun
#   r10. gate-status history read failure    -> exit 1, NO POST, NO rerun
#   r11. missing required env (PR_NUMBER)    -> exit 1
#   r12. custom REVIEW_GATE_CONTEXT: a       -> rerun, not direct success
#        prior success under another            (proof is per-context), and
#        context is not proof                   posts name the custom context
#   r13. threads-open verdict                -> posts pending (downward path)
#   r14. REVIEW_GATE_CONTEXT resolved from   -> posts name the file's context
#        the settings file
#   r15. unparseable settings assignment     -> exit 1, NO POST, NO rerun
#        (TOML array syntax)                    (fail loud, never empty)
#   r16. non-integer rerun cap               -> exit 1
#   r17. legacy MAX_ATTEMPTS env raises the  -> run at attempt 5 reruns under
#        cap                                    MAX_ATTEMPTS=6
#   r18. settings value with trailing TOML   -> value resolves, comment
#        comment                                stripped
#   r19. same key assigned twice in the      -> exit 1, NO POST, NO rerun
#        settings file (file-wide matching      (ambiguous, fail loud)
#        makes it ambiguous)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

# Sandbox: the real refire + its real settings lib, next to a stubbed
# predicate.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin"
cp "$SKILL_ROOT/scripts/approval-refire.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$TMP_ROOT/scripts/lib/"
cat > "$TMP_ROOT/scripts/review-predicate.sh" <<'EOF'
#!/usr/bin/env bash
# Predicate stub: STUB_PREDICATE_RC != 0 simulates an evidence-read failure
# (no verdict); otherwise STUB_VERDICT_LINE is the authoritative verdict.
if [[ "${STUB_PREDICATE_RC:-0}" != "0" ]]; then
  echo "::error::stubbed predicate failure" >&2
  exit "${STUB_PREDICATE_RC}"
fi
printf '%s\n' "${STUB_VERDICT_LINE:?}"
EOF
chmod +x "$TMP_ROOT/scripts/review-predicate.sh" "$TMP_ROOT/scripts/approval-refire.sh"

# Parametrized `gh` stub:
#   STUB_GATE_HISTORY   JSON array (newest first) answered for
#                       commits/<sha>/statuses; "fail" fails the read
#   STUB_RUNS_MODE      completed|in_progress|empty|high_attempt — the
#                       actions/runs?head_sha= listing
#   STUB_POST_LOG       file collecting every status POST's args
#   STUB_RERUN_LOG      file collecting every rerun POST's run id
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
shift
args="$*"
case "$args" in
  *"/rerun"*)
    id="$(sed -n 's|.*actions/runs/\([0-9]*\)/rerun.*|\1|p' <<<"$args")"
    echo "rerun:$id" >> "${STUB_RERUN_LOG:?}"
    ;;
  "-X POST "*"/statuses/"*)
    echo "post:$args" >> "${STUB_POST_LOG:?}"
    ;;
  *"/commits/"*"/statuses"*)
    if [[ "${STUB_GATE_HISTORY:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_GATE_HISTORY:-[]}"
    ;;
  *"/actions/runs?"*)
    case "${STUB_RUNS_MODE:-completed}" in
      completed)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"completed","conclusion":"success","event":"pull_request","run_attempt":1},{"id":222,"name":"push run","status":"completed","conclusion":"success","event":"push","run_attempt":1}]}' ;;
      in_progress)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"in_progress","conclusion":null,"event":"pull_request","run_attempt":1}]}' ;;
      empty)
        echo '{"workflow_runs":[]}' ;;
      high_attempt)
        echo '{"workflow_runs":[{"id":111,"name":"ci","status":"completed","conclusion":"success","event":"pull_request","run_attempt":5}]}' ;;
      *) echo "unknown STUB_RUNS_MODE" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "unexpected gh api call: $args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# run_refire [ENV=val ...] — runs the refire under the stubs with the standard
# identifiers and fresh POST/rerun logs; prints stdout, returns its exit code.
# Settings resolve from /dev/null (built-in defaults) unless a case overrides
# REVIEW_GATE_SETTINGS_FILE to exercise the file layer.
POST_LOG="$TMP_ROOT/post.log"
RERUN_LOG="$TMP_ROOT/rerun.log"
run_refire() {
  : > "$POST_LOG"
  : > "$RERUN_LOG"
  env PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets PR_NUMBER=7 HEAD_SHA=headsha PR_AUTHOR=pr-author \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
    "$@" bash "$TMP_ROOT/scripts/approval-refire.sh" 2>&1
}

AWAITING="verdict=awaiting detail=awaiting a non-author review for headsha"
APPROVED="verdict=approved detail=reviewed at head with no unresolved threads"
CR="verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
THREADS="verdict=threads-open detail=2 unresolved review thread(s)"

echo "=== downward transitions are direct posts ==="

rc=0; out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "r1: awaiting exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "r1: awaiting posts pending"
assert_contains "$(cat "$POST_LOG")" "context=Review gate" "r1: post carries the default gate context"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r1: no rerun on a downward transition"

out=$(run_refire STUB_VERDICT_LINE="$AWAITING" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha"}]')
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "r2: already-pending same description posts nothing"
assert_contains "$out" "nothing to do" "r2: reports the no-op"

out=$(run_refire STUB_VERDICT_LINE="$CR" STUB_GATE_HISTORY='[]')
assert_contains "$(cat "$POST_LOG")" "state=failure" "r3: changes-requested posts failure"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r3: no rerun on changes-requested"

rc=0; out=$(run_refire STUB_VERDICT_LINE="$THREADS" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "r13: threads-open exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "r13: threads-open posts pending"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r13: no rerun on threads-open"

echo "=== upward flip: success needs proof ==="

rc=0; out=$(run_refire STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"ok"}]') || rc=$?
assert_eq "$rc" "0" "r4: approved with current success exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "r4: current success posts nothing"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r4: current success reruns nothing"

rc=0; out=$(run_refire STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"x"},{"context":"Review gate","state":"success","description":"ok"}]')
assert_contains "$(cat "$POST_LOG")" "state=success" "r5: prior success on the sha allows a direct success post"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r5: proof fast path never reruns"

rc=0; out=$(run_refire STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=completed) || rc=$?
assert_eq "$rc" "0" "r6: first approved flip exits 0"
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "r6: full rerun of the completed pull_request run only (never the push run)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "r6: no direct success without proof"

rc=0; out=$(run_refire STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' STUB_RUNS_MODE=high_attempt) || rc=$?
assert_eq "$rc" "0" "r7: attempt cap exits 0"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r7: run at MAX_ATTEMPTS is left alone"
assert_contains "$out" "cap 5" "r7: warns about the cap"

out=$(run_refire STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RUNS_MODE=high_attempt MAX_ATTEMPTS=6)
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "r17: legacy MAX_ATTEMPTS env raises the cap (attempt 5 reruns under cap 6)"

rc=0; out=$(run_refire STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='[]' \
  STUB_RUNS_MODE=in_progress QUIESCE=0) || rc=$?
assert_eq "$rc" "0" "r8: in-progress head under QUIESCE=0 exits 0"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "r8: in-progress run is left to finish"
assert_contains "$out" "still in progress" "r8: says why"

echo "=== fail loud, act never ==="

set +e
rc=0; out=$(run_refire STUB_PREDICATE_RC=2 STUB_GATE_HISTORY='[]')
rc=$?
set -e
assert_eq "$rc" "1" "r9: predicate failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "r9: no POST and no rerun on predicate failure"

set +e
out=$(run_refire STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=fail)
rc=$?
set -e
assert_eq "$rc" "1" "r10: status-history read failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "r10: no action on history read failure"

set +e
out=$(env PATH="$TMP_ROOT/bin:$PATH" GH_REPO=acme/widgets HEAD_SHA=headsha \
  REVIEW_GATE_SETTINGS_FILE=/dev/null \
  STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
  STUB_VERDICT_LINE="$AWAITING" bash "$TMP_ROOT/scripts/approval-refire.sh" 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "r11: missing PR_NUMBER exits 1"

set +e
out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  MAX_ATTEMPTS=lots)
rc=$?
set -e
assert_eq "$rc" "1" "r16: non-integer rerun cap exits 1"

echo "=== settings resolution (lib/settings.sh) ==="

out=$(run_refire STUB_VERDICT_LINE="$APPROVED" REVIEW_GATE_CONTEXT="CI Required" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"ok"}]' \
  STUB_RUNS_MODE=completed)
assert_eq "$(cat "$RERUN_LOG")" "rerun:111" "r12: another context's success is not proof - reruns instead"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "r12: and posts no success"

out=$(run_refire STUB_VERDICT_LINE="$AWAITING" REVIEW_GATE_CONTEXT="CI Required" STUB_GATE_HISTORY='[]')
assert_contains "$(cat "$POST_LOG")" "context=CI Required" "r12: posts name the custom context"

cat > "$TMP_ROOT/settings.toml" <<'EOF'
REVIEW_GATE_CONTEXT = "File Gate"
EOF
rc=0; out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/settings.toml") || rc=$?
assert_eq "$rc" "0" "r14: settings-file context exits 0"
assert_contains "$(cat "$POST_LOG")" "context=File Gate" "r14: posts name the settings-file context"

cat > "$TMP_ROOT/commented-settings.toml" <<'EOF'
REVIEW_GATE_CONTEXT = "File Gate" # inline TOML comment is valid
EOF
rc=0; out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/commented-settings.toml") || rc=$?
assert_eq "$rc" "0" "r18: settings value with a trailing TOML comment exits 0"
assert_contains "$(cat "$POST_LOG")" "context=File Gate" "r18: trailing comment does not pollute the value"

cat > "$TMP_ROOT/bad-settings.toml" <<'EOF'
REVIEW_GATE_CONTEXT = ["Review gate", "Other"]
EOF
set +e
out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/bad-settings.toml")
rc=$?
set -e
assert_eq "$rc" "1" "r15: unparseable settings assignment exits 1"
assert_contains "$out" "unsupported syntax" "r15: names the configuration error"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "r15: no POST and no rerun on a config error"

# Keys are matched file-wide regardless of TOML table (the settings contract),
# so a second assignment of the same name — here under an unrelated table —
# is ambiguous and must fail loud, never silently resolve to either value.
cat > "$TMP_ROOT/dup-settings.toml" <<'EOF'
REVIEW_GATE_CONTEXT = "File Gate"
[unrelated]
REVIEW_GATE_CONTEXT = "Other Gate"
EOF
set +e
out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/dup-settings.toml")
rc=$?
set -e
assert_eq "$rc" "1" "r19: duplicate key assignment exits 1"
assert_contains "$out" "assigned more than once" "r19: names the ambiguity"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "r19: no POST and no rerun on a duplicate-key config error"

# TOML permits leading whitespace before a key, and keys under a table are
# often indented. An indented re-assignment is the SAME ambiguity as r19 and
# must fail identically — before this guard matched leading whitespace, the
# indented copy lost silently to the column-0 copy.
cat > "$TMP_ROOT/indented-dup-settings.toml" <<'EOF'
REVIEW_GATE_CONTEXT = "File Gate"
[unrelated]
  REVIEW_GATE_CONTEXT = "Other Gate"
EOF
set +e
out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/indented-dup-settings.toml")
rc=$?
set -e
assert_eq "$rc" "1" "r20: indented duplicate key assignment exits 1"
assert_contains "$out" "assigned more than once" "r20: names the ambiguity"

# A key assigned ONLY with indentation is a real TOML assignment and must be
# READ — silently resolving it to the built-in default is silent gate
# divergence on a security-sensitive key.
cat > "$TMP_ROOT/indented-only-settings.toml" <<'EOF'
[env]
  REVIEW_GATE_CONTEXT = "Indented Gate"
EOF
rc=0; out=$(run_refire STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/indented-only-settings.toml") || rc=$?
assert_eq "$rc" "0" "r21: indented-only assignment exits 0"
assert_contains "$(cat "$POST_LOG")" "context=Indented Gate" "r21: the indented value is read, not the default"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
