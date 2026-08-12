#!/usr/bin/env bash
# Assertions on the review-gate WORKFLOW YAML — split out of
# review-writer.test.sh, which is the review-writer.sh engine suite. Two
# instrument classes live here, and they are different kinds of evidence:
#
#   tpl:*    grep-pins on expressions offline runs cannot execute (job-level
#            if:, permissions, triggers, refs, budgets). GitHub evaluates
#            those, so these keep them from being silently dropped or
#            reworded; the eviction behavior they stand for is asserted live
#            in tests/e2e-sandbox.sh.
#   relay:*  the relay step's SCRIPT, extracted from the YAML and EXECUTED
#            against a gh stub — not a pin, the real shell (VST-210).
#
# BOTH RUN AGAINST BOTH COPIES: the shipped template, and the adopted
# .github/workflows/review-gate-writer.yml found by walking up to the
# enclosing repo. That copy is what actually gates PRs and is hand-maintained,
# so template-only assertions would prove the behavior of a file CI never
# runs. In a CONSUMER the adopted copy is normally PRESENT and legitimately
# differs from the template (its own default branch in the ADAPT markers, an
# optional check_run guard) — so the pins and the relay battery run against it
# there too, while the whole-file drift check does not, being a
# self-adoption-only invariant. Only the template is asserted when no adopted
# copy is found at all.
#
# THE RELAY NEVER REDS is the invariant every relay case asserts, over both
# the runner's shells AND over its own environment (each env: binding dropped
# in turn) — a red or a hang on a PR-attached leg is a failed check on the PR
# head, which is the whole defect VST-210 removes.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

# Local copies rather than a shared lib: pr-watch.test.sh already carries its
# own, which is the established convention in this skill.
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        missing: %s\n' "$name" "$needle"
  fi
}

# ------------------------------------------------------------- the copies ---

TEMPLATE="$SKILL_ROOT/templates/review-gate-writer.yml"
# Walk up to the enclosing repo rather than assuming a fixed depth: this skill
# sits at skills/review-gate/ in the catalog but at .agents/skills/review-gate/
# in a consumer, so a hardcoded ../../ resolves to different places and would
# silently report "no copy here" in one of them.
SELF_ADOPTION=""
_dir="$SKILL_ROOT"
while [[ "$_dir" != "/" ]]; do
  if [[ -e "$_dir/.git" || -d "$_dir/.github" ]]; then
    SELF_ADOPTION="$_dir/.github/workflows/review-gate-writer.yml"
    break
  fi
  _dir="$(dirname "$_dir")"
done

WORKFLOWS=()
WORKFLOW_LABELS=()
if [[ -f "$TEMPLATE" ]]; then
  WORKFLOWS+=("$TEMPLATE"); WORKFLOW_LABELS+=("template")
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "the shipped template is missing at $TEMPLATE"
fi
if [[ -n "$SELF_ADOPTION" && -f "$SELF_ADOPTION" ]]; then
  WORKFLOWS+=("$SELF_ADOPTION"); WORKFLOW_LABELS+=("self-adoption copy")
else
  printf '  note  %s\n' "no adopted workflow found at ${SELF_ADOPTION:-<no enclosing repo root>} — asserting the template only"
fi

# ------------------------------------------------------------------ pins ----

