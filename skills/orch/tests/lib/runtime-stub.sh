# shellcheck shell=bash
# A stand-in for scripts/orch-runtime in the shell suites, which run where no
# runtime is built: the succession a script hands to the runtime is
# recorded, not run, a first launch's start is performed as the runtime's
# confirmed arm records it, the watch's read of the runtime's open intents
# answers from a file the row plants, and a workflow fence's item-record
# read and write go through the store. Sourced; defines fixture_runtime_stub
# and fixture_runtime_start_perform.
#
# fixture_runtime_start_perform DIR — write DIR/.orch-runtime-start, the
# performer a runtime stand-in hands a first launch's `start-controller`
# request to: it performs the start as the runtime's
# confirmed arm records it (runtime/src/ops/controller.rs §
# record_transfer_outcome, effects/transfer.rs § succeed) through the
# launcher's own adapter call and record writer: the request's controller
# opened as a window of the fleet session (AGENT_RUNTIME_TMUX_SESSION, the launcher's
# export) in its cwd on its own line, the record written through
# lib/overseer-launch.sh's ol_record_write (the identity, the line, the next
# generation), the pane awaited until its foreground process is the harness
# (bounded by AGENT_RUNTIME_TMUX_VERIFY_SECS, as the runtime's wait for the runner's
# composer is), and the reply carrying the recorded outcome `confirmed` in
# the shape the launcher reads. It judges no screen and launches no watch:
# the runtime's rows hold those (tests/rust/controller.rs). The libs are the
# ones beside SCRIPT_DIR, the launcher's export; PROJECT_ROOT likewise.
fixture_runtime_start_perform() { # DIR
  local dir="$1"
  [[ "$dir" == "$TMP_ROOT/"* ]] || { echo 'runtime-stub: dir=not-private' >&2; return 1; }
  cat > "$dir/.orch-runtime-start" <<'EOF'
#!/usr/bin/env bash
# argv: REQUEST_FILE
set -euo pipefail
request="${1:?request file}"
# No apostrophe in a `:?` word: inside the expansion bash reads one as a
# quote and swallows the lines after it.
: "${SCRIPT_DIR:?the launching script exports its scripts directory}"
export PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DEP_ERR="$(mktemp)" || exit 1
trap 'rm -f -- "$DEP_ERR"' EXIT
export DEP_ERR
source "$SCRIPT_DIR/lib/lane-context.sh"
source "$SCRIPT_DIR/lib/lane-state.sh"
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/overseer-launch.sh"
cwd="$(jq -r '.controller.cwd' "$request")"
line="$(jq -r '.controller.launch_line' "$request")"
# The home the runtime's launch prepares, the account on these harnesses.
identity="$(jq -c '.controller | {harness, account, home: (.home // .account), model, effort, cwd}
  + (if .class == null then {} else {class} end)' "$request")"
ol_record_read || OL_PRIOR=""
opened="$("$SCRIPT_DIR/overseer-host" create --cwd "$cwd" --name overseer --session "${AGENT_RUNTIME_TMUX_SESSION:?}" \
  --line "$line" 2>"$DEP_ERR")" \
  || { cat -- "$DEP_ERR" >&2; printf 'orch-runtime: fixture-create-failed\n' >&2; exit 1; }
session="" window="" server=""
for word in $opened; do
  case "$word" in
    session=*) session="${word#session=}" ;;
    window=*) window="${word#window=}" ;;
    server=*) server="${word#server=}" ;;
  esac
done
ol_record_write tmux "$session" "$window" "$server" "$identity" "$line" \
  || { cat -- "$DEP_ERR" >&2; printf 'orch-runtime: fixture-record-unwritten\n' >&2; exit 1; }
deadline=$((SECONDS + ${AGENT_RUNTIME_TMUX_VERIFY_SECS:-20}))
while (( SECONDS < deadline )); do
  running="$(tmux display-message -p -t "$session" '#{pane_current_command}' 2>/dev/null || true)"
  case "$running" in "" | sh | bash | dash) sleep 0.2 ;; *) break ;; esac
