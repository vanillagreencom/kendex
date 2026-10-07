#!/usr/bin/env bash
# The Claude model-classes plugin under the Claude Code it targets: strict
# validation and its callback tests, each must-fail control of register.js
# and the fixtures, and every fixture answer held to the kendex on PATH, which
# must carry this checkout's core: CI builds it from the checkout.
#
# Every step runs on a copy under the scratch root, since `claude plugin test`
# lays types into the folder it reads. A control edits one copy, must match
# its text exactly once, and must turn red each test row it names. The core
# contract step prints, from a test written into a copy, the context each
# scenario sends and the fixture that answers it, then asks
# `kendex tier-model claude --model <class> --json` with that context and
# requires exit 0, protocol model-resolution-v1 and the same decision fields.
#
# No claude on PATH skips the suite on a developer machine and fails it
# under CI. No kendex, or one whose answer carries no `warning` field, skips
# the core contract rows by name unless ORCH_REQUIRE_KENDEX is set; a kendex
# that exits nonzero fails the suite.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
PLUGIN="$ROOT/skills/orch/scripts/claude-model-classes"
if ! command -v claude >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "harness: claude is not on PATH under CI; this suite runs the plugin under Claude Code" >&2
    exit 2
  fi
  printf 'claude-model-classes: native-kit=unsupported\n'
  printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
  exit 0
