import { expect, test } from 'claude-code/testing';
import { install, nativeDefault, selected } from './lib/fixtures.ts';

const intent = { KENDEX_MODEL_REQUEST: 'standard', KENDEX_MODEL_SELECTED_SELECTOR: 'opus' };

for (const row of [
  { name: 'selected root', response: { ...selected, selectorChange: { tag: 'equivalent' } }, model: 'sonnet', fails: false },
  { name: 'unknown default', response: { ...nativeDefault, selectorChange: { tag: 'unknown' } }, model: 'claude-opus-5-5', fails: false },
  { name: 'failed metadata default', response: { ...nativeDefault, selectorChange: { tag: 'unknown' } }, model: 'claude-opus-5-5', fails: true },
]) {
  test(row.name, async ($, on) => {
    const fixture = install(on, row.response, { variables: intent, metadataFails: row.fails });
    let calls = 0;
    on('turn.step', async function* ($, e) {
      calls += 1;
      yield { kind: 'text', index: 0, text: e.model };
      return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null };
    });
    const stream = $.turn.step({ turnId: 'turn', index: 0, model: 'claude-opus-5-5', messageCount: 1 });
    let step = await stream.next();
    const text: string[] = [];
    while (step.done !== true) {
      if (step.value.kind === 'text') text.push(step.value.text);
      step = await stream.next();
    }
    expect(step.value.answer).toBe(row.model);
    expect(text).toEqual([row.model]);
    expect(calls).toBe(1);
    expect(fixture.calls[0].context.selectorObservation).toEqual({ priorSelector: 'opus', currentSelector: 'claude-opus-5-5' });
    expect(fixture.calls[0].cwd).toBe('/fixture/session');
    expect(fixture.calls[0].argv.slice(0, 5)).toEqual(['kendex', 'tier-model', 'claude', '--model', 'standard']);
  });
}

for (const row of [{ name: 'child', agentId: 'child', variables: intent }, { name: 'untagged root', agentId: undefined, variables: {} }]) {
  test(`${row.name} keeps its native model without core dispatch`, async ($, on) => {
    const fixture = install(on, selected, { variables: row.variables });
    let calls = 0;
    on('turn.step', async function* ($, e) {
      calls += 1;
      return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null };
    });
    const stream = $.turn.step({ turnId: 'turn', index: 0, model: 'child-model', messageCount: 1, agentId: row.agentId });
    let step = await stream.next();
    while (step.done !== true) step = await stream.next();
    expect(step.value.answer).toBe('child-model');
    expect(calls).toBe(1);
    expect(fixture.calls.length).toBe(0);
  });
}

test('a confirmed native change withdraws root intent', async ($, on) => {
  const fixture = install(on, { ...selected, selectorChange: { tag: 'changed' } }, { variables: intent });
  let calls = 0;
  on('turn.step', async function* ($, e) {
    calls += 1;
    return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null };
  });
  const stream = $.turn.step({ turnId: 'turn', index: 0, model: 'claude-fable-5-5', messageCount: 1 });
  let step = await stream.next();
  while (step.done !== true) step = await stream.next();
  expect(step.value.answer).toBe('claude-fable-5-5');
  expect(fixture.variables.has('KENDEX_MODEL_REQUEST')).toBe(false);
  expect(calls).toBe(1);
});

for (const row of [
  { name: 'core failure', response: undefined, exitCode: 1, stderr: 'error: fixture failure', cause: 'core-exit=1 stderr=error: fixture failure' },
  { name: 'invalid protocol', response: { ...selected, protocol: 'other' }, cause: 'invalid=protocol' },
  { name: 'missing selector decision', response: selected, cause: 'invalid=selector-change' },
]) {
  test(`${row.name} shows its refusal and makes no model call`, async ($, on) => {
    install(on, row.response, { variables: intent, exitCode: row.exitCode, stderr: row.stderr });
    let calls = 0;
    on('turn.step', async function* ($, e) {
      calls += 1;
      return { turnId: e.turnId, index: e.index, answer: 'called', toolUses: [], stopReason: 'end_turn', usage: null };
    });
    const stream = $.turn.step({ turnId: 'turn', index: 0, model: 'opus', messageCount: 1 });
    let step = await stream.next();
    const text: string[] = [];
    while (step.done !== true) {
      if (step.value.kind === 'text') text.push(step.value.text);
      step = await stream.next();
    }
    expect(step.value.answer).toContain('model-resolution: refused=');
    expect(step.value.answer).toContain(row.cause);
    expect(text).toEqual([step.value.answer]);
    expect(step.value.toolUses).toEqual([]);
    expect(step.value.usage).toBe(null);
    expect(calls).toBe(0);
  });
}

test('a receipt without an observable selector asks core to retain unknown', async ($, on) => {
  const fixture = install(on, { ...nativeDefault, selectorChange: { tag: 'unknown' } }, { variables: { KENDEX_MODEL_REQUEST: 'standard' } });
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: e.model, toolUses: [], stopReason: 'end_turn', usage: null };
  });
  const stream = $.turn.step({ turnId: 'turn', index: 0, model: 'opus', messageCount: 1 });
  let step = await stream.next();
  while (step.done !== true) step = await stream.next();
  expect(fixture.calls[0].context.selectorObservation).toEqual({ priorSelector: null, currentSelector: 'opus' });
  expect(fixture.variables.get('KENDEX_MODEL_REQUEST')).toBe('standard');
  expect(step.value.answer).toBe('opus');
});
