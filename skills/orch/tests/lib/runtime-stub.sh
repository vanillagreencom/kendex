# shellcheck shell=bash
# A stand-in for scripts/orch-runtime in the legacy suites: the succession a
# legacy script hands to the runtime is recorded, not run, a first launch's
# start is performed as the runtime's confirmed arm records it, and the
# watch's read of the runtime's open intents answers from a file the row
# plants. Sourced; defines fixture_runtime_stub and
# fixture_runtime_start_perform.
#
# fixture_runtime_start_perform DIR — write DIR/.orch-runtime-start, the
# performer a runtime stand-in hands a `start-controller` request to
# (`oversee launch`'s, U7d): it performs the start as the runtime's
# confirmed arm records it (runtime/src/ops/controller.rs §
# record_transfer_outcome, effects/transfer.rs § succeed) through the
# launcher's own adapter call and record writer: the request's controller
# opened as a window of the fleet session (ORCH_TMUX_SESSION, the launcher's
# export) in its cwd under overseer-run, the record written through
# lib/overseer-launch.sh's ol_record_write (the identity, the line, the next
# generation), the pane awaited until its foreground process is the harness
# (bounded by ORCH_TMUX_VERIFY_SECS, as the runtime's wait for the runner's
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
identity="$(jq -c '.controller | {harness, account, home, model, effort, cwd} + (if .class == null then {} else {class} end)' "$request")"
ol_record_read || OL_PRIOR=""
OL_OPEN_OUT="$("$SCRIPT_DIR/overseer-host" create --cwd "$cwd" --name overseer --session "${ORCH_TMUX_SESSION:?}" \
  --line "$(lane_single_quote "$SCRIPT_DIR/overseer-run") $line" 2>"$DEP_ERR")" \
  || { cat -- "$DEP_ERR" >&2; printf 'orch-runtime: fixture-create-failed\n' >&2; exit 1; }
ol_session_from_out
ol_record_write tmux "$OL_SESSION" "$OL_WINDOW" "$OL_SERVER" "$identity" "$line" \
  || { cat -- "$DEP_ERR" >&2; printf 'orch-runtime: fixture-record-unwritten\n' >&2; exit 1; }
deadline=$((SECONDS + ${ORCH_TMUX_VERIFY_SECS:-20}))
while (( SECONDS < deadline )); do
  running="$(tmux display-message -p -t "$OL_SESSION" '#{pane_current_command}' 2>/dev/null || true)"
  case "$running" in "" | sh | bash | dash | overseer-run) sleep 0.2 ;; *) break ;; esac
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
# script), and the start performer beside it. RECORD_DIR is where the stub
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
# holds, printing one keyed line.
fixture_runtime_stub() { # DIR [RECORD_DIR]
  local dir="$1" record="${2:-}"
  [[ "$dir" == "$TMP_ROOT/"* ]] || { echo 'runtime-stub: dir=not-private' >&2; return 1; }
  [[ ! -L "$dir/orch-runtime" ]] || rm -- "${dir:?}/orch-runtime"
  fixture_runtime_start_perform "$dir" || return 1
  cat > "$dir/orch-runtime" <<EOF
#!/usr/bin/env bash
set -euo pipefail
record='$record'
[[ -n "\$record" ]] || record="\${STUB_DIR:?}"
mkdir -p -- "\$record"
printf '%s\\n' "\$*" >> "\$record/runtime.args"
case "\${1:-} \${2:-}" in
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
  *) echo "orch-runtime: usage" >&2; exit 2 ;;
esac
EOF
  chmod +x "$dir/orch-runtime"
}
