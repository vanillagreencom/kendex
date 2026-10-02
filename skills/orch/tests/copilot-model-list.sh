#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
mkdir -p -- "$ROOT/tmp" || { echo 'copilot-model-list: scratch=parent-create-failed' >&2; exit 1; }
TMP_ROOT="$(mktemp -d "$ROOT/tmp/copilot-model-list.XXXXXX")" || { echo 'copilot-model-list: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "copilot-model-list: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'copilot-model-list: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
HELPER="$TMP_ROOT/ext/model-list.mjs"
SDK="$TMP_ROOT/ext/node_modules/@github/copilot-sdk"
mkdir -p "$SDK"
cp -- "${COPILOT_MODEL_HELPER:-$ROOT/skills/orch/scripts/copilot-lane-context/model-list.mjs}" "$HELPER"
printf '{"name":"@github/copilot-sdk","type":"module","exports":"./index.mjs"}\n' > "$SDK/package.json"
cat > "$SDK/index.mjs" <<'SDK'
import { appendFileSync } from 'node:fs';
const log = value => appendFileSync(process.env.FAKE_LOG, `${value}\n`);
export const RuntimeConnection = { forStdio(options) { log(`connection:${options.path}:${options.env.COPILOT_HOME}`); return options; } };
export class CopilotClient {
  constructor() { log('construct'); }
  async start() {
    log('start');
    if (process.env.MODE === 'start-failed') throw new Error('startup failed');
    if (process.env.MODE === 'start-hang') {
      // Reach the injected deadline before releasing startup. The release lets a
      // timeout-bypass control finish and fail the evidence assertion normally.
      globalThis.setTimeout = callback => { queueMicrotask(callback); return undefined; };
      await new Promise(resolve => setImmediate(resolve));
    }
  }
  async listModels() {
    log('list');
    if (['list-failed', 'list-stop-failed'].includes(process.env.MODE)) throw new Error('list failed');
    if (process.env.MODE === 'empty') return [];
    if (process.env.MODE === 'bad') return [{ id: '' }];
    return [
      { id: 'chat', capabilities: { supports: { vision: false, reasoningEffort: false }, limits: { max_context_window_tokens: 123456 } }, policy: { state: 'enabled' } },
      { id: 'denied', capabilities: { supports: { vision: true, reasoningEffort: true } }, policy: { state: 'disabled' } },
      { id: 'embedding', capabilities: { supports: {} } },
    ];
  }
  stop() {
    log('stop');
    if (['stop-failed', 'list-stop-failed'].includes(process.env.MODE)) return Promise.resolve([new Error('cleanup failed')]);
    if (process.env.MODE === 'stop-hang') {
      // The fake SDK supplies the test clock at shutdown, after listing ends.
      globalThis.setTimeout = callback => { queueMicrotask(callback); return undefined; };
      return new Promise(() => {});
    }
    return Promise.resolve([]);
  }
  async forceStop() { log('force-stop'); }
}
if (process.env.MODE === 'unsupported') delete CopilotClient.prototype.listModels;
SDK

observe() { # MODE
  : > "$TMP_ROOT/sdk.log"
  OUTPUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" COPILOT_HOME=fixture-account MODE="$1" FAKE_LOG="$TMP_ROOT/sdk.log" node "$HELPER" fixture-account fixture-host)"
  jq -e 'type == "object" and (.models | type) == "object"' <<<"$OUTPUT" >/dev/null || return 1
}
observe complete
assert_eq "$(jq -c '.models | [.tag,.account,.host]' <<<"$OUTPUT")" '["complete","fixture-account","fixture-host"]' 'complete list binds its account and host'
assert_eq "$(jq -c '[.models.models[] | [.id,.allowed,.chat]]' <<<"$OUTPUT")" '[["chat",true,true],["denied",false,true],["embedding",true,false]]' 'policy denial and non-chat capabilities remain distinct'
assert_eq "$(jq -c '.capacity' <<<"$OUTPUT")" '[{"tag":"known","selector":"chat","account":"fixture-account","host":"fixture-host","source":"copilot:sdk.listModels","context_window":123456}]' 'capacity binds to the listed model and account host'
assert_eq "$(paste -sd, - < "$TMP_ROOT/sdk.log")" 'connection:undefined:fixture-account,construct,start,list,stop' 'SDK owns executable selection, listing and shutdown without a conversation'
for mode in empty bad start-failed start-hang list-failed stop-failed list-stop-failed stop-hang unsupported; do
  observe "$mode"
  case "$mode" in
    empty) assert_eq "$(jq -c '[.models.tag,.models.models]' <<<"$OUTPUT")" '["complete",[]]' 'complete empty list stays complete' ;;
    unsupported) assert_eq "$(jq -r '.models.tag' <<<"$OUTPUT")" unsupported 'missing SDK method reports unsupported' ;;
    *) assert_eq "$(jq -r '.models.tag' <<<"$OUTPUT")" failed "$mode keeps failed evidence" ;;
  esac
  case "$mode" in
    stop-failed|list-stop-failed|stop-hang) assert_file_contains "$TMP_ROOT/sdk.log" force-stop "$mode force-closes the owned runtime" ;;
    unsupported) assert_file_not_contains "$TMP_ROOT/sdk.log" start 'unsupported interface starts no runtime' ;;
    *) assert_file_contains "$TMP_ROOT/sdk.log" stop "$mode closes the owned runtime" ;;
  esac