done
jq -cn --argjson generation "$OL_GENERATION" '{protocol: "orch-runtime-v1", ok: true, result: {
  persisted: {kind: "fleet", report: {op: "start-controller", generation: ($generation - 1), effect: {Persisted: {intent: {id: "fixture-start"}}}}},
  effect: {kind: "fleet", report: {op: "record-outcome", recorded_now: true, generation: $generation,
    intent: {id: "fixture-start", outcome: "confirmed", observation: {note: "successor-confirmed"}}}}}}'
EOF
  chmod +x "$dir/.orch-runtime-start"
}

# fixture_runtime_stub DIR [RECORD_DIR] — write DIR/orch-runtime, replacing a
# link to the real wrapper there (a mutant scripts directory links every
# script), the start performer beside it, and beside that the walk's
# stand-in a first launch asks for its controller: `successor --fleet
# --cwd DIR` answered by the shell walk beside the launcher
# (lib/overseer-launch.sh § ol_walk) in the verb's reply shape, and `state
# exists|init --fleet` and `state get --fleet POINTER` answered through the
# store beside the stub over the oversee state. RECORD_DIR is where the stub
# records and reads its files; left out, the stub takes $STUB_DIR from its
# environment at each call, the watch harness's per-case directory. Every
# call appends its argv to RECORD_DIR/runtime.args. `op --fleet --request
# FILE` hands a `start-controller` request to the performer above and
# records nothing of it; any other request is copied to
# RECORD_DIR/runtime.request (the succession's, the marker a row awaits) and
# answers the reply a started transfer gets, `transfer-started` with the intent
# RECORD_DIR/runtime.intent names (a fixed id when none), unless
# RECORD_DIR/runtime.refuse names a refusal key: then it prints that keyed
# line on stderr with a refused reply and exits 1. `state inspect --fleet`
# answers with the open intents in RECORD_DIR/runtime.open-intents (`[]`
# when absent), or exits with the status RECORD_DIR/runtime.inspect-rc
# holds, printing one keyed line. `accounts pick`, the account judge the
# succession walk and the mark judge ask, answers the reply planted under
# RECORD_DIR/runtime.picks for the question asked, keyed
# `<harness>-<trigger>-<excluded account's name>` (the trigger
# `--min-headroom-pct`'s word, the name `--exclude-lane`'s basename
# without its dot, `none` where the question names none), else the reply
# at RECORD_DIR/runtime.pick-lane for a named pick (`--lane`) and at
# RECORD_DIR/runtime.pick for the chooser where a row plants one (each a
# reply the verb printed on a fixture, never one written by hand: the
# record's spelling is what the caller's reading is proven on); where none
# is planted and RECORD_DIR/runtime.picks-only stands, the question is
# refused `fixture-pick-unplanted`, else the shell judge beside the stub
# (DIR/lanes, else the shipped `lanes`) is asked the same question through
# its `pick`, its answer wrapped as the verb's reply, the exit by number and
# the record; `--fleet` and `--replaces` are the verb's words alone and are
# dropped. `state get --item KEY [POINTER]` and
# `state set --item KEY POINTER VALUE` answer through the store beside the
# stub (DIR/workflow-state, else the shipped one), the pointer's tokens
# joined as the store's dotted field, so the store's `set` judges VALUE as
# the runtime's does; the get's reply carries the pointer and its value.
fixture_runtime_stub() { # DIR [RECORD_DIR]
  local dir="$1" record="${2:-}" lanes store
  [[ "$dir" == "$TMP_ROOT/"* ]] || { echo 'runtime-stub: dir=not-private' >&2; return 1; }
  [[ ! -L "$dir/orch-runtime" ]] || rm -- "${dir:?}/orch-runtime"
  fixture_runtime_start_perform "$dir" || return 1
  cat > "$dir/.orch-runtime-successor" <<'EOF'
#!/usr/bin/env bash
# argv: the successor verb's words, a first controller's alone.
set -euo pipefail
cwd="" predecessor="" handoff=tmp/handoffs/OVERSEER-HANDOFF.md
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) cwd="$2"; shift ;;
    --predecessor) predecessor="$2"; shift ;;
    --handoff) handoff="$2"; shift ;;
  esac
  shift
