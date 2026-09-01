#!/usr/bin/env bash
# Assertions on the review-gate WORKFLOW YAML — split out of
# review-writer.test.sh, which is the review-writer.sh engine suite.
#
# Two instrument classes, over two different subjects:
#
#   [template]  the TEMPLATE's own contract, run against
#               templates/review-gate-writer.yml ALONE. What it covers is
#               enumerated once, in DEVELOPMENT.md § The workflow template —
#               repeating that list here would be a second copy to drift.
#               What it does NOT cover is in two places: the ledger below
#               for the IN-SET exclusions and what covers each, and that
#               same section for the classes outside the set altogether.
#   relay:*     the relay step's SCRIPT, extracted from the YAML and EXECUTED
#               against a gh stub — not a pin, the real shell (VST-210). Run
#               against both copies.
#
# The relay battery runs against BOTH copies: the shipped template, and the
# adopted .github/workflows/review-gate-writer.yml found by walking up to the
# enclosing repo. That copy is what actually gates PRs and is hand-maintained.
# Two divergence classes are legitimate, and neither is a value anyone types:
# this repo's self-adoption swaps the vendored script path for the tracked
# one, and a consumer that opted into check_run has uncommented two trigger
# lines. The whole-file drift check is scoped to self-adoption for the second
# of those. Only the template is asserted when no adopted copy is found.
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

