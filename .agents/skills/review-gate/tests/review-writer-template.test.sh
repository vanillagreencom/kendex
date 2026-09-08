#!/usr/bin/env bash
# Assertions on the review-gate WORKFLOW YAML — split out of
# review-writer.test.sh, which is the review-writer.sh engine suite.
#
# What the template MEANS is read by one instrument: the relay step's SCRIPT,
# extracted from the YAML and EXECUTED against a gh stub — not a pin, the real
# shell. Re-derivation of the rest of the template is deliberately
# unasserted here. What the suite ALSO holds is template/adopted-copy
# EQUALITY: the whole-file drift check (self-adoption only) and the relay
# step's byte-identity across copies.
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
# head, which would block the PR.
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

RELAY_JITTER_MAX=0

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
# every dispatch row fails there and only there. Pass-through, not a real
# timer, recording the bound it was handed: the stub answers instantly, and
# the timeout-killed case is modelled by GH_CODES handing back 124, which this
# propagates like the real command does.
cat > "$RELAY_BIN/timeout" <<'RELAY_TIMEOUT'
#!/usr/bin/env bash
echo "$1" >> "$TIMEOUT_LOG"
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
TIMEOUT_LOG="$TMP_ROOT/relay-timeout.log"

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
  : > "$RELAY_LOG"; : > "$SLEEP_LOG"; : > "$TIMEOUT_LOG"
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
    GH_LOG="$RELAY_LOG" SLEEP_LOG="$SLEEP_LOG" TIMEOUT_LOG="$TIMEOUT_LOG" GH_CODES="$5" GH_HEADERS="${7:-}" \
    FAKE_NOW="$FAKE_NOW" PATH="$RELAY_BIN:$PATH" "${keep[@]}" \
    bash $1 "$2" 2>&1)"
  RELAY_RC=$?
  set -e
  RELAY_CALLS="$(cat "$RELAY_LOG")"
  RELAY_SLEEPS="$(cat "$SLEEP_LOG")"
  RELAY_BOUNDS="$(paste -sd, - < "$TIMEOUT_LOG")"
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
    # mergeStateStatus at UNSTABLE. Nothing this
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

# The extracted steps, and the copy each one CAME FROM. Two arrays because
# RELAY_STEPS only grows on a successful extraction while WORKFLOW_LABELS is
# populated for every discovered copy — so indexing the labels by a step's
# position would, the moment one extraction failed, print the surviving copy's
# results under the failed copy's name, in the log a maintainer is reading to
# diagnose that failure.
RELAY_STEPS=()
RELAY_STEP_LABELS=()
relay_extract() { # file, label — appends the step and its label, on success
  local wf="$1" tag="$2" step="$TMP_ROOT/relay-step-${#RELAY_STEPS[@]}.sh"
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
    RELAY_STEP_LABELS+=("$tag")
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay: the step script extracted from the workflow (non-empty, dispatches)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay: could NOT extract the step script — the battery and the cross-copy identity check below both lose this copy"
  fi
}