fi
TMP_ROOT="$(mktemp -d)" || { echo "claude-model-classes: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "claude-model-classes: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "claude-model-classes: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

version="$(claude --version)" || exit 1
printf 'claude-model-classes: version=%s\n' "$version"

copy_plugin() { # NAME
  cp -R -- "$PLUGIN" "$TMP_ROOT/$1" || { echo "claude-model-classes: copy=failed name=$1" >&2; exit 1; }
  cp -R -- "$ROOT/skills/orch/tests/claude-model-classes" "$TMP_ROOT/$1/tests" || { echo "claude-model-classes: copy-tests=failed name=$1" >&2; exit 1; }
}

# edit FILE OLD NEW: OLD must occur exactly once.
edit() {
  python3 - "$1" "$2" "$3" <<'EDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
assert s.count(sys.argv[2]) == 1, f'edit: matches={s.count(sys.argv[2])} needle={sys.argv[2]}'
p.write_text(s.replace(sys.argv[2], sys.argv[3]))
EDIT
}

copy_plugin plugin
if claude plugin validate --strict "$TMP_ROOT/plugin" >"$TMP_ROOT/validate.out" 2>&1 </dev/null; then
  pass 'strict plugin validation'
else
  fail 'strict plugin validation' "$(cat -- "$TMP_ROOT/validate.out")"
fi
if claude plugin test "$TMP_ROOT/plugin" >"$TMP_ROOT/test.out" 2>&1 </dev/null; then
  pass 'native callback tests'
else
  fail 'native callback tests' "$(cat -- "$TMP_ROOT/test.out")"
fi

# name@file under the plugin@old@new@rows it turns red, `|`-separated
while IFS='@' read -r name file old new rows <&3; do
  copy_plugin "control-$name"
  edit "$TMP_ROOT/control-$name/$file" "$old" "$new" || { fail "control $name applies"; continue; }
  rc=0
  claude plugin test "$TMP_ROOT/control-$name" >"$TMP_ROOT/control-$name.out" 2>&1 </dev/null || rc=$?
  [[ $rc -ne 0 ]] || fail "control $name exits nonzero"
  IFS='|' read -r -a red <<<"$rows"
  for row in "${red[@]}"; do
    if grep -qF -- "(fail) $row [" "$TMP_ROOT/control-$name.out"; then
      pass "control $name reddens: $row"
    else
      fail "control $name leaves green: $row"
    fi
  done
done 3<<'CONTROLS'
spawn-selector@hooks/register.js@next({ ...e, model: decided.model })@next({ ...e, model: e.model })@core selector reaches one startup with the child directory and identity
spawn-unchanged@hooks/register.js@decided.model === undefined ? next(e) :@decided.model === undefined ? next({ ...e, model: 'sonnet' }) :@inherit preserves native input|a kept default leaves the declared alias and asks about the native default, no launch context
spawn-catch@hooks/register.js@({ deny: `model-resolution: integration=${next.error.kind} cause=${next.error.message}` })@next(e)@core stderr failure starts no child|invalid protocol starts no child
spawn-native-default@hooks/register.js@const context = { ...await launchContext($), default: { tag: 'native-default' } };@const context = await sessionContext($);@core selector reaches one startup with the child directory and identity|a kept default leaves the declared alias and asks about the native default, no launch context
spawn-launch-default@hooks/register.js@const context = { ...await launchContext($), default: { tag: 'native-default' } };@const context = await launchContext($);@a kept default leaves the declared alias and asks about the native default, a launch default
root-selector@hooks/register.js@return yield* next(model === undefined ? e : { ...e, model });@return yield* next(model === undefined ? e : { ...e, model: e.model });@selected root|kept default runs on the observed session model
root-fallback@hooks/register.js@const model = decided.model ?? decided.fallback;@const model = decided.model;@kept default runs on the observed session model
session-model@hooks/register.js@observed = await $.session.model();@await $.session.model();@selected root|kept default runs on the observed session model
session-source@hooks/register.js@host: context.host, source: 'claude:session.model',@host: context.host, source: 'claude:agent.spawn.parentModel',@selected root|kept default runs on the observed session model
metadata-failure@hooks/register.js@cause: String(error) };@cause: String(error) }; throw error;@failed metadata default
child-exclusion@hooks/register.js@if (e.agentId !== undefined) return yield* next(e);@if (e.agentId !== undefined && false) return yield* next(e);@child keeps its native model without core dispatch
root-change@hooks/register.js@case 'changed':@case 'changed-never':@a confirmed native change withdraws root intent
selector-change@hooks/register.js@throw new Error('model-resolution: invalid=selector-change');@break;@unknown selector decision shows its refusal and makes no model call
root-catch@hooks/register.js@return { turnId: e.turnId, index: e.index, answer, toolUses: [], stopReason: null, usage: null };@return yield* next(e);@core failure shows its refusal and makes no model call
refusal-chunk@hooks/register.js@yield { kind: 'text', index: 0, text: answer };@if (false) yield { kind: 'text', index: 0, text: answer };@core failure shows its refusal and makes no model call|invalid protocol shows its refusal and makes no model call
warning-latch@hooks/register.js@await $.env.get('KENDEX_MODEL_WARNING_EMITTED') === '1') return;@(await $.env.get('KENDEX_MODEL_WARNING_EMITTED') === '1' && false)) return;@the warning latch spans repeated child dispatch, preset=false|the warning latch spans repeated child dispatch, preset=true
warning-line@hooks/register.js@await $.ui.log(line);@await $.ui.log(`model-resolution: rebuilt`);@a kept default leaves the declared alias and asks about the native default, no launch context
stderr-line@hooks/register.js@const stderr = line === '' ? '' : ` stderr=${line}`;@const stderr = '';@core stderr failure starts no child|core failure shows its refusal and makes no model call|managed read failure starts no child
core-warning@hooks/register.js@${typeof warning === 'string' ? ` warning=${warning}` : ''}@@managed read failure starts no child
warning-absent@hooks/register.js@return response?.warning ?? (Array.isArray(diagnostics) && diagnostics.length > 0 ? warningAbsent : undefined);@return response?.warning;@a kendex without the warning field still warns once
warning-diagnosed@hooks/register.js@return response?.warning ?? (Array.isArray(diagnostics) && diagnostics.length > 0 ? warningAbsent : undefined);@return response?.warning ?? warningAbsent;@inherit preserves native input|unmanaged preserves native input
core-warning-absent@hooks/register.js@warning = warningOf(JSON.parse(result.stdout));@warning = JSON.parse(result.stdout)?.warning;@kendex 1.11.0 refusal starts no child
context-parse@hooks/register.js@throw new Error(`model-resolution: invalid=KENDEX_MODEL_CONTEXT cause=${error.message}`);@throw error;@unparseable launch context starts no child
context-object@hooks/register.js@return { ...record(context, 'KENDEX_MODEL_CONTEXT') };@return { ...context };@a launch context that is no object starts no child
truncated@hooks/register.js@if (result.isStdoutTruncated === true) throw@if (result.isStdoutTruncated === true && false) throw@truncated response starts no child
protocol@hooks/register.js@if (response.protocol !== protocol) throw@if (response.protocol !== protocol && false) throw@invalid protocol starts no child|invalid protocol shows its refusal and makes no model call
harness@hooks/register.js@if (response.harness !== 'claude') throw@if (response.harness !== 'claude' && false) throw@another harness starts no child
default-path@hooks/register.js@default: throw new Error('model-resolution: invalid=default-path');@default: break;@unknown default path starts no child
runtime-result@hooks/register.js@throw new Error('model-resolution: invalid=runtime-result');@break;@deferred result starts no child
selector@hooks/register.js@if (typeof value !== 'string' || value.length === 0) {@if (typeof value !== 'string' && false) {@missing selector starts no child
CONTROLS

# The scenarios the fixtures name, each printing what it sent and what answered it.
contract_test() { # PLUGIN_COPY
  cat >"$1/tests/core-contract.test.ts" <<'TEST'
import { test } from 'claude-code/testing';
import { install, launch, observedOpus, spawnDefault, spawnSelected, stepChanged, stepNative, stepObserved, stepSelected, stepUnknown } from './lib/fixtures.ts';

const intent = { KENDEX_MODEL_REQUEST: 'standard', KENDEX_MODEL_SELECTED_SELECTOR: 'opus' };
const launched = JSON.stringify(launch);
const launchDefault = JSON.stringify({ ...launch, models: { tag: 'unsupported', source: 'claude:mods-model-list' }, default: observedOpus });
const report = (name: string, context: unknown, response: unknown) =>
  console.log(`core-contract=${JSON.stringify({ name, context, response })}`);

for (const row of [
  { name: 'spawn-selected', response: spawnSelected, variables: { KENDEX_MODEL_CONTEXT: launched } },
  { name: 'spawn-default', response: spawnDefault, variables: {} },
  { name: 'spawn-launch-default', response: spawnDefault, variables: { KENDEX_MODEL_CONTEXT: launchDefault } },
]) {
  test(row.name, async ($, on) => {
    const fixture = install(on, row.response, { variables: row.variables });
    on('agent.spawn', ($, e) => ({ model: e.model ?? 'parent', agentId: 'child' }));
    await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    report(row.name, fixture.calls[0].context, row.response);
  });
}

for (const row of [
  { name: 'step-selected', response: stepSelected, model: 'claude-opus-5-5', fails: false, variables: { ...intent, KENDEX_MODEL_REQUEST: 'fast', KENDEX_MODEL_CONTEXT: launched } },
  { name: 'step-observed', response: stepObserved, model: 'claude-opus-5-5', fails: false, variables: intent },
  { name: 'step-native', response: stepNative, model: 'claude-opus-5-5', fails: true, variables: intent },
  { name: 'step-changed', response: stepChanged, model: 'claude-fable-5-5', fails: false, variables: intent },
  { name: 'step-unknown', response: stepUnknown, model: 'opus', fails: false, variables: { KENDEX_MODEL_REQUEST: 'standard' } },
]) {
  test(row.name, async ($, on) => {
    const fixture = install(on, row.response, { variables: row.variables, metadataFails: row.fails });
    on('turn.step', async function* ($, e) {
      return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null };
    });
    const stream = $.turn.step({ turnId: 'turn', index: 0, model: row.model, messageCount: 1 });
    let step = await stream.next();
    while (step.done !== true) step = await stream.next();
    report(row.name, fixture.calls[0].context, row.response);
  });
}
TEST
}
CONTRACT_SCENARIOS='spawn-selected spawn-default spawn-launch-default step-selected step-observed step-native step-changed step-unknown'

# The fields register.js reads from core's answer.
DECISION='{tag: .resolution.tag, path: .resolution.path, model: .resolution.selection.nativeSelector, change: .selectorChange.tag, warned: has("warning")}'

# contract COPY: prints one `name verdict` line per scenario, verdict ok,
# core-exit=N, protocol=P or differs; returns 1 when the copy printed none.
contract() {
  local copy="$1" out line name context response class rc answer got want
  contract_test "$copy"
  out="$TMP_ROOT/${copy##*/}.contract"
  claude plugin test "$copy" >"$out" 2>&1 </dev/null || true
  grep -q '^core-contract=' "$out" || return 1
  while IFS= read -r line; do
    line="${line#core-contract=}"
    name="$(jq -r '.name' <<<"$line")" || return 1
    context="$(jq -c '.context' <<<"$line")" || return 1
    response="$(jq -c '.response' <<<"$line")" || return 1
    class="$(jq -r '.response.request.class' <<<"$line")" || return 1
    rc=0
    answer="$(cd -- "$TMP_ROOT" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" \
      kendex tier-model claude --model "$class" --json --runtime-context-json "$context" 2>"$TMP_ROOT/core.err")" || rc=$?
    if [[ $rc -ne 0 ]]; then
      printf '%s core-exit=%s\n' "$name" "$rc"
    elif [[ "$(jq -r '.protocol' <<<"$answer")" != model-resolution-v1 ]]; then
      printf '%s protocol=%s\n' "$name" "$(jq -r '.protocol' <<<"$answer")"
    else
      got="$(jq -cS "$DECISION" <<<"$answer")" || return 1
      want="$(jq -cS "$DECISION" <<<"$response")" || return 1
      if [[ "$got" == "$want" ]]; then
        printf '%s ok\n' "$name"
      else
        printf '%s differs\n' "$name"
        printf '        %s core: %s\n        %s fixture: %s\n' "$name" "$got" "$name" "$want" >&2
      fi
    fi
  done < <(grep '^core-contract=' "$out")
}

