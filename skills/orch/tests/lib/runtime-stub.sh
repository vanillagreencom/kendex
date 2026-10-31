# shellcheck shell=bash
# A stand-in for scripts/orch-runtime in the legacy suites: the succession a
# legacy script hands to the runtime is recorded, not run, and the watch's
# read of the runtime's open intents answers from a file the row plants.
# Sourced; defines fixture_runtime_stub.
#
# fixture_runtime_stub DIR [RECORD_DIR] — write DIR/orch-runtime, replacing a
# link to the real wrapper there (a mutant scripts directory links every
# script). RECORD_DIR is where the stub records and reads its files; left
# out, the stub takes $STUB_DIR from its environment at each call, the watch
# harness's per-case directory. Every call
# appends its argv to RECORD_DIR/runtime.args. `op --fleet --request FILE`
# copies FILE to RECORD_DIR/runtime.request and answers the reply a started
# transfer gets, `transfer-started` with the intent RECORD_DIR/runtime.intent
# names (a fixed id when none), unless RECORD_DIR/runtime.refuse names a
# refusal key: then it prints that keyed line on stderr with a refused reply
# and exits 1. `state inspect --fleet` answers with the open intents in
# RECORD_DIR/runtime.open-intents (`[]` when absent), or exits with the
# status RECORD_DIR/runtime.inspect-rc holds, printing one keyed line.
fixture_runtime_stub() { # DIR [RECORD_DIR]
  local dir="$1" record="${2:-}"
  [[ "$dir" == "$TMP_ROOT/"* ]] || { echo 'runtime-stub: dir=not-private' >&2; return 1; }
  [[ ! -L "$dir/orch-runtime" ]] || rm -- "${dir:?}/orch-runtime"
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