# The responses a fixture answers with. EVERY GitHub response — 404s, 422s
# and 5xx included — carries the x-ratelimit headers, so every fixture below
# does, and the rate-limit shapes differ from the ordinary ones only where
# GitHub differs: x-ratelimit-remaining, retry-after, a 429 status, or the
# secondary-limit body. `FAKE_NOW` is the stubbed clock the step reads, so a
# reset epoch built from it means exactly what the step computes.
RL_OK="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 4947
X-Ratelimit-Reset: $(( FAKE_NOW + 1400 ))
X-Ratelimit-Resource: core"
RL_SPENT="X-Ratelimit-Limit: 5000
X-Ratelimit-Remaining: 0
X-Ratelimit-Resource: core"
headers_of() { # NAME -> the scripted response; `none` is a transport failure
  case "$1" in
    none) ;;
    403-retry-77)        printf '%s\n' "HTTP/2.0 403 Forbidden" "retry-after: 77" "$RL_OK" ;;
    403-retry-4000)      printf '%s\n' "HTTP/2.0 403 Forbidden" "retry-after: 4000" "$RL_OK" ;;
    403-retry-3)         printf '%s\n' "HTTP/2.0 403 Forbidden" "retry-after: 3" "$RL_OK" ;;
    403-spent-reset+90)  printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_SPENT" "X-Ratelimit-Reset: $(( FAKE_NOW + 90 ))" ;;
    403-spent-reset-past) printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_SPENT" "X-Ratelimit-Reset: 1000000000" ;;
    403-spent-no-reset)  printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_SPENT" ;;
    403-spent-reset-soon) printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_SPENT" "X-Ratelimit-Reset: soon" ;;
    403-spent-reset-long) printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_SPENT" "X-Ratelimit-Reset: 17000000000" ;;
    403-retry-soon-spent-reset+70) printf '%s\n' "HTTP/2.0 403 Forbidden" "retry-after: soon" "$RL_SPENT" "X-Ratelimit-Reset: $(( FAKE_NOW + 70 ))" ;;
    403-secondary-body)  printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_OK" '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}' ;;
    403-permissions-body) printf '%s\n' "HTTP/2.0 403 Forbidden" "$RL_OK" '{"message":"Resource not accessible by integration"}' ;;
    429)                 printf '%s\n' "HTTP/2.0 429 Too Many Requests" "$RL_OK" ;;
    502)                 printf '%s\n' "HTTP/2.0 502 Bad Gateway" "$RL_OK" ;;
    502-retry-soon)      printf '%s\n' "HTTP/2.0 502 Bad Gateway" "retry-after: soon" "$RL_OK" ;;
    502-retry-huge)      printf '%s\n' "HTTP/2.0 502 Bad Gateway" "retry-after: 999999999" "$RL_OK" ;;
    404)                 printf '%s\n' "HTTP/2.0 404 Not Found" "$RL_OK" ;;
    422)                 printf '%s\n' "HTTP/2.0 422 Unprocessable Entity" "$RL_OK" ;;
    *) printf 'headers_of: no fixture named %s\n' "$1" >&2; exit 1 ;;
  esac
}
ref_of() { # NAME -> the github.workflow_ref the step derives its file from
  case "$1" in
    main)    printf '%s' "o/r/.github/workflows/review-gate-writer.yml@refs/heads/main" ;;
    renamed) printf '%s' "o/r/.github/workflows/gate.yml@refs/heads/trunk" ;;
    empty)   ;;
    *) printf 'ref_of: no ref named %s\n' "$1" >&2; exit 1 ;;
  esac
}

# relay_observe EXPECT — prints the run's value of every `name=` field EXPECT
# names, in EXPECT's order, so a row fails on the field it names:
#   rc       the step's exit status (the invariant asserts 0 on every run
#            under both shells; the row pins it where the reader looks)
#   calls    every gh call, in order, as `dispatch:<file>` for the exact
#            dispatch the step is meant to make and `other:<argv>` for
#            anything else, or none
#   wait     the clamped wait the step announced (the jitter is asserted
#            against the recorded sleep per run in relay_run), or none
#   sleeps   sleep calls the stub recorded
#   bound    the per-attempt bound the timeout shim was handed, one per
#            dispatch in order, or none: the shim passes through, so the
#            bound is proven here and the timeout-killed shape is modelled
#            by an exit of 124
#   note     the annotation level(s) the step emitted: warning, error,
#            warning+error, or none
#   says~<t> whether the output carries <t>, `+` read as a space: the one
#            phrase that tells two shapes with the same wait and calls apart
relay_observe() {
  local got="" token name value line
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RELAY_RC" ;;
      calls)
        value=""
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          case "$line" in
            "gh api -i -X POST repos/o/r/actions/workflows/"*"/dispatches -f ref=main")
              line="${line#gh api -i -X POST repos/o/r/actions/workflows/}"
              value="$value,dispatch:${line%/dispatches -f ref=main}" ;;
            *) value="$value,other:$line" ;;
          esac
        done <<<"$RELAY_CALLS"
        value="${value#,}"; value="${value:-none}" ;;
      wait) value="${RELAY_WAIT:-none}" ;;
      sleeps) value="$(grep -c . <<<"$RELAY_SLEEPS" || true)" ;;
      bound) value="${RELAY_BOUNDS:-none}" ;;
      note)
        value=""
        grep -qF '::warning::' <<<"$RELAY_OUT" && value="warning"
        grep -qF '::error::' <<<"$RELAY_OUT" && value="${value:+$value+}error"
        value="${value:-none}" ;;
      says~*)
        line="${name#says~}"; line="${line//+/ }"
        value="$(grep -qF -- "$line" <<<"$RELAY_OUT" && echo true || echo false)" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# relay_row ROW — one run under both shells, one assertion on the fields the