# EXACT on the clamped wait the step computed and announced (RELAY_WAIT), not
# on the number handed to sleep — that one carries the step's random jitter.
# The relationship between the two is asserted per run in relay_run, so
# nothing is lost by pinning the deterministic half here. Nothing below reads
# a clock: the step's is stubbed, so no case is time-dependent.
RELAY_JITTER_MAX=0
assert_sleep() { # base, tag, name
  local base="$1" tag="$2" name="$3"
  if [[ "$RELAY_WAIT" == "$base" ]]; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        expected a %ss wait, got: %s (slept [%s])\n' \
      "$tag" "$name" "$base" "${RELAY_WAIT:-<no retry warning>}" "$RELAY_SLEEPS"
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

# CATALOG or CONSUMER. It decides the adopted copy's label, and whether the
# whole-file drift check is meaningful: in the catalog the two files are one
# artifact modulo the vendored path, and in a consumer the check_run opt-in
# is a legitimate difference the diff cannot tell from drift.
IS_CATALOG=0
[[ "$SKILL_ROOT" == */skills/review-gate && "$SKILL_ROOT" != */.agents/* ]] && IS_CATALOG=1
ADOPTED_LABEL="adopted copy"
[[ "$IS_CATALOG" -eq 1 ]] && ADOPTED_LABEL="self-adoption copy"

WORKFLOWS=()
WORKFLOW_LABELS=()
if [[ -f "$TEMPLATE" ]]; then
  WORKFLOWS+=("$TEMPLATE"); WORKFLOW_LABELS+=("template")
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "the shipped template is missing at $TEMPLATE"
fi
if [[ -n "$SELF_ADOPTION" && -f "$SELF_ADOPTION" ]]; then
  WORKFLOWS+=("$SELF_ADOPTION"); WORKFLOW_LABELS+=("$ADOPTED_LABEL")
else
  printf '  note  %s\n' "no adopted workflow found at ${SELF_ADOPTION:-<no enclosing repo root>} — asserting the template only"
fi

# --------------------------------------------- the template's own contract ---

# Derivations over the SHIPPED TEMPLATE, and only it. `validate-workflow.sh`
# answers whether an adopted COPY is still a copy; it derives nothing, so it
# cannot judge what the template says — edit the template, re-copy, and its
# diff is empty on a broken contract. These run once rather than per copy:
# equality already carries the template into every copy.
#
# WHAT THE SET IS. Every property is a check below or a ledger row below,
# and DEVELOPMENT.md § The workflow template writes that list out. It is NOT
# every property the workflow rests on — the same section names the two
# classes deliberately outside it. Read it before calling something a gap.
#
# LEDGER — inside the set, deliberately NOT checked here, because something
# else reds when the property goes:
#   * the relay step's converge-leg refusal (`workflow_dispatch|schedule)`)
#     — the battery below EXECUTES the step on both converge legs, so
#     removing the guard turns each into a dispatch the case did not expect.
#   * every status-escaping grep in the relay tolerates a no-match — the two
#     header readers carry `|| true`, and the battery runs the step under
#     `-eo pipefail` asserting THE RELAY NEVER REDS, so dropping either guard
#     reds the retry and status-parsing cases. No count: it moves with the
#     battery.
#   * the WRITE job holds no `actions: write` — subsumed by the exactly-one
#     grant check below, which counts the whole file and requires the one
#     grant to sit on the relay.
# No fourth row for DISPATCH_REF, WORKFLOW_REF or EVENT_NAME: `_relay_once`
# supplies all three as literals, so the battery proves the step degrades
# safely without one and nothing about whether the file still carries it.

if [[ -f "$TEMPLATE" ]]; then
  echo "=== the template's own contract ==="
  # The write job is the file's last; the relay sits between the merge-group
  # job and it.
  write_block="$(sed -n '/^  write:/,$p' "$TEMPLATE")"
  relay_block="$(sed -n '/^  request-converge:/,/^  write:/p' "$TEMPLATE")"
  whole="$(cat "$TEMPLATE")"

  # Every presence and count read drops full-line comments first, through
  # `live`. DEVELOPMENT.md § The workflow template states the rest of the
  # technique — which patterns avoid a spelling, which are byte-exact on
  # purpose, and what none of them reach.
  live() { grep -v '^[[:space:]]*#' <<<"$1"; }
  # A match is the failure — and so is a grep READ error, which never passes.
  # An EXTRA match reds, which is the fail-closed direction for an absence.
  absent() { # haystack, ERE, name
    local rc=0
    grep -qE -- "$2" <<<"$(live "$1")" || rc=$?
    case "$rc" in
      1) PASS=$((PASS + 1)); printf '  ok    [template] %s\n' "$3" ;;
      0) FAIL=$((FAIL + 1)); printf '  FAIL  [template] %s\n' "$3" ;;
      *) FAIL=$((FAIL + 1)); printf '  FAIL  [template] %s — could not be read\n' "$3" ;;
    esac
  }
  # COUNTED, never "at least one": a count says how many LIVE lines carry it,
  # so a deletion and a comment-out both move the number.
  count_is() { # haystack, ERE, expected, name
    assert_eq "$(grep -cE -- "$2" <<<"$(live "$1")" || true)" "$3" "[template] $4"
  }
  tpl_eq() { assert_eq "$1" "$2" "[template] $3"; }

  if [[ -z "$write_block" || -z "$relay_block" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [template] %s\n' "could not slice the relay and write job blocks (job renamed or reordered?)"
  else
    # --- leg routing ---------------------------------------------------
    # BYTE-EXACT, not term-wise: an appended '|| true' leaves every term in
    # place and makes the expression always true, so the relay runs on the
    # converge legs it excludes and the write job's evictable concurrency
    # group lands on a PR-attached leg (VST-210).
    tpl_eq "$(grep -m 1 -E '^    if: ' <<<"$relay_block" || true)" \
      "    if: github.event_name != 'merge_group' && github.event_name != 'workflow_dispatch' && github.event_name != 'schedule' && (github.event_name != 'check_run' || github.event.check_run.name == vars.REVIEW_GATE_CHECK_RUN_NAME)" \
      "the relay's if: is EXACTLY the expected expression"
    tpl_eq "$(grep -m 1 -E '^    if: ' <<<"$write_block" || true)" \
      "    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'" \
      "the write job's if: is EXACTLY the two converge legs"

    # --- the triggers the VST-210 split made load-bearing ---------------
    # workflow_dispatch is the relay's DISPATCH TARGET, not a manual kick: a
    # consumer pruning it strips every event-fast path to the cron floor and
    # every relay run burns its retry against a 422. The cron floor is then
    # the write job's only non-dispatch leg.
    count_is "$whole" '^  workflow_dispatch: \{\}$' "1" "workflow_dispatch stays in on: — it is the relay's dispatch target"
    count_is "$whole" '^    - cron: ' "1" "the schedule floor survives — the write job's only non-dispatch leg"
    # Under newest-row evidence semantics a success->pending/failure
    # transition is a WITHDRAWAL and must converge event-fast; any state
    # filter would make it wait for the cron floor instead.
    absent "$whole" 'github\.event\.state' "no status state filter of any spelling"

    # --- the relay executes nothing, and cannot be evicted ---------------
    # It is the job every PR-attached leg reaches, pull_request_target
    # included: no checkout, no engine, no PR code. An evictable relay puts
    # the CANCELLED check straight back on the PR head.
    absent "$relay_block" 'uses: actions/checkout' "the relay checks nothing out — the pull_request_target job holds no repository content"
    absent "$relay_block" '^    concurrency:' "the relay holds NO concurrency group, so it can never be evicted onto a PR as a cancelled check"
    # Dispatch is its whole scope; sustained failure surfaces as gate
    # staleness (cron floor + pr-watch --heal), never as an incident here.
    # No `$` on the three permission patterns: YAML permits a trailing
    # `# comment` after a scalar, which an end-anchored pattern misses. No
    # key extends these two, so the indentation anchor alone ties them to a
    # job-level `permissions:` entry.
    absent "$relay_block" '^      issues: write' "the relay holds NO issues:write — the no-escalation decision stands"

    # --- permissions -----------------------------------------------------
    # ONE grant in the whole file, and it is the relay's dispatch scope: the
    # writer never re-runs CI, so a second grant anywhere — the write job
    # included — is the decision reversed.
    count_is "$whole" '^      actions: write' "1" "exactly ONE actions:write in the workflow (the writer never re-runs CI)"
    count_is "$relay_block" '^      actions: write' "1" "and it is the RELAY's dispatch scope, not the write job's"

    # --- the single-writer contract --------------------------------------
    # Two writer runs must not interleave, and a pending one must never be
    # cancelled mid-write — the group is on the WRITE job, never the relay.
    count_is "$write_block" '^      group: review-gate-writer$' "1" "the write job holds the single-writer concurrency group"
    count_is "$write_block" '^      cancel-in-progress: false$' "1" "pending writer runs are never cancelled mid-write"

    # --- checkouts -------------------------------------------------------
    # A write-capable token on a checked-out tree is the pull_request_target
    # hazard. COUNTED against the checkouts: a single-match pin is satisfied
    # by the first and says nothing about the second.
    checkouts="$(grep -cE 'uses: actions/checkout' <<<"$(live "$whole")" || true)"
    creds="$(grep -cE '^          persist-credentials: false$' <<<"$(live "$whole")" || true)"
    if [[ "$checkouts" != "0" && "$creds" == "$checkouts" ]]; then
      PASS=$((PASS + 1)); printf '  ok    [template] %s\n' "all $checkouts checkout(s) drop credentials"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [template] EVERY checkout must drop credentials — %s checkout(s), %s persist-credentials: false\n' "$checkouts" "$creds"
    fi
    # Both engine jobs check out the DEFAULT branch, bare: a fallback would
    # be a per-repo value in a file that carries none, and a wrong one runs
    # an engine from a branch that does not exist.
    count_is "$whole" '^          ref: \$\{\{ github\.event\.repository\.default_branch \}\}$' "$checkouts" "EVERY checkout pins the bare default-branch expression"
    absent "$whole" 'default_branch \|\|' "no ref falls back to a hardcoded branch name"
    # ORDER, not ingredients: a guard AFTER its checkout has already let the
    # unpinned ref onto disk. G a guard's binding, C a checkout, in file order.
    tpl_eq "$(live "$whole" | awk '/^          DEFAULT_BRANCH: / { printf "G" } /uses: actions\/checkout/ { printf "C" } END { printf "\n" }')" "GCGC" "each engine job's default-branch guard PRECEDES its checkout"
    # The REFUSAL, not the diagnostic beside it. Bound to the guard's OWN
    # message: the two missing-engine guards also exit 1.
    tpl_eq "$(live "$whole" | awk '/default_branch resolved empty/ { w = 3; next } w > 0 { if ($0 ~ /^[[:space:]]*exit[[:space:]]+[1-9]/) { n++; w = 0 } else w-- } END { print n + 0 }')" "2" "BOTH guard steps exit NONZERO on an empty resolution"

    # --- which ENGINE the indirection executes ---------------------------
    # github.ref_name here would be the PR's BASE branch on the
    # pull_request_target leg, so the relay would dispatch whatever engine
    # lives on a non-default branch. Equality on the binding, plus a count so
    # a second binding cannot sit out of reach of it. The battery cannot
    # cover this: _relay_once supplies DISPATCH_REF as a literal.
    tpl_eq "$(grep -m 1 -E '^      DISPATCH_REF: ' <<<"$relay_block" || true)" \
      "      DISPATCH_REF: \${{ github.event.repository.default_branch }}" \
      "the relay dispatches onto the DEFAULT branch, with no per-repo fallback"
    count_is "$whole" '^      DISPATCH_REF: ' "1" "exactly ONE DISPATCH_REF binding, so no second value sits out of reach"
    # Same reason for the other two the step reads. Without WORKFLOW_REF no
    # converge pass is ever requested and every event defers to the cron
    # floor; without EVENT_NAME the step's own loop breaker reads an unset
    # var, and the job if: becomes the only one left.
    count_is "$relay_block" '^      WORKFLOW_REF: \$\{\{ github\.workflow_ref \}\}$' "1" "the relay binds WORKFLOW_REF — without it no converge pass is ever requested"
    count_is "$relay_block" '^      EVENT_NAME: \$\{\{ github\.event_name \}\}$' "1" "the relay binds EVENT_NAME — its step's independent loop breaker reads it"

    # --- the relay's failure surface -------------------------------------
    # A red or a hang on a PR-attached leg is a failed check on the PR head.
    # The battery executes the step and cannot see these: a dropped `timeout`
    # still reaches the gh stub, and an added mktemp still succeeds.
    count_is "$relay_block" 'timeout [0-9]+ gh api' "1" "each dispatch attempt is time-bounded — an unresponsive API would otherwise hang to timeout-minutes and be CANCELLED on the PR head"
    absent "$relay_block" 'mktemp' "the relay allocates no temp file — an unchecked mktemp is an undeclared failure path on a job that must never red"
    count_is "$relay_block" "tr -d '\\\\r'" "2" "BOTH header readers normalize CR — a CRLF status line otherwise carries \\r into the status comparison"

    # --- the fork leg, and the escalation arm ----------------------------
    # A fork pull_request_review hands the workflow a read-only token, so
    # the step must know to no-op rather than red.
    count_is "$whole" "github\.event\.pull_request\.head\.repo\.full_name != github\.repository" "1" "the fork pull_request_review read-only flag is derived, not assumed"
    # VST-36: a job killed by its timeout is CANCELLED, not failed, so an
    # escalation armed on failure() alone would miss exactly the case it exists for.
    count_is "$whole" '^        if: failure\(\) \|\| cancelled\(\)$' "1" "the escalation arm covers timeout-cancelled jobs (VST-36)"

    # --- the check_run loop breaker --------------------------------------
    # It recognises this workflow's own completions once a consumer opts
    # check_run in. Rename a job without the list and it stops matching, with
    # no concurrency group on the relay to throttle what follows. Job names
    # are the 4-space `name:`; step names carry a `- `.
    job_names="$(grep -E '^    name: ' "$TEMPLATE" | sed 's/^    name: //' | sort)"
    guard_names="$(sed -n '/case "\${CHECK_NAME:-}" in/,/esac/p' "$TEMPLATE" | grep -E '^ *"[^"]+"(\|"[^"]+")*\)$' | tr '|' '\n' | sed 's/[")]//g; s/^ *//' | sort)"
    if [[ -n "$guard_names" && "$job_names" == "$guard_names" ]]; then
      PASS=$((PASS + 1)); printf '  ok    [template] %s\n' "the check_run breaker lists exactly this workflow's job names"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [template] the check_run breaker has drifted from the job names\n        jobs:  [%s]\n        guard: [%s]\n' "$(tr '\n' '/' <<<"$job_names")" "$(tr '\n' '/' <<<"$guard_names")"
    fi

    # --- the budget pair --------------------------------------------------
    # The RELATION, so a coordinated retune passes and an uncoordinated one
    # lands here. All four terms come from the file; a timeout under the
    # retry budget kills a rate-limit retry and leaves a CANCELLED check on
    # the PR head. `|| true` on each read: a no-match would abort the suite
    # under this file's pipefail rather than fail the check.
    tmo="$(grep -oE '^    timeout-minutes: [0-9]+' <<<"$relay_block" | head -n 1 | awk '{print $2}' || true)"
    cap_s="$(grep -oE '^          cap=[0-9]+' <<<"$relay_block" | head -n 1 | cut -d= -f2 || true)"
    attempt_s="$(grep -oE 'timeout [0-9]+ gh api' <<<"$(live "$relay_block")" | head -n 1 | awk '{print $2}' || true)"
    jitter_s="$(grep -oE '^          jitter_max=[0-9]+' <<<"$relay_block" | head -n 1 | cut -d= -f2 || true)"
    if [[ -z "$tmo" || -z "$cap_s" || -z "$attempt_s" || -z "$jitter_s" ]]; then
      FAIL=$((FAIL + 1)); printf '  FAIL  [template] the relay budget is unpinned — timeout-minutes=%s cap=%s per-attempt=%s jitter_max=%s\n' "$tmo" "$cap_s" "$attempt_s" "$jitter_s"
    elif (( tmo * 60 > 2 * attempt_s + cap_s + jitter_s )); then
      PASS=$((PASS + 1)); printf '  ok    [template] %s\n' "the relay's timeout budget (${tmo}m) outlasts its worst case (2 x ${attempt_s}s + ${cap_s}s cap + ${jitter_s}s jitter)"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [template] %s\n' "the relay's timeout budget (${tmo}m) is NOT above its worst case — a retry is killed and leaves a cancelled check on the PR head"
    fi
  fi
fi




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
# The step bounds each dispatch with `timeout 60 gh api ...`. GNU `timeout` is
# coreutils, absent from a default macOS — which this suite must run on (Bash
# 3.2). Without a shim every attempt exits 127 before reaching the gh stub and
# 56 assertions fail there and only there. Pass-through, not a real timer: the
# stub answers instantly, and the timeout-killed case is modelled by GH_CODES
# handing back 124, which this propagates like the real command does.
cat > "$RELAY_BIN/timeout" <<'RELAY_TIMEOUT'
#!/usr/bin/env bash
shift
exec "$@"
RELAY_TIMEOUT
chmod +x "$RELAY_BIN/timeout"
# The step derives an exhausted window's wait as `reset - $(date +%s)`. With a
# REAL clock the fixture's reset epoch is stamped when the case is built and
# the subtraction happens when the step runs, so a case that straddles a
# one-second boundary computes a wait one lower than the case it is compared
# against — and relay_run runs every case twice and asserts the two agree.
# Measured at 43 disagreements in 64 parallel runs. Freezing the clock removes
# the race outright and lets the waits be asserted exactly.
FAKE_NOW=1700000000
cat > "$RELAY_BIN/date" <<'RELAY_DATE'
#!/usr/bin/env bash
[ "$1" = "+%s" ] && { echo "${FAKE_NOW:-1700000000}"; exit 0; }
for d in /usr/bin/date /bin/date; do [ -x "$d" ] && exec "$d" "$@"; done
echo "date stub: no system date found" >&2
exit 127
RELAY_DATE
chmod +x "$RELAY_BIN/date"

RELAY_LOG="$TMP_ROOT/relay-gh.log"
SLEEP_LOG="$TMP_ROOT/relay-sleep.log"

# THE SHELLS THE RUNNER ACTUALLY USES. A `run:` block with no `shell:` key
# gets `bash -e {0}`; an explicit `shell: bash` gets
# `bash --noprofile --norc -eo pipefail {0}`. Running the extracted step under
# plain `bash` models NEITHER, and the difference is load-bearing: under `-e`
# an underivable workflow_ref exits 1, and under pipefail a no-match `grep`
# inside the header helper kills the step on the ORDINARY retry path. Every
# case runs under both, and the two must agree.
RELAY_SHELLS=("-e" "-eo pipefail")

# RELAY_DROP names one env: binding to leave UNSET for this invocation, so
# the invariant can be asserted over the step's ENVIRONMENT as well as over
# API responses. The step runs under `set -u`, so an unbound read is a red —
# and a red here is a failed check on a PR head, permanently, on every event.
RELAY_DROP=""
_relay_once() { # shell-flags, step-path, read_only, ref, codes, event, headers, check_name
  : > "$RELAY_LOG"; : > "$SLEEP_LOG"
  local env_kv=(
    "WRITER_READ_ONLY=$3"
    "WORKFLOW_REF=$4"
    "EVENT_NAME=${6:-pull_request_target}"
    "GH_REPO=o/r"
    "DISPATCH_REF=main"
    "CHECK_NAME=${8:-}"
  )
  local keep=() kv
  for kv in "${env_kv[@]}"; do
    [[ -n "$RELAY_DROP" && "$kv" == "$RELAY_DROP="* ]] && continue
    keep+=("$kv")
  done
  set +e
  RELAY_OUT="$(env -u WRITER_READ_ONLY -u WORKFLOW_REF -u EVENT_NAME -u GH_REPO -u DISPATCH_REF -u CHECK_NAME \
    GH_LOG="$RELAY_LOG" SLEEP_LOG="$SLEEP_LOG" GH_CODES="$5" GH_HEADERS="${7:-}" \
    FAKE_NOW="$FAKE_NOW" PATH="$RELAY_BIN:$PATH" "${keep[@]}" \
    bash $1 "$2" 2>&1)"
  RELAY_RC=$?
  set -e
  RELAY_CALLS="$(cat "$RELAY_LOG")"
  RELAY_SLEEPS="$(cat "$SLEEP_LOG")"
  # The step announces the CLAMPED wait and its JITTER separately and sleeps
  # their sum. Split them back out. The clamp is the whole deterministic
  # computation — it is what every case asserts and what the two shells are
  # compared on; the jitter is random by construction, so comparing IT across
  # shells would compare noise, not behavior. The recorded sleep is not
  # dropped: relay_run asserts, per shell, that it equals the sum the step
  # announced and that the jitter stayed inside its declared bound.
  RELAY_WAIT=""; RELAY_JITTER=""
  if [[ "$RELAY_OUT" =~ retrying\ once\ in\ ([0-9]+)s\ \+\ ([0-9]+)s\ jitter ]]; then
    RELAY_WAIT="${BASH_REMATCH[1]}"; RELAY_JITTER="${BASH_REMATCH[2]}"
  fi
}

relay_run() { # step-path, read_only, workflow_ref, gh_codes, event_name, headers, check_name
  local first_rc="" first_calls="" first_wait="" flags detail
  for flags in "${RELAY_SHELLS[@]}"; do
    _relay_once "$flags" "$@"
    # THE INVARIANT, asserted on every case rather than per-case so a future
    # case cannot forget it: the relay never reds. It runs on PR-attached
    # legs, so a non-zero exit is a failed check on the PR head and pins
    # mergeStateStatus at UNSTABLE — the defect VST-210 removes. Nothing this
    # step can hit justifies that, because it holds no statuses scope and can
    # only ever leave the gate stale, which the cron floor owns.
    # What was announced is what was slept, and the jitter stayed inside its
    # bound. Per shell, because the cross-shell comparison normalizes the
    # random half out — without this nothing would catch a jitter that escaped
    # its bound or a sleep that ignored the wait it printed.
    if [[ -n "$RELAY_SLEEPS" || -n "$RELAY_WAIT" ]]; then
      if [[ "$RELAY_WAIT" =~ ^[0-9]+$ && "$RELAY_JITTER" =~ ^[0-9]+$ ]] \
         && (( RELAY_JITTER < RELAY_JITTER_MAX )) \
         && [[ "$RELAY_SLEEPS" == "$(( RELAY_WAIT + RELAY_JITTER ))" ]]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        [bash %s] announced %ss + %ss jitter (bound %s), slept: [%s]\n' \
          "relay INVARIANT: the wait slept is the wait announced, and the jitter is bounded" \
          "$flags" "${RELAY_WAIT:-<none>}" "${RELAY_JITTER:-<none>}" "$RELAY_JITTER_MAX" "$RELAY_SLEEPS"
      fi
    fi
    if [[ "$RELAY_RC" != "0" ]]; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n        exit %s under [bash %s]\n        output: %s\n' \
        "relay INVARIANT: the relay never reds a PR head (case: ro=$2 ref='$3' codes='$4' event='${5:-pull_request_target}'${RELAY_DROP:+ UNSET=$RELAY_DROP})" \
        "$RELAY_RC" "$flags" "$RELAY_OUT"
    else
      PASS=$((PASS + 1))
    fi
    if [[ -z "$first_rc" ]]; then
      first_rc="$RELAY_RC"; first_calls="$RELAY_CALLS"; first_wait="$RELAY_WAIT"
    elif [[ "$RELAY_RC" != "$first_rc" || "$RELAY_CALLS" != "$first_calls" || "$RELAY_WAIT" != "$first_wait" ]]; then
      FAIL=$((FAIL + 1))
      # Three dimensions are compared, so the diagnostic must say WHICH one
      # moved: printing rc alone reports "rc=0 vs rc=0" for a divergence in
      # the calls or the wait and sends the reader looking at exit codes.
      detail=""
      if [[ "$RELAY_RC" != "$first_rc" ]]; then
        detail+="$(printf '\n        rc:           %s -> %s' "$first_rc" "$RELAY_RC")"
      fi
      if [[ "$RELAY_CALLS" != "$first_calls" ]]; then
        detail+="$(printf '\n        RELAY_CALLS:  [%s] -> [%s]' "$first_calls" "$RELAY_CALLS")"
      fi
      if [[ "$RELAY_WAIT" != "$first_wait" ]]; then
        detail+="$(printf '\n        wait:         [%s] -> [%s]' "$first_wait" "$RELAY_WAIT")"
      fi
      printf '  FAIL  %s\n        [bash %s] diverged from [bash %s]:%s\n' \
        "relay INVARIANT: behavior is identical under both runner shells (a pipefail-only difference is a latent red)" \
        "$flags" "${RELAY_SHELLS[0]}" "$detail"
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
  # Read from the step, not hardcoded: every wait assertion below is stated as
  # an exact clamp plus this bound, so a retuned jitter must move them with it.
  RELAY_JITTER_MAX="$(grep -oE '^jitter_max=[0-9]+' "$step" | head -n 1 | cut -d= -f2 || true)"
  if [[ -z "$RELAY_JITTER_MAX" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay: could not read jitter_max from the extracted step — every wait assertion below would be unbounded"
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
    "[$tag] relay2: a RENAMED consumer copy dispatches its own file (github.workflow_ref is read, not a hardcoded name — nothing to edit on rename)"

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
  # not send, and the difference is not cosmetic: reading x-ratelimit-reset
  # whenever retry-after is absent fires on every failure, produces an
  # hour-scale wait, trips the budget refusal, and leaves the relay making
  # exactly one attempt in production while a header-less fixture stays green.
  # So every fixture below carries a realistic header set, and the rate-limit
  # cases differ from the ordinary ones only where GitHub differs:
  # x-ratelimit-remaining, retry-after, a 429 status, or the secondary-limit
  # body. `now` is the STUBBED clock the step reads, so a reset epoch built
  # from it means exactly what the step computes.
  local rl_ok rl_spent now
  now="$FAKE_NOW"
  rl_ok="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 4947
X-Ratelimit-Reset: $(( now + 1400 ))
X-Ratelimit-Resource: core"
  rl_spent="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 0
X-Ratelimit-Resource: core"

  # No response at all — a transport failure, not an HTTP answer.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target
  assert_sleep 5 "$tag" "relay9: a failure with NO response at all retries quickly — the 60s floor belongs to the rate-limit shapes, not to every failure"
  assert_contains "$RELAY_OUT" "no HTTP response, gh exit 1" "[$tag] relay9: and the warning names the cause — this job's whole run log is that warning, so one naming no cause has nowhere to send its reader"

  # `timeout` kills the attempt: not an API answer at all, and the one cause
  # whose fix (the bound itself) is in this file rather than at GitHub.
  relay_run "$step" 0 "$ref" "124 0" pull_request_target
  assert_sleep 5 "$tag" "relay9b: a dispatch killed by its own per-attempt bound retries quickly"
  assert_contains "$RELAY_OUT" "the dispatch API did not respond within" "[$tag] relay9b: and is reported as a timeout, not as an HTTP answer"

  # SECONDARY limit, the shape that sends retry-after.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 77
$rl_ok"
  assert_sleep 77 "$tag" "relay10: retry-after is honored (secondary limit)"
  assert_contains "$RELAY_OUT" "HTTP 403, gh exit 1" "[$tag] relay10: and the warning names the status it backed off from"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 4000
$rl_ok"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay11: a window beyond the job's budget is NOT slept — retrying inside a window the server named is a guaranteed failure bought with a paid runner hold"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay11: and the second attempt is skipped entirely"
  assert_contains "$RELAY_OUT" "beyond this job's budget" "[$tag] relay11: the deferral names its reason"

  # PRIMARY limit: the window is SPENT (remaining 0) and a reset epoch says
  # when it refills. Exact against the stubbed clock.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent
X-Ratelimit-Reset: $(( now + 90 ))"
  assert_sleep 90 "$tag" "relay12: an EXHAUSTED window (remaining 0) honors its reset epoch"

  # The same reset epoch with the window HEALTHY is an ordinary header, not
  # rate-limit evidence.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
  assert_sleep 5 "$tag" "relay12b: a healthy window's reset epoch is not a wait instruction — a 5xx still takes the quick transient retry"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay12b: and the retry actually happens"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent
X-Ratelimit-Reset: 1000000000"
  assert_sleep 60 "$tag" "relay13: a reset epoch in the PAST falls to the floor, never a negative sleep"

  # An exhausted window whose reset header is missing or unusable: the
  # sanitizer must drop it and leave the floor, never pass it to sleep.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent"
  assert_sleep 60 "$tag" "relay13b: an exhausted window with NO reset header takes the floor — the derivation is skipped, not attempted against an empty value"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_spent
X-Ratelimit-Reset: soon"
  assert_sleep 60 "$tag" "relay13c: and a NON-NUMERIC reset is discarded before it can reach the arithmetic"

  # The clamp direction relay10 cannot reach.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 3
$rl_ok"
  assert_sleep 60 "$tag" "relay14: a sub-minute retry-after is raised to the 60s floor — obeying 3s verbatim retries back inside the limit"

  # SECONDARY limit without retry-after: the body is the only evidence left.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
$rl_ok
{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\"}"
  assert_sleep 60 "$tag" "relay15: a secondary-limit 403 that sends no retry-after is recognized from its body and takes the floor"

  # The status the secondary limit is documented to use, carrying neither a
  # retry-after nor a spent window: classified as a rate limit, or it would be
  # retried in 5s inside the window it was just refused by.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 429 Too Many Requests
$rl_ok"
  assert_sleep 60 "$tag" "relay15b: an HTTP 429 with a healthy window and no retry-after is still a rate limit and takes the floor"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
  assert_sleep 5 "$tag" "relay16: a 5xx blip retries QUICKLY — a minute of paid runner hold buys nothing against a transient"

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
  # is byte-for-byte a 403 with a healthy window and no retry-after, which a
  # ladder treating any 403 as a rate limit spends 60s on and then retries
  # into a certain failure, on every event, forever.
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
  assert_sleep 5 "$tag" "relay17: a non-numeric retry-after is discarded, not passed to sleep"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: soon
$rl_spent
X-Ratelimit-Reset: $(( now + 70 ))"
  assert_sleep 70 "$tag" "relay17b: a non-numeric retry-after is discarded but an EXHAUSTED window still governs"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
retry-after: 999999999
$rl_ok"
  assert_sleep 5 "$tag" "relay18: an out-of-range retry-after is discarded before it can overflow the arithmetic or reach sleep"

  # --- the check_run opt-in's self-amplification breaker ----------------
  # The relay's if: is a NEGATIVE list, so a repo that adds the check_run
  # trigger makes THIS workflow's own job completions relayable events — and
  # the relay holds no concurrency group to throttle what follows.
  relay_run "$step" 0 "$ref" "0" check_run "" "Request a gate convergence pass"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay23: a check_run naming the relay's OWN job dispatches NOTHING — the relay does not relay its own check runs"
  assert_contains "$RELAY_OUT" "::warning::" "[$tag] relay23: and says so, rather than absorbing the event silently"
  relay_run "$step" 0 "$ref" "0" check_run "" "Evaluate and write the review gate"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay23b: the write job's own check run is refused by the same guard"
  relay_run "$step" 0 "$ref" "0" check_run "" "CodeRabbit"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/review-gate-writer.yml/dispatches -f ref=main" \
    "[$tag] relay23c: a REVIEWER's check run still relays — the guard names this workflow's jobs, not every check run"

  # --- the invariant over the step's ENVIRONMENT ------------------------
  # The step runs under `set -u`, so its never-reds guarantee is only as good
  # as its env: block. Every binding sits in repo-owned YAML a consumer may
  # touch — the check_run opt-in uncomments trigger lines a few lines above
  # this job, and nothing stops a hand-edit reaching the block itself — so a
  # dropped line is a live class, not a hypothetical. Unbound, each of these
  # kills the step before it prints anything, on every PR-attached run,
  # permanently. relay_run asserts rc 0 under both shells for each.
  local dropped
  for dropped in EVENT_NAME WRITER_READ_ONLY WORKFLOW_REF GH_REPO DISPATCH_REF CHECK_NAME; do
    RELAY_DROP="$dropped"
    relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
$rl_ok"
    RELAY_DROP=""
  done
  # EVENT_NAME unbound is the one drop that changes nothing about the
  # dispatch: the step goes on to relay, with its second loop breaker unable
  # to confirm the leg. That is a deliberate choice (the job if: still guards
  # it) and it must be announced, or the breaker is silently off.
  RELAY_DROP=EVENT_NAME
  relay_run "$step" 0 "$ref" "0" pull_request_target
  assert_contains "$RELAY_OUT" "EVENT_NAME is unbound" "[$tag] relay24: an unbound EVENT_NAME warns that the step's loop breaker cannot verify the leg"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/review-gate-writer.yml/dispatches -f ref=main" \
    "[$tag] relay24: and the dispatch still happens — the job if: is the remaining guard, so this degrades loudly rather than closing"
  RELAY_DROP=""
  # And the three bindings the dispatch itself is built from must fail CLOSED
  # when unbound — degrading to green must not mean degrading to a dispatch
  # against a garbage target, and must not mean SIMULATING one either. Two of
  # them expand inside a command substitution, where `set -u` kills only the
  # subshell: gh is never reached, and a step that did not guard would sail on
  # to warn, sleep, "retry" and report an API answer it never received. So
  # each case asserts BOTH that nothing was dispatched and that nothing was
  # waited on, plus a warning that names the binding a maintainer must restore.
  local drop_case
  for drop_case in "WORKFLOW_REF|could not derive this workflow's file name|relay22: an unbound WORKFLOW_REF" \
                   "GH_REPO|env: block is missing GH_REPO|relay22b: an unbound GH_REPO" \
                   "DISPATCH_REF|env: block is missing DISPATCH_REF|relay22c: an unbound DISPATCH_REF"; do
    RELAY_DROP="${drop_case%%|*}"
    relay_run "$step" 0 "$ref" "1 0" pull_request_target
    assert_eq "$RELAY_CALLS" "" "[$tag] ${drop_case##*|} dispatches NOTHING — it lands on a warn-and-defer path, not on a garbage target"
    assert_eq "$RELAY_SLEEPS" "" "[$tag] ${drop_case##*|} waits for NOTHING — a guard that let the step reach the retry ladder would be reporting an API answer that never arrived"
    assert_contains "$RELAY_OUT" "$(cut -d'|' -f2 <<<"$drop_case")" "[$tag] ${drop_case##*|} names the binding in its warning — the whole output of this run is that one line"
    RELAY_DROP=""
  done
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
# the file it has no legitimate reason to differ in any copy.
# WHOLE-FILE drift, not just the relay step: a cross-copy tooth covering only
# the extracted step leaves a stale claim anywhere else in the adopted copy
# unchecked. Comments are compared out because the self-adoption header
# rewords them (vendored paths) — prose drift between the copies is therefore
# NOT machine-checkable here and stays a review concern; what IS checked is
# that every line of CODE matches once the vendored script path is
# normalized, which is the class that changes behavior.
# Scoped to SELF-adoption (IS_CATALOG, decided above). In the catalog the two
# files are the same artifact modulo the vendored script path, so any other
# code difference is drift. In a CONSUMER one difference is legitimate and
# indistinguishable from drift by diff: the check_run opt-in uncomments two
# trigger lines, which a code diff reads as added code. A consumer's copy is
# checked by validate-workflow.sh instead, which knows that opt-in. The
# relay-step byte-identity check below stays unconditional — that script
# carries no vendored path and no opt-in, so it is the same bytes in every
# copy.
if [[ "${#WORKFLOWS[@]}" -eq 2 && "$IS_CATALOG" -eq 0 ]]; then
  printf '  note  %s\n' "adopted copy may carry the check_run opt-in, which a code diff cannot tell from drift — whole-file drift not checked; the relay step's byte-identity still is"
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
    0) PASS=$((PASS + 1)); printf '  ok    %s\n' "relay: the template's and the adopted copy's relay steps are byte-identical (the step is the same bytes in every copy, so any drift is unintended)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the two copies' relay steps DIVERGED — a template edit was not mirrored into the adopted workflow"
       diff "${RELAY_STEPS[0]}" "${RELAY_STEPS[1]}" | head -20 ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the extracted relay steps could not be compared (diff read error) — drift is unproven, not disproven" ;;
  esac
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