done
observe stop-failed
assert_eq "$(jq -c '[.models.tag,.models.cause]' <<<"$OUTPUT")" '["failed","disconnect: Error: Error: cleanup failed"]' 'cleanup-only failure reports its own cause'
observe list-stop-failed
assert_eq "$(jq -c '[.models.tag,.models.cause]' <<<"$OUTPUT")" '["failed","Error: list failed; disconnect: Error: Error: cleanup failed"]' 'discovery and cleanup failures keep both causes'
observe start-hang
assert_eq "$(jq -c '[.models.tag,.models.cause]' <<<"$OUTPUT")" '["failed","Error: model-list deadline exceeded"]' 'discovery deadline reports its own failed evidence'
assert_file_contains "$TMP_ROOT/sdk.log" stop 'discovery deadline closes the owned runtime'
observe stop-hang
assert_contains "$(jq -r '.models.cause' <<<"$OUTPUT")" 'shutdown deadline exceeded' 'shutdown uses its bounded deadline'
if [[ "${COPILOT_MODEL_CONTROL:-}" != 1 ]]; then
  while IFS=$'\t' read -r name before after assertion; do
    MUTANT="$TMP_ROOT/$name.mjs"
    cp -- "$HELPER" "$MUTANT"
    mutate_file "$MUTANT" "$before" "$after"
    node --check "$MUTANT"
    rc=0
    env COPILOT_MODEL_CONTROL=1 COPILOT_MODEL_HELPER="$MUTANT" bash "$ROOT/skills/orch/tests/copilot-model-list.sh" > "$TMP_ROOT/$name.log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]] && grep -Fq "  FAIL  $assertion" "$TMP_ROOT/$name.log"; then
      pass "control: $name fails its intended assertion"
    else fail "control: $name did not fail its intended assertion"; dump_stderr "$TMP_ROOT/$name.log"; fi
  done <<'CONTROLS'
policy	allowed: state === undefined || state === 'enabled', chat	allowed: true, chat	policy denial and non-chat capabilities remain distinct
deadline	reject(new Error('model-list deadline exceeded'))	void new Error('model-list deadline exceeded')	discovery deadline reports its own failed evidence
cause	evidence.models.cause += `; disconnect: ${String(error)}`	evidence.models.cause = `; disconnect: ${String(error)}`	discovery and cleanup failures keep both causes
CONTROLS
fi
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