pin_workflows() { # file, label
  local wf="$1" tag="$2"
  local write_block relay_block rc count

  pin() { # needle, name
    if grep -qF -- "$1" "$wf"; then
      PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "$2"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        missing: %s\n' "$tag" "$2" "$1"
    fi
  }
  # The write job is the file's last job; the relay sits between the
  # merge-group job and it.
  write_block="$(sed -n '/^  write:/,$p' "$wf")"
  relay_block="$(sed -n '/^  request-converge:/,/^  write:/p' "$wf")"
  if [[ -z "$write_block" || -z "$relay_block" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "could not slice the relay and write job blocks (job renamed or reordered?)"
    return
  fi

  # --- leg routing -----------------------------------------------------
  if grep -qF -- "    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'" <<<"$write_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the write job's if: is exactly the two converge legs (VST-210: no PR-attached leg holds the evictable group)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write job's if: is exactly the two converge legs (VST-210: no PR-attached leg holds the evictable group)"
  fi
  if grep -qF -- "    if: github.event_name != 'merge_group' && github.event_name != 'workflow_dispatch' && github.event_name != 'schedule'" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay's if: is the NEGATIVE list (a newly added PR-attached trigger relays by default, and the dispatch target is excluded so no loop exists)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's if: is the NEGATIVE list (a newly added PR-attached trigger relays by default, and the dispatch target is excluded so no loop exists)"
  fi

  # EVERY status STATE converges (no state filter of ANY spelling): under
  # newest-row evidence semantics a success→pending/failure transition is a
  # withdrawal and must close the gate event-fast. Grep's exit code is
  # branched explicitly — 1 is the passing absence; anything else (2 = read
  # error) fails rather than laundering into a pass.
  rc=0; grep -qF -- "github.event.state" "$wf" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: no status state filter of any spelling" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: a status state filter returned — withdrawals would wait for the cron floor" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the workflow could not be read (grep error)" ;;
  esac

  # --- the triggers the split made load-bearing ------------------------
  # workflow_dispatch stopped being a manual convenience at VST-210: it is
  # the relay's dispatch target. A consumer pruning it as "we never kick it
  # by hand" silently strips every event-fast path down to the cron floor,
  # and every relay run burns its retry against a 422.
  pin "  workflow_dispatch: {}" "tpl: workflow_dispatch stays in on: — it is the relay's DISPATCH TARGET, not a manual kick"
  pin "    - cron:" "tpl: the schedule floor survives — with the PR-attached legs relaying, it is the write job's only non-dispatch leg"

  # --- concurrency -----------------------------------------------------
  pin "cancel-in-progress: false" "tpl: pending writer runs are never cancelled mid-write"
  pin "group: review-gate-writer" "tpl: single writer concurrency group"
  # The whole point of VST-210: the relay is the job PR-attached runs
  # execute, so it must hold NO concurrency group — an evictable relay would
  # put the CANCELLED check straight back into the PR's rollup.
  rc=0; grep -q '^    concurrency:' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay holds NO concurrency group (it can never be evicted, so it can never leave a cancelled check on a PR)" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew a concurrency group — PR-attached runs are evictable again (VST-210 regression)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- the relay executes nothing ---------------------------------------
  # The relay is the job every PR-attached leg reaches, pull_request_target
  # included. Its stated design is "no checkout, no engine, no PR code".
  # The persist-credentials pin below is satisfied anywhere in the file, so
  # a checkout added HERE would otherwise keep the suite green.
  rc=0; grep -q 'uses: actions/checkout' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay checks nothing out — the pull_request_target leg's job holds no repository content at all" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew a checkout — it is the pull_request_target job and must execute no repository code" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- permissions ------------------------------------------------------
  rc=0; grep -qF -- "actions: write" <<<"$write_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the WRITE job holds no actions:write — the writer never re-runs CI" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write job requested actions:write (the writer never re-runs CI)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write block could not be read (grep error)" ;;
  esac
  count="$(grep -cF -- "actions: write" "$wf" || true)"
  if [[ "$count" == "1" ]] && grep -qF -- "actions: write" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: exactly ONE actions:write in the workflow, and it is the relay's dispatch scope"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        actions:write occurrences: %s (expected exactly 1, on the relay job)\n' "$tag" "tpl: exactly ONE actions:write in the workflow, and it is the relay's dispatch scope" "$count"
  fi

  # --- the dispatch ref: which ENGINE the indirection executes ----------
  # The single expression that decides that. github.ref_name here would be
  # the PR's BASE branch on the pull_request_target leg, so the relay would
  # dispatch whatever engine lives on a non-default branch — silently
  # breaking the default-branch-defined-writer guarantee the design rests
  # on. Two teeth: the exact literal is present on the relay, and no OTHER
  # DISPATCH_REF value can exist anywhere.
  if grep -qF -- "DISPATCH_REF: \${{ github.event.repository.default_branch || 'main' }}" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay dispatches onto the DEFAULT branch with the empty-expression fallback"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's DISPATCH_REF is not the default-branch expression — the converge pass would run a non-default-branch engine"
  fi
  count="$(grep -cF -- "DISPATCH_REF:" "$wf" || true)"
  assert_eq "$count" "1" "[$tag] tpl: exactly ONE DISPATCH_REF binding (a second could not be reached by the literal pin above)"

  # --- the budget pair: backoff cap vs the job's timeout ----------------
  # Both halves were reconciled by hand in round 1 and only one was pinned.
  # Assert the RELATION, not the literals, so a deliberate coordinated retune
  # still passes and an uncoordinated one lands on a test that explains why.
  local tmo cap_s attempt_s worst
  # `|| true` on each: a no-match grep exits 1, and under this file's
  # `set -euo pipefail` that status propagates out of the command
  # substitution and kills the SUITE — so removing the very term being pinned
  # would abort the run instead of failing it, which is silence reading as
  # success in the check meant to catch it.
  tmo="$(grep -oE '^    timeout-minutes: [0-9]+' <<<"$relay_block" | head -n 1 | awk '{print $2}' || true)"
  cap_s="$(grep -oE '^          cap=[0-9]+' <<<"$relay_block" | head -n 1 | cut -d= -f2 || true)"
  # Extracted, not hardcoded: all three terms of the budget come from the
  # file, so raising any one of them without the others lands here.
  attempt_s="$(grep -oE 'timeout [0-9]+ gh api' <<<"$relay_block" | head -n 1 | awk '{print $2}' || true)"
  if [[ -z "$tmo" || -z "$cap_s" || -z "$attempt_s" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        timeout-minutes=%s cap=%s per-attempt=%s\n' "$tag" "tpl: could not read the relay's timeout-minutes, backoff cap and per-attempt bound — the budget is unpinned" "$tmo" "$cap_s" "$attempt_s"
  else
    # Worst case the step can produce: two bounded dispatch attempts plus the
    # capped wait between them.
    worst=$(( 2 * attempt_s + cap_s ))
    if (( tmo * 60 > worst )); then
      PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay's timeout budget (${tmo}m) still outlasts its worst case (2 x ${attempt_s}s attempts + ${cap_s}s cap = ${worst}s) — a retry can finish instead of being CANCELLED on the PR head"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's timeout budget (${tmo}m) is NOT above its worst case (${worst}s) — a rate-limit retry would be killed by the timeout, leaving a cancelled check on the PR head"
    fi
  fi

  # --- no unbounded or unchecked calls in the relay ---------------------
  assert_contains "$relay_block" "tr -d '\\r'" "[$tag] tpl: response header reads strip CR — a CRLF status line otherwise carries \\r into the status comparison"
  assert_eq "$(grep -cF -- "tr -d '\\r'" <<<"$relay_block" || true)" "2" "[$tag] tpl: BOTH header readers normalize CR (header and header_status), not just one"
  assert_contains "$relay_block" "timeout 60 gh api" "[$tag] tpl: each dispatch attempt is time-bounded — an unresponsive API would otherwise hang to timeout-minutes and be CANCELLED on the PR head"
  # Comment lines stripped first: the block explains WHY it allocates no temp
  # file, and a needle that its own rationale satisfies is not a check.
  rc=0; grep -v '^ *#' <<<"$relay_block" | grep -q 'mktemp' || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay allocates no temp file — an unchecked mktemp is an undeclared failure path (empty name, ambiguous redirect) on a job that must never red" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew an mktemp — check it or drop it; the response belongs in a variable" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac
  # The no-match guard inside header(): without it a pipefail shell kills the
  # step on the ordinary path where the API simply sent no such header.
  # STRUCTURAL, not a single needle: EVERY grep in the relay's script must
  # tolerate a no-match. A bare one exits 1 on the ordinary path where the
  # API simply sent no such header, and under a pipefail shell that status
  # propagates out of the command substitution and `set -e` reds the PR.
  # A grep used as an if/elif CONDITION is exempt: `set -e` does not act on a
  # command in a condition, and its status is consumed by the test rather
  # than escaping. The hazard is a grep whose status can propagate out — in a
  # command substitution or a pipeline — so those are the ones counted.
  local escaping_greps guarded_greps
  escaping_greps="$(grep -v '^ *#' <<<"$relay_block" | grep 'grep ' | grep -vcE '^ *(el)?if ' || true)"
  guarded_greps="$(grep -v '^ *#' <<<"$relay_block" | grep 'grep ' | grep -vE '^ *(el)?if ' | grep -c '|| true' || true)"
  if [[ "$escaping_greps" == "$guarded_greps" && "$escaping_greps" != "0" ]]; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: all $escaping_greps status-escaping grep(s) in the relay step tolerate a no-match (a bare one reds the PR under pipefail on the ORDINARY path)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        %s status-escaping grep(s) in the relay step, only %s guarded with || true\n' "$tag" "tpl: every status-escaping grep in the relay step must tolerate a no-match under pipefail" "$escaping_greps" "$guarded_greps"
  fi

  # --- the loop breaker's second tooth ---------------------------------
  # The job if: is the first breaker and the line adoption.md tells
  # consumers to hand-edit; the step's own EVENT_NAME guard survives that
  # mis-edit. Nothing throttles a self-dispatch loop once started — the
  # relay holds no concurrency group by design.
  rc=0; grep -q '^      EVENT_NAME: \${{ github\.event_name }}$' <<<"$relay_block" || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the RELAY binds EVENT_NAME (its step's independent loop breaker reads it)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay lost its EVENT_NAME binding — the step's loop breaker reads an unset var (the write job's identical binding does NOT cover this)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac
  assert_contains "$relay_block" "workflow_dispatch|schedule)" "[$tag] tpl: the relay step refuses to dispatch when it ran on a converge leg"
  # WORKFLOW_REF reads like a convenience — it exists so a renamed copy needs
  # no ADAPT — which is exactly why it is the binding a consumer hand-edit is
  # most likely to drop. Its absence now degrades to the warn-and-defer path
  # rather than a red, but a dropped line still means no converge pass is
  # ever requested, so it is pinned as well as defaulted.
  rc=0; grep -q '^      WORKFLOW_REF: \${{ github\.workflow_ref }}$' <<<"$relay_block" || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay binds WORKFLOW_REF (without it no converge pass is ever requested — every event would silently defer to the cron floor)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay lost its WORKFLOW_REF binding — it degrades safely but requests NOTHING, so the event-fast path is gone" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- the relay's scope is dispatch and nothing else -------------------
  # Its dispatch failure exits GREEN by decision (a red relay recreates the
  # UNSTABLE pin) and it carries NO escalation — sustained failure surfaces
  # as gate staleness via the cron floor and pr-watch --heal. So issues:write
  # must not appear here: the rolling incident stays on the write job, and a
  # relay that grew the scope would mean the decision was reversed silently.
  rc=0; grep -q '^      issues: write$' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay holds NO issues:write — dispatch is its whole scope; sustained failure is detected as gate staleness, not by this job" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew issues:write — the no-escalation decision was reversed without updating the docs that state it" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- checkouts --------------------------------------------------------
  pin "if: failure() || cancelled()" "tpl: VST-36 escalation covers timeout-cancelled jobs"
  pin "persist-credentials: false" "tpl: checkouts drop credentials"
  pin "github.event.pull_request.head.repo.full_name != github.repository" "tpl: fork pull_request_review read-only flag"
  # BOTH engine checkouts are counted: a one-match pin would stay green if
  # either job regressed to the bare expression.
  count="$(grep -cF -- "ref: \${{ github.event.repository.default_branch || 'main' }}" "$wf" || true)"
  assert_eq "$count" "2" "[$tag] tpl: BOTH checkouts pin the default branch with the empty-expression fallback"
  rc=0; grep -qF -- 'ref: ${{ github.event.repository.default_branch }}' "$wf" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: no checkout uses the bare default_branch expression" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: a checkout regressed to the bare default_branch expression (empty resolution would reach actions/checkout's own fallback)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the workflow could not be read (grep error)" ;;
  esac
}

echo "=== workflow pins ==="
for i in "${!WORKFLOWS[@]}"; do
  pin_workflows "${WORKFLOWS[$i]}" "${WORKFLOW_LABELS[$i]}"
done

# ---------------------------------------------------- relay step behavior ---

# The relay's step is an ordinary shell script, so it is EXECUTED rather than
# pinned: extracted verbatim and run against a gh stub whose exit codes and
# response headers are scripted per attempt. Extraction failure is fatal on
# its own — a renamed step that silently yielded an empty script would make
# every case below pass against nothing.
RELAY_BIN="$TMP_ROOT/relay-bin"
mkdir -p "$RELAY_BIN"
# Records each invocation to a file (NOT stdout: the step redirects gh's
# stdout into its response capture), replays the scripted header fixture as
# the response, and exits with the Nth code of GH_CODES.
cat > "$RELAY_BIN/gh" <<'RELAY_GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
n=$(grep -c . "$GH_LOG")
[ -n "${GH_HEADERS:-}" ] && printf '%s\n' "$GH_HEADERS"
set -- $GH_CODES
eval "code=\${$n:-0}"
exit "$code"
RELAY_GH
chmod +x "$RELAY_BIN/gh"
# The step's backoff is a real >=60s sleep. Stubbing it keeps the offline
# suite fast AND makes the wait itself assertable — the argument is recorded.
cat > "$RELAY_BIN/sleep" <<'RELAY_SLEEP'
#!/usr/bin/env bash
echo "$1" >> "$SLEEP_LOG"
exit 0
RELAY_SLEEP
chmod +x "$RELAY_BIN/sleep"

RELAY_LOG="$TMP_ROOT/relay-gh.log"
SLEEP_LOG="$TMP_ROOT/relay-sleep.log"

# THE SHELLS THE RUNNER ACTUALLY USES. A `run:` block with no `shell:` key
# gets `bash -e {0}`; an explicit `shell: bash` gets
# `bash --noprofile --norc -eo pipefail {0}`. Running the extracted step under
# plain `bash` — as this harness first did — models NEITHER, and that gap hid
# real reds: under `-e` an underivable workflow_ref exited 1, and under
# pipefail a no-match `grep` inside the header helper killed the step on the
# ORDINARY retry path. Every case runs under both, and the two must agree.
RELAY_SHELLS=("-e" "-eo pipefail")

# RELAY_DROP names one env: binding to leave UNSET for this invocation, so
# the invariant can be asserted over the step's ENVIRONMENT as well as over
# API responses. The step runs under `set -u`, so an unbound read is a red —
# and a red here is a failed check on a PR head, permanently, on every event.
RELAY_DROP=""
_relay_once() { # shell-flags, step-path, read_only, ref, codes, event, headers
  : > "$RELAY_LOG"; : > "$SLEEP_LOG"
  local env_kv=(
    "WRITER_READ_ONLY=$3"
    "WORKFLOW_REF=$4"
    "EVENT_NAME=${6:-pull_request_target}"
    "GH_REPO=o/r"
    "DISPATCH_REF=main"
  )
  local keep=() kv
  for kv in "${env_kv[@]}"; do
    [[ -n "$RELAY_DROP" && "$kv" == "$RELAY_DROP="* ]] && continue
    keep+=("$kv")
  done
  set +e
  RELAY_OUT="$(env -u WRITER_READ_ONLY -u WORKFLOW_REF -u EVENT_NAME -u GH_REPO -u DISPATCH_REF \
    GH_LOG="$RELAY_LOG" SLEEP_LOG="$SLEEP_LOG" GH_CODES="$5" GH_HEADERS="${7:-}" \
    PATH="$RELAY_BIN:$PATH" "${keep[@]}" \
    bash $1 "$2" 2>&1)"
  RELAY_RC=$?
  set -e
  RELAY_CALLS="$(cat "$RELAY_LOG")"
  RELAY_SLEEPS="$(cat "$SLEEP_LOG")"
}

relay_run() { # step-path, read_only, workflow_ref, gh_codes, event_name, headers
  local first_rc="" first_calls="" first_sleeps="" flags
  for flags in "${RELAY_SHELLS[@]}"; do
    _relay_once "$flags" "$@"
    # THE INVARIANT, asserted on every case rather than per-case so a future
    # case cannot forget it: the relay never reds. It runs on PR-attached
    # legs, so a non-zero exit is a failed check on the PR head and pins
    # mergeStateStatus at UNSTABLE — the defect VST-210 removes. Nothing this
    # step can hit justifies that, because it holds no statuses scope and can
    # only ever leave the gate stale, which the cron floor owns.
    if [[ "$RELAY_RC" != "0" ]]; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n        exit %s under [bash %s]\n        output: %s\n' \
        "relay INVARIANT: the relay never reds a PR head (case: ro=$2 ref='$3' codes='$4' event='${5:-pull_request_target}'${RELAY_DROP:+ UNSET=$RELAY_DROP})" \
        "$RELAY_RC" "$flags" "$RELAY_OUT"
    else
      PASS=$((PASS + 1))
    fi
    if [[ -z "$first_rc" ]]; then
      first_rc="$RELAY_RC"; first_calls="$RELAY_CALLS"; first_sleeps="$RELAY_SLEEPS"
    elif [[ "$RELAY_RC" != "$first_rc" || "$RELAY_CALLS" != "$first_calls" || "$RELAY_SLEEPS" != "$first_sleeps" ]]; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n        [bash %s] rc=%s vs rc=%s under [bash %s]\n' \
        "relay INVARIANT: behavior is identical under both runner shells (a pipefail-only difference is a latent red)" \
        "$flags" "$RELAY_RC" "$first_rc" "${RELAY_SHELLS[0]}"
    else
      PASS=$((PASS + 1))
    fi
  done
}

RELAY_STEPS=()
relay_battery() { # file, label
  local wf="$1" tag="$2" step="$TMP_ROOT/relay-step-${#RELAY_STEPS[@]}.sh"
  local ref="o/r/.github/workflows/review-gate-writer.yml@refs/heads/main"
  awk '
    /^      - name: Request a converge pass$/ { found = 1; next }
    found && !inblock && /^        run: \|$/ { inblock = 1; next }
    inblock {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print; next }
      exit
    }
  ' "$wf" > "$step"
  if [[ -s "$step" ]] && grep -qF -- "/dispatches" "$step"; then
    RELAY_STEPS+=("$step")
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay: the step script extracted from the workflow (non-empty, dispatches)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay: could NOT extract the step script — every case below would prove nothing"
    return
  fi

  relay_run "$step" 0 "$ref" "0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay1: an ordinary PR-attached leg exits 0"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/review-gate-writer.yml/dispatches -f ref=main" \
    "[$tag] relay1: dispatches THIS workflow's file on the default branch, exactly once"

  # Control for the derivation: a repo that renamed its copy must dispatch
  # the renamed file. Without this, relay1 would also pass against a
  # hardcoded name.
  relay_run "$step" 0 "o/r/.github/workflows/gate.yml@refs/heads/trunk" "0"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/gate.yml/dispatches -f ref=main" \
    "[$tag] relay2: a RENAMED consumer copy dispatches its own file (github.workflow_ref is read, not a hardcoded name — no ADAPT line)"

  relay_run "$step" 1 "$ref" "0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay3: fork pull_request_review (read-only token) is a GREEN no-op, never a red run"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay3: the read-only leg dispatches NOTHING — the cron floor converges fork review evidence"

  relay_run "$step" 0 "" "0"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay4: an underivable workflow_ref dispatches NOTHING — never a garbage path (fail-closed)"
  assert_contains "$RELAY_OUT" "::warning::could not derive this workflow's file name" "[$tag] relay4: and warns instead of reddening — this is a PERMANENT condition, so a red here would pin every open PR at UNSTABLE forever while the cron floor keeps converging them anyway"

  relay_run "$step" 0 "$ref" "1 0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay5: a transient dispatch failure is retried once and succeeds"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay5: exactly two attempts — one bounded retry, not a loop"

  # GREEN on double failure, deliberately: the relay holds no statuses
  # scope, so it cannot make the gate look converged — only leave it stale,
  # which the cron floor owns. A red here would pin the PR at UNSTABLE, the
  # exact defect the split removes.
  relay_run "$step" 0 "$ref" "1 1"
  assert_eq "$RELAY_RC" "0" "[$tag] relay6: two failed dispatches exit GREEN — reddening would recreate the UNSTABLE pin for a fault the cron floor recovers from"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay6: the double-failure path still stops after two attempts"
  assert_contains "$RELAY_OUT" "::warning::could not request a converge pass after two attempts" "[$tag] relay6: the double failure is announced as a WARNING — the annotation is the per-run trace, gate staleness is the detector of record"
  rc=0; grep -qF -- "::error::" <<<"$RELAY_OUT" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay6: and NOT as an error — an error annotation on a green job is the shape a future 'restore fail-loud' edit leaves behind" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay6: the double-failure path emitted ::error:: — decide one way: green+warning (current) or red, not a mixed signal" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay6: the relay output could not be read (grep error)" ;;
  esac

  # --- the loop breaker, independent of the job if: --------------------
  relay_run "$step" 0 "$ref" "0" workflow_dispatch
  assert_eq "$RELAY_RC" "0" "[$tag] relay7: a relay that ran on the workflow_dispatch leg exits 0"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay7: and dispatches NOTHING — the step's own guard breaks a self-dispatch loop even if the job if: was mis-edited"
  assert_contains "$RELAY_OUT" "::warning::" "[$tag] relay7: the mis-edit is announced, not silently absorbed"
  relay_run "$step" 0 "$ref" "0" schedule
  assert_eq "$RELAY_CALLS" "" "[$tag] relay8: the schedule converge leg is refused by the same guard"

  # --- backoff: the retry must be able to outlast the limit it retries --
  # --- the retry ladder, against REAL response shapes ------------------
  # EVERY GitHub response — including 404s, 422s and 5xx — carries the five
  # x-ratelimit headers. Fixtures that omit them model a response GitHub does
  # not send, and that is precisely how a dead ladder passed review: reading
  # x-ratelimit-reset whenever retry-after was absent fired on every failure,
  # produced an hour-scale wait, tripped the budget refusal, and left the
  # relay making exactly one attempt in production while the suite stayed
  # green. So every fixture below carries a realistic header set, and the
  # rate-limit cases differ from the ordinary ones only where GitHub differs:
  # x-ratelimit-remaining, retry-after, or the secondary-limit body.
  local rl_ok rl_spent now
  now="$(date +%s)"
  rl_ok="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 4947
X-Ratelimit-Reset: $(( now + 1400 ))
X-Ratelimit-Resource: core"
  rl_spent="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 0
X-Ratelimit-Resource: core"

  # No response at all — a transport failure, not an HTTP answer.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay9: a failure with NO response at all retries quickly — the 60s floor belongs to the rate-limit shapes, not to every failure"

  # SECONDARY limit, the shape that sends retry-after.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 77
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "77" "[$tag] relay10: retry-after is honored (secondary limit)"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 4000
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay11: a window beyond the job's budget is NOT slept — retrying inside a window the server named is a guaranteed failure bought with a paid runner hold"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay11: and the second attempt is skipped entirely"
  assert_contains "$RELAY_OUT" "beyond this job's budget" "[$tag] relay11: the deferral names its reason"

  # PRIMARY limit: the window is SPENT (remaining 0) and a reset epoch says
  # when it refills. Computed from now so the case is not time-brittle.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent
X-Ratelimit-Reset: $(( now + 90 ))"
  case "$RELAY_SLEEPS" in
    88|89|90) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay12: an EXHAUSTED window (remaining 0) honors its reset epoch — slept ${RELAY_SLEEPS}s" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        expected ~90, got: %s\n' "$tag" "relay12: an exhausted window honors its reset epoch" "$RELAY_SLEEPS" ;;
  esac

  # THE REGRESSION THIS ROUND FIXED: the same reset epoch with the window
  # HEALTHY is an ordinary header, not rate-limit evidence. Reading it here
  # is what killed the ladder.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay12b: a healthy window's reset epoch is NOT a wait instruction — a 5xx still takes the quick transient retry (the dead-ladder regression)"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay12b: and the retry actually happens"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent
X-Ratelimit-Reset: 1000000000"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay13: a reset epoch in the PAST falls to the floor, never a negative sleep"

  # The clamp direction relay10 cannot reach.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 3
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay14: a sub-minute retry-after is raised to the 60s floor — obeying 3s verbatim retries back inside the limit"

  # SECONDARY limit without retry-after: the body is the only evidence left.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_ok
{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\"}"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay15: a secondary-limit 403 that sends no retry-after is recognized from its body and takes the floor"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay16: a 5xx blip retries QUICKLY — a minute of paid runner hold buys nothing against a transient"

  # PERMANENT answers buy nothing by waiting: no sleep, no second attempt.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 404 Not Found
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay19: a 404 is not slept on — a missing workflow file is a settled answer, and this job holds a runner on a PR head"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay19: and the second attempt is skipped"
  assert_contains "$RELAY_OUT" "refused permanently (HTTP 404)" "[$tag] relay19: the deferral names the permanent status"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 422 Unprocessable Entity
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay20: a 422 (bad ref) is not slept on either"

  # THE PERMISSIONS 403 — the most reachable permanent failure this job has,
  # since it is the only one needing actions:write in a hand-edited file. It
  # is byte-for-byte a 403 with a healthy window and no retry-after, which
  # the previous ladder spent 60s on and then retried into a certain failure,
  # on every event, forever.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_ok
{\"message\":\"Resource not accessible by integration\"}"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay21: a PERMISSIONS 403 is permanent — no wait, no retry (it is not a rate limit)"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay21: and only one attempt is made"
  assert_contains "$RELAY_OUT" "actions:write" "[$tag] relay21: the annotation names the likely cause instead of leaving a silent adoption failure"

  # Sanitizers: neither a non-numeric nor an out-of-range value may reach sleep.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
retry-after: soon
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay17: a non-numeric retry-after is discarded, not passed to sleep"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: soon
$rl_spent
X-Ratelimit-Reset: $(( now + 70 ))"
  case "$RELAY_SLEEPS" in
    68|69|70) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay17b: a non-numeric retry-after is discarded but an EXHAUSTED window still governs — slept ${RELAY_SLEEPS}s" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        expected ~70, got: %s\n' "$tag" "relay17b: a discarded retry-after falls through to the exhausted window" "$RELAY_SLEEPS" ;;
  esac
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
retry-after: 999999999
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay18: an out-of-range retry-after is discarded before it can overflow the arithmetic or reach sleep"

  # --- the invariant over the step's ENVIRONMENT ------------------------
  # The step runs under `set -u`, so its never-reds guarantee is only as good
  # as its env: block. Every binding sits in repo-owned YAML that adoption.md
  # tells consumers to hand-edit — the check_run guard goes on this job's
  # if:, and the ADAPT'd dispatch ref is three lines from WORKFLOW_REF — so a
  # dropped line is a live class, not a hypothetical. Unbound, each of these
  # used to kill the step before it printed anything, on every PR-attached
  # run, permanently. relay_run asserts rc 0 under both shells for each.
  local dropped
  for dropped in EVENT_NAME WRITER_READ_ONLY WORKFLOW_REF GH_REPO DISPATCH_REF; do
    RELAY_DROP="$dropped"
    relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
    RELAY_DROP=""
  done
  # And the two that decide whether anything is dispatched still fail CLOSED
  # when unbound — degrading to green must not mean degrading to a dispatch
  # against a garbage target.
  RELAY_DROP=WORKFLOW_REF
  relay_run "$step" 0 "$ref" "1 0" pull_request_target
  assert_eq "$RELAY_CALLS" "" "[$tag] relay22: an unbound WORKFLOW_REF dispatches NOTHING (it lands on the underivable-ref warn-and-defer path, not on a garbage path)"
  RELAY_DROP=""
}

echo "=== relay step behavior (request-converge, VST-210) ==="
for i in "${!WORKFLOWS[@]}"; do
  relay_battery "${WORKFLOWS[$i]}" "${WORKFLOW_LABELS[$i]}"
done

# The battery above proves each copy's step behaves; this proves they are the
# SAME step. Behavior equivalence under the cases we thought to write is
# weaker than byte-identity for a script that exists in two hand-maintained
# places — a divergence the cases do not happen to probe would otherwise ship.
# The step is pure logic with no vendored paths in it, so unlike the rest of
# the file it has no legitimate ADAPT reason to differ.
# WHOLE-FILE drift, not just the relay step. This round found a stale claim
# surviving in the adopted copy because the only cross-copy tooth covered the
# extracted step. Comments are compared out because ADAPT deliberately rewords
# them (vendored paths, default-branch notes) — prose drift between the copies
# is therefore NOT machine-checkable here and stays a review concern; what IS
# checked is that every line of CODE matches once the vendored script path is
# normalized, which is the class that changes behavior.
# Scoped to SELF-adoption. In the catalog the two files are the same artifact
# modulo the vendored script path, so any other code difference is drift. In a
# CONSUMER they are legitimately different: the adopted copy carries the repo's
# own ADAPTs (its default branch in the `|| 'main'` fallbacks, possibly a
# check_run guard on the relay's if:), so diffing them there would report
# intended configuration as drift. The relay-step byte-identity check below
# stays unconditional — that script carries no branch name and no vendored
# path, so it is ADAPT-free even for a consumer.
IS_CATALOG=0
[[ "$SKILL_ROOT" == */skills/review-gate && "$SKILL_ROOT" != */.agents/* ]] && IS_CATALOG=1
if [[ "${#WORKFLOWS[@]}" -eq 2 && "$IS_CATALOG" -eq 0 ]]; then
  printf '  note  %s\n' "adopted copy carries this repo's own ADAPTs (not the catalog) — whole-file drift not checked; the relay step's byte-identity still is"
fi
if [[ "${#WORKFLOWS[@]}" -eq 2 && "$IS_CATALOG" -eq 1 ]]; then
  _norm() { # strip comments and blank lines, normalize the vendored path
    grep -v '^ *#' "$1" | grep -v '^ *$' | sed 's#\.agents/skills/review-gate/#skills/review-gate/#g'
  }
  if diff -q <(_norm "${WORKFLOWS[0]}") <(_norm "${WORKFLOWS[1]}") >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "drift: the template and the adopted copy are identical in CODE once the vendored path is normalized"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "drift: the template and the adopted copy DIVERGED in code — a template edit was not mirrored"
    diff <(_norm "${WORKFLOWS[0]}") <(_norm "${WORKFLOWS[1]}") | head -20
  fi
fi

if [[ "${#RELAY_STEPS[@]}" -eq 2 ]]; then
  # diff exits 0 identical, 1 differing, >1 could-not-read. A missing input
  # must never be reported as drift, nor drift as a read failure.
  # rc captured, not read from a bare command: under this file's `set -e` a
  # differing diff would abort the suite before reaching the verdict below —
  # real drift would then look like a silent early finish rather than a FAIL.
  rc=0; diff -q "${RELAY_STEPS[0]}" "${RELAY_STEPS[1]}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1)); printf '  ok    %s\n' "relay: the template's and the adopted copy's relay steps are byte-identical (the step carries no ADAPT, so any drift is unintended)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the two copies' relay steps DIVERGED — a template edit was not mirrored into the adopted workflow"
       diff "${RELAY_STEPS[0]}" "${RELAY_STEPS[1]}" | head -20 ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the extracted relay steps could not be compared (diff read error) — drift is unproven, not disproven" ;;
  esac
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