done
[[ -z "$predecessor" ]] || { printf 'orch-runtime: fixture-unexpected predecessor=%s\n' "$predecessor" >&2; exit 2; }
: "${SCRIPT_DIR:?the launching script exports its scripts directory}"
DEP_ERR="$(mktemp)" || exit 1
trap 'rm -f -- "${DEP_ERR:?}"' EXIT
export DEP_ERR
source "$SCRIPT_DIR/lib/lane-context.sh"
source "$SCRIPT_DIR/lib/lane-state.sh"
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/overseer-launch.sh"
ol_preference_entries "$(ol_preference)" \
  || { printf 'orch-runtime: preference-invalid entry=%s\n' "$OL_BAD_ENTRY" >&2; exit 1; }
rc=0
ol_walk "${AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT:-5}" "" "${OL_ENTRIES[@]}" 2>/dev/null || rc=$?
case "$rc" in
  0) ol_brief "$OL_HARNESS" "$handoff"
     jq -cn --arg harness "$OL_HARNESS" --arg account "$OL_LANE_DIR" --arg model "$OL_MODEL" \
       --arg effort "$OL_EFFORT" --arg class "${OL_MODEL_CLASS:-}" --arg pick "$OL_PICK_MODEL" \
       --arg entry "$OL_CHOSEN" --arg cwd "$cwd" --arg brief "$OL_BRIEF" --argjson entries "$OL_NAMED" '
       {harness: $harness, account: $account, model: $model, effort: $effort, class: $class} as $chosen
       | {protocol: "orch-runtime-v1", ok: true, result: {
           walk: {answer: "lane", entries: $entries, chosen: ($chosen + {entry: $entry, pick_model: $pick}),
             skipped: [], walled: 0, unmeasured: 0, deprecated: []},
           successor: ($chosen + {cwd: $cwd, permission: "bypass"}
             | with_entries(select(.value != ""))),
           brief: $brief, expected: null}}' ;;
  3) jq -cn --argjson entries "$OL_NAMED" --argjson walled "$OL_WALKED_WALLED" \
       --argjson unmeasured "$OL_WALKED_UNMEASURED" '{protocol: "orch-runtime-v1", ok: true, result: {
       walk: {answer: "none", entries: $entries, chosen: null, skipped: [], walled: $walled,
         unmeasured: $unmeasured, deprecated: []}, successor: null, brief: null, expected: null}}' ;;
  *) printf 'orch-runtime: account-unjudged cause=%s\n' "${OL_REASON:-walk-failed}" >&2; exit 1 ;;
esac
EOF
  chmod +x "$dir/.orch-runtime-successor"
  lanes="$dir/lanes"
  [[ -e "$lanes" ]] || lanes="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/lanes"
  store="$dir/workflow-state"
  [[ -e "$store" ]] || store="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/workflow-state"
  cat > "$dir/orch-runtime" <<EOF