# The fixtures carry core's `warning` field, which kendex first sends in the first release after 1.11.0.
# core_probe asks the kendex on PATH about the plugin's own no-list context and
# prints `ready`, `skip REASON` for no kendex or an answer without the field,
# or `fail core-exit=N stderr=LINE` for a kendex that exits nonzero.
mkdir -p "$TMP_ROOT/home"
NO_LIST='{"protocol":"model-resolution-v1","harness":"claude","account":"native-session","host":"native-process","providers":[],"currentProvider":null,"models":{"tag":"unsupported","source":"claude:mods-model-list"},"default":{"tag":"native-default"},"capacity":[],"rejected":[]}'
core_probe() {
  local probe rc=0 line=''
  if ! command -v kendex >/dev/null 2>&1; then
    printf 'skip no kendex on PATH\n'
    return
  fi
  probe="$(cd -- "$TMP_ROOT" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" \
    kendex tier-model claude --model standard --json --runtime-context-json "$NO_LIST" 2>"$TMP_ROOT/probe.err")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    IFS= read -r line <"$TMP_ROOT/probe.err" || true
    printf 'fail core-exit=%s stderr=%s\n' "$rc" "$line"
  elif jq -e 'has("warning")' <<<"$probe" >/dev/null 2>&1; then
    printf 'ready\n'
  else
    printf 'skip the kendex on PATH sends no warning field\n'
  fi
}