# row names: `label|read_only|ref|codes|event|headers|check_name|drop|expect`.
# `codes` is gh's exit status per attempt; an empty event is the PR-attached
# leg; `drop` names one env: binding left unset for the run.
RELAY_STEP=""
RELAY_TAG=""
relay_row() {
  local label ro ref codes event headers check drop expect
  IFS='|' read -r label ro ref codes event headers check drop expect <<<"$1"
  [[ -n "$expect" ]] || { printf 'relay_row: a row with no expect asserts nothing: %s\n' "$1" >&2; exit 1; }
  # Resolved into locals first: an unknown fixture name exits inside a
  # command substitution, which `set -e` ignores in an argument position, and
  # the row would run against empty headers and could pass as the
  # no-response shape.
  local resolved_ref resolved_headers
  resolved_ref="$(ref_of "$ref")"
  resolved_headers="$(headers_of "$headers")"
  RELAY_DROP="$drop"
  relay_run "$RELAY_STEP" "$ro" "$resolved_ref" "$codes" "$event" "$resolved_headers" "$check"
  RELAY_DROP=""
  assert_eq "$(relay_observe "$expect")" "$expect" "[$RELAY_TAG] $label"
}

relay_battery() { # step script, label
  RELAY_STEP="$1"; RELAY_TAG="$2"
  # Read from the step, not hardcoded: every wait a row pins is an exact
  # clamp plus this bound, so a retuned jitter must move them with it.
  RELAY_JITTER_MAX="$(grep -oE '^jitter_max=[0-9]+' "$1" | head -n 1 | cut -d= -f2 || true)"
  if [[ -z "$RELAY_JITTER_MAX" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$2" "relay: could not read jitter_max from the extracted step — every wait assertion below would be unbounded"
    return
  fi

  # The dispatch, and the three guards in front of it: a renamed consumer
  # copy dispatches its own file (github.workflow_ref is read, never a
  # hardcoded name), a read-only token is a green no-op the cron floor
  # converges, an underivable ref dispatches nothing rather than a garbage
  # path, and the step's own loop breaker refuses the converge legs even if
  # the job if: was mis-edited. A double failure exits GREEN with a warning
  # and never an error: the relay holds no statuses scope, so it can only
  # leave the gate stale, which the cron floor owns; a red would pin the PR
  # at UNSTABLE, the defect the split removed.
  for row in \
    "an ordinary PR-attached leg dispatches THIS workflow's file on the default branch, exactly once, under the per-attempt bound|0|main|0||none|||rc=0 calls=dispatch:review-gate-writer.yml bound=60 sleeps=0 note=none" \
    "a RENAMED consumer copy dispatches its own file|0|renamed|0||none|||rc=0 calls=dispatch:gate.yml sleeps=0 note=none" \
    "a read-only token (fork pull_request_review) is a green no-op that dispatches nothing|1|main|0||none|||rc=0 calls=none sleeps=0 note=none" \
    "an underivable workflow_ref dispatches NOTHING and warns, never a garbage path|0|empty|0||none|||rc=0 calls=none sleeps=0 note=warning says~could+not+derive+this+workflow's+file+name=true" \
    "a transient dispatch failure is retried once and succeeds: exactly two attempts|0|main|1 0||none|||rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 note=warning" \
    "two failed dispatches stop after two attempts and exit GREEN with a warning, never an error|0|main|1 1||none|||rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 note=warning says~after+two+attempts=true" \
    "the workflow_dispatch leg is refused by the step's own loop breaker, and says so|0|main|0|workflow_dispatch|none|||rc=0 calls=none sleeps=0 note=warning says~CONVERGE+leg=true" \
    "the schedule leg is refused by the same guard|0|main|0|schedule|none|||rc=0 calls=none sleeps=0 note=warning says~CONVERGE+leg=true"
  do relay_row "$row"; done

  # The retry ladder against real response shapes. A failure with no answer
  # or a 5xx retries quickly: the 60s floor belongs to the rate-limit shapes.
  # retry-after is honored and clamped to the floor; a window beyond the
  # job's budget is not slept, since retrying inside a window the server
  # named is a guaranteed failure bought with a paid runner hold. An
  # exhausted window (remaining 0) honors its reset epoch, falls to the floor
  # on a past, missing or non-numeric reset, and a healthy window's reset is
  # not a wait instruction. A secondary limit without retry-after is read
  # from its body, and a 429 is a rate limit on its status alone. Permanent
  # answers — 404, 422, and the permissions 403 that is byte-for-byte a 403
  # with a healthy window — are not slept on and not retried. Non-numeric or
  # out-of-range values are discarded before they can reach sleep or the
  # arithmetic.
  for row in \
    "a failure with NO response retries in 5s and names the cause|0|main|1 0||none|||rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 says~no+HTTP+response,+gh+exit+1=true" \
    "a dispatch killed by its own per-attempt bound retries in 5s and is reported as a timeout|0|main|124 0||none|||rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml bound=60,60 wait=5 sleeps=1 says~did+not+respond+within=true" \
    "retry-after is honored (secondary limit) and the warning names the status|0|main|1 0||403-retry-77|||rc=0 wait=77 sleeps=1 says~HTTP+403,+gh+exit+1=true" \
    "a window beyond the job's budget is NOT slept and the second attempt is skipped|0|main|1 0||403-retry-4000|||rc=0 calls=dispatch:review-gate-writer.yml wait=none sleeps=0 note=warning says~beyond+this+job's+budget=true" \
    "an EXHAUSTED window honors its reset epoch|0|main|1 0||403-spent-reset+90|||rc=0 wait=90 sleeps=1" \
    "a healthy window's reset epoch is not a wait instruction: a 5xx takes the quick retry|0|main|1 0||502|||rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 says~HTTP+502,+gh+exit+1=true" \
    "a reset epoch in the PAST falls to the floor, never a negative sleep|0|main|1 0||403-spent-reset-past|||rc=0 wait=60 sleeps=1" \
    "an exhausted window with NO reset header takes the floor|0|main|1 0||403-spent-no-reset|||rc=0 wait=60 sleeps=1" \
    "a NON-NUMERIC reset is discarded before the arithmetic|0|main|1 0||403-spent-reset-soon|||rc=0 wait=60 sleeps=1" \
    "an over-long reset epoch is discarded before the arithmetic|0|main|1 0||403-spent-reset-long|||rc=0 wait=60 sleeps=1" \
    "a sub-minute retry-after is raised to the 60s floor|0|main|1 0||403-retry-3|||rc=0 wait=60 sleeps=1" \
    "a secondary-limit 403 with no retry-after is recognized from its body and takes the floor|0|main|1 0||403-secondary-body|||rc=0 wait=60 sleeps=1" \
    "an HTTP 429 with a healthy window and no retry-after is a rate limit and takes the floor|0|main|1 0||429|||rc=0 wait=60 sleeps=1" \
    "a 404 is a settled answer: no sleep, one attempt, the permanent status named|0|main|1 0||404|||rc=0 calls=dispatch:review-gate-writer.yml wait=none sleeps=0 note=warning says~refused+permanently+(HTTP+404)=true" \
    "a 422 (bad ref) is not slept on either|0|main|1 0||422|||rc=0 calls=dispatch:review-gate-writer.yml wait=none sleeps=0 note=warning" \
    "a PERMISSIONS 403 is permanent: no wait, one attempt, the likely cause named|0|main|1 0||403-permissions-body|||rc=0 calls=dispatch:review-gate-writer.yml wait=none sleeps=0 note=warning says~actions:write=true" \
    "a non-numeric retry-after is discarded, not passed to sleep|0|main|1 0||502-retry-soon|||rc=0 wait=5 sleeps=1" \
    "a non-numeric retry-after is discarded but an EXHAUSTED window still governs|0|main|1 0||403-retry-soon-spent-reset+70|||rc=0 wait=70 sleeps=1" \
    "an out-of-range retry-after is discarded before it can overflow the arithmetic|0|main|1 0||502-retry-huge|||rc=0 wait=5 sleeps=1"
  do relay_row "$row"; done

  # The check_run opt-in's self-amplification breaker: the relay's if: is a
  # negative list, so with check_run enabled this workflow's own job
  # completions are relayable events, and the relay holds no concurrency
  # group. Its own jobs are refused by name; a reviewer's check run relays.
  for row in \
    "a check_run naming the relay's OWN job dispatches nothing, and says so|0|main|0|check_run|none|Request a gate convergence pass||rc=0 calls=none sleeps=0 note=warning" \
    "the write job's own check run is refused by the same guard|0|main|0|check_run|none|Evaluate and write the review gate||rc=0 calls=none sleeps=0 note=warning" \
    "a REVIEWER's check run still relays|0|main|0|check_run|none|CodeRabbit||rc=0 calls=dispatch:review-gate-writer.yml sleeps=0 note=none"
  do relay_row "$row"; done

  # The invariant over the step's ENVIRONMENT. The step runs under `set -u`,
  # and every binding sits in repo-owned YAML a consumer may hand-edit, so a
  # dropped line is a live class: unbound, each would kill the step before it
  # prints anything, on every PR-attached run, permanently. An unbound
  # EVENT_NAME is the one drop that changes nothing about the dispatch — the
  # job if: still guards the leg — and it must be announced or the breaker is
  # silently off. The three bindings the dispatch is built from fail CLOSED:
  # two expand inside a command substitution, where `set -u` kills only the
  # subshell, so a step that did not guard would sail on to warn, sleep,
  # "retry" and report an API answer it never received; each row pins that
  # nothing was dispatched, nothing was waited on, and the binding is named.
  for row in \
    "an unbound EVENT_NAME warns that the loop breaker cannot verify the leg, and the dispatch still happens|0|main|0||none||EVENT_NAME|rc=0 calls=dispatch:review-gate-writer.yml sleeps=0 note=warning says~EVENT_NAME+is+unbound=true" \
    "an unbound EVENT_NAME on the retry path still retries|0|main|1 0||502||EVENT_NAME|rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 note=warning" \
    "an unbound WRITER_READ_ONLY reads as not read-only|0|main|1 0||502||WRITER_READ_ONLY|rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 note=warning" \
    "an unbound CHECK_NAME is no check_run of our own|0|main|1 0||502||CHECK_NAME|rc=0 calls=dispatch:review-gate-writer.yml,dispatch:review-gate-writer.yml wait=5 sleeps=1 note=warning" \
    "an unbound WORKFLOW_REF dispatches nothing, waits for nothing, and is named|0|main|1 0||none||WORKFLOW_REF|rc=0 calls=none wait=none sleeps=0 note=warning says~could+not+derive+this+workflow's+file+name=true" \
    "an unbound GH_REPO dispatches nothing, waits for nothing, and is named|0|main|1 0||none||GH_REPO|rc=0 calls=none wait=none sleeps=0 note=warning says~env:+block+is+missing+GH_REPO=true" \
    "an unbound DISPATCH_REF dispatches nothing, waits for nothing, and is named|0|main|1 0||none||DISPATCH_REF|rc=0 calls=none wait=none sleeps=0 note=warning says~env:+block+is+missing+DISPATCH_REF=true"
  do relay_row "$row"; done
}

echo "=== relay step behavior (request-converge, VST-210) ==="
for i in "${!WORKFLOWS[@]}"; do
  relay_extract "${WORKFLOWS[$i]}" "${WORKFLOW_LABELS[$i]}"
done

# The battery runs ONCE, against the first copy that EXTRACTED — which is the
# template unless its extraction failed, so the label travels with the step
# rather than being re-derived from a position. Every row runs under both
# entries of RELAY_SHELLS, and the
# byte-identity check below proves the other copy's step is the SAME BYTES —
# so a second battery would execute one script twice and call the agreement a
# result. Identity is the stronger claim of the two, and it is the one that
# must not be skipped: if extraction lost a copy, relay_extract has already
# reddened above.
if [[ "${#RELAY_STEPS[@]}" -ge 1 ]]; then
  relay_battery "${RELAY_STEPS[0]}" "${RELAY_STEP_LABELS[0]}"
fi

# The battery above proves one copy's step behaves; this proves the other is
# the SAME step, which is what carries that behavior across to it. Behavior
# equivalence under the cases we thought to write is weaker than byte-identity
# for a script that exists in two hand-maintained places — a divergence the
# cases do not happen to probe would otherwise ship.
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
# trigger lines, which a code diff reads as included code. A consumer's copy is
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