#!/usr/bin/env bash
set -euo pipefail
record='$record'
[[ -n "\$record" ]] || record="\${STUB_DIR:?}"
mkdir -p -- "\$record"
printf '%s\\n' "\$*" >> "\$record/runtime.args"
case "\${1:-} \${2:-}" in
  "accounts pick")
    planted="\$record/runtime.pick"
    case " \$* " in *" --lane "*) planted="\$record/runtime.pick-lane" ;; esac
    harness="" trigger="" excluded=none take=""
    for arg in "\$@"; do
      case "\$take" in
        harness) harness="\$arg" ;;
        trigger) trigger="\$arg" ;;
        excluded) excluded="\${arg##*/}"; excluded="\${excluded#.}" ;;
      esac
      take=""
      case "\$arg" in
        --harness) take=harness ;;
        --min-headroom-pct) take=trigger ;;
        --exclude-lane) take=excluded ;;
      esac
    done
    keyed="\$record/runtime.picks/\$harness-\$trigger-\$excluded"
    if [[ -f "\$keyed" ]]; then cat -- "\$keyed"; exit 0; fi
    if [[ -f "\$planted" ]]; then cat -- "\$planted"; exit 0; fi
    if [[ -e "\$record/runtime.picks-only" ]]; then
      printf 'orch-runtime: fixture-pick-unplanted key=%s\\n' "\$harness-\$trigger-\$excluded" >&2
      exit 2
    fi
    args=() skip=""
    for arg in "\$@"; do
      if [[ -n "\$skip" ]]; then skip=""; continue; fi
      case "\$arg" in
        --replaces) skip="\$arg" ;;
        accounts | pick | --fleet) ;;
        *) args+=("\$arg") ;;
      esac
    done
    rc=0
    out="\$('$lanes' pick \${args[@]+"\${args[@]}"} --json)" || rc=\$?
    jq -cn --argjson rc "\$rc" --arg out "\$out" '{protocol: "orch-runtime-v1", ok: true, result: {
      answer: ({"0": "lane", "3": "walled", "4": "no-record", "5": "unmeasured", "7": "cloud-repo-unset"}[\$rc | tostring] // "unjudged"),
      exit: \$rc, record: (try (\$out | fromjson) catch null)}}' ;;
  "op --fleet")
    [[ "\${3:-}" == --request && -n "\${4:-}" ]] || { echo 'orch-runtime: usage' >&2; exit 2; }
    # A first launch's start is performed, never recorded: runtime.request is
    # the succession's, which a row awaits as the marker of the recovery's
    # dispatch.
    [[ "\$(jq -r '.op // empty' "\$4")" != start-controller ]] || exec "\$(cd -- "\$(dirname -- "\$0")" && pwd -P)/.orch-runtime-start" "\$4"
    cp -- "\$4" "\$record/runtime.request"
    git rev-parse HEAD > "\$record/runtime.head" 2>/dev/null || printf 'no-checkout\\n' > "\$record/runtime.head"
    if [[ -f "\$record/runtime.refuse" ]]; then
      key="\$(cat "\$record/runtime.refuse")"
      printf 'orch-runtime: %s path=fixture\\n' "\$key" >&2
      printf '{"protocol":"orch-runtime-v1","ok":false,"refusal":{"key":"%s"}}\\n' "\$key"
      exit 1
    fi
    intent="request-transfer:overseer:1:1-1"
    [[ ! -f "\$record/runtime.intent" ]] || intent="\$(cat "\$record/runtime.intent")"
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{"persisted":{},"effect":{"started":"transfer-started","intent":"%s","job":"runner=fixture"}}}\\n' "\$intent" ;;
  "state inspect")
    if [[ -f "\$record/runtime.inspect-rc" ]]; then
      echo 'orch-runtime: record-missing path=fixture' >&2
      exit "\$(cat "\$record/runtime.inspect-rc")"
    fi
    open='[]'
    [[ ! -f "\$record/runtime.open-intents" ]] || open="\$(cat "\$record/runtime.open-intents")"
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{"kind":"fleet","open_intents":%s}}\\n' "\$open" ;;
  "successor --fleet")
    exec "\$(cd -- "\$(dirname -- "\$0")" && pwd -P)/.orch-runtime-successor" "\$@" ;;
  "state exists")
    exists=false
    ! '$store' exists oversee >/dev/null 2>&1 || exists=true
    jq -cn --arg path "\$('$store' path oversee)" --argjson exists "\$exists" \\
      '{protocol: "orch-runtime-v1", ok: true, result: {issue_id: "oversee", path: \$path, exists: \$exists}}' ;;
  "state init")
    '$store' init oversee >/dev/null
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{}}\\n' ;;
  "state get")
    if [[ "\${3:-}" == --fleet ]]; then
      jq -c --arg pointer "\${4:-}" '{protocol: "orch-runtime-v1", ok: true, result: {pointer: \$pointer,
        value: getpath(\$pointer | split("/")[1:])}}' "\$('$store' path oversee)"
      exit 0
    fi
    [[ "\${3:-}" == --item && -n "\${4:-}" && \$# -le 5 ]] || { echo 'orch-runtime: usage' >&2; exit 2; }
    doc="\$('$store' get "\$4")"
    jq -c --arg pointer "\${5:-}" '{protocol: "orch-runtime-v1", ok: true, result: {pointer: \$pointer,
      value: getpath(\$pointer | split("/")[1:] | map(if test("^[0-9]+\$") then tonumber else . end))}}' <<<"\$doc" ;;
  "state set")
    [[ "\${3:-}" == --item && -n "\${4:-}" && "\${5:-}" == /?* && \$# -eq 6 ]] || { echo 'orch-runtime: usage' >&2; exit 2; }
    field="\${5#/}"
    '$store' set "\$4" "\${field//\//.}" "\$6" >/dev/null
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{}}\\n' ;;
  *) echo "orch-runtime: usage" >&2; exit 2 ;;
esac
EOF
  chmod +x "$dir/orch-runtime"
}