# A kendex that fails the probe fails the suite rather than skipping.
mkdir -p "$TMP_ROOT/failing-kendex"
printf '#!/bin/sh\necho "error: fixture probe failure" >&2\nexit 3\n' >"$TMP_ROOT/failing-kendex/kendex"
chmod +x "$TMP_ROOT/failing-kendex/kendex"
assert_eq "$(PATH="$TMP_ROOT/failing-kendex:$PATH" core_probe)" 'fail core-exit=3 stderr=error: fixture probe failure' 'control core-probe-exit fails, not skips'

core="$(core_probe)"
case "$core" in
  fail\ *)
    fail "core contract probe ${core#fail }" ;;
  skip\ *)
    if [[ -n "${ORCH_REQUIRE_KENDEX:-}" ]]; then
      fail "ORCH_REQUIRE_KENDEX is set and ${core#skip } for the core contract"
    else
      for scenario in $CONTRACT_SCENARIOS contract-fixture contract-key; do
        printf '  skip  core answers %s: %s\n' "$scenario" "${core#skip }"
      done
    fi ;;
  ready)
    copy_plugin contract
    verdicts="$(contract "$TMP_ROOT/contract")" || { fail 'core contract scenarios printed'; verdicts=''; }
    for scenario in $CONTRACT_SCENARIOS; do
      assert_eq "$(grep "^$scenario " <<<"$verdicts" || true)" "$scenario ok" "core answers $scenario as its fixture does"
    done

    # A fixture core would not give, and a context key core does not read.
    copy_plugin contract-fixture
    edit "$TMP_ROOT/contract-fixture/tests/lib/fixtures.ts" "tag: 'observed-session-or-default', selector: 'opus'," "tag: 'observed-session-or-default', selector: 'sonnet',"
    verdicts="$(contract "$TMP_ROOT/contract-fixture")" || verdicts=''
    assert_eq "$(grep '^step-observed ' <<<"$verdicts" || true)" 'step-observed differs' 'control contract-fixture reddens: step-observed'
    copy_plugin contract-key
    edit "$TMP_ROOT/contract-key/hooks/register.js" 'providers: [], currentProvider: null,' 'providers: [], provider: null,'
    verdicts="$(contract "$TMP_ROOT/contract-key")" || verdicts=''
    assert_eq "$(grep '^spawn-default ' <<<"$verdicts" || true)" 'spawn-default core-exit=1' 'control contract-key reddens: spawn-default'
    assert_eq "$(grep '^step-observed ' <<<"$verdicts" || true)" 'step-observed core-exit=1' 'control contract-key reddens: step-observed' ;;
  *)
    fail "core contract probe=unexpected value=[$core]" ;;
esac

printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
