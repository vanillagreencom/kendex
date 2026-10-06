import { expect, test } from 'claude-code/testing';
import { install, nativeDefault, selected } from './lib/fixtures.ts';

test('core selector reaches one startup with the child directory and identity', async ($, on) => {
  const fixture = install(on, selected);
  let started = 0;
  on('agent.spawn', ($, e) => {
    started += 1;
    return { model: e.model ?? 'native-parent', agentId: 'child' };
  });
  const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'haiku', cwd: '/fixture/child' });
  expect(result.model).toBe('sonnet');
  expect(started).toBe(1);
  expect(result.agentId).toBe('child');
  expect(fixture.calls.length).toBe(1);
  expect(fixture.calls[0].cwd).toBe('/fixture/child');
  expect(fixture.calls[0].argv.slice(0, 5)).toEqual(['kendex', 'tier-model', 'claude', '--agent', 'runtime']);
});

for (const tag of ['inherit', 'unmanaged']) {
  test(`${tag} preserves native input`, async ($, on) => {
    install(on, { ...selected, resolution: { tag } });
    let started = 0;
    on('agent.spawn', ($, e) => { started += 1; return { model: e.model ?? 'parent', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'opus' });
    expect(result.model).toBe('opus');
    expect(started).toBe(1);
  });
}

for (const metadataFails of [false, true]) {
  test(`unknown metadata forwards native inheritance, failed read=${metadataFails}`, async ($, on) => {
    const fixture = install(on, nativeDefault, {}, metadataFails);
    let started = 0;
    on('agent.spawn', ($, e) => { started += 1; return { model: e.model ?? 'parent', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'sonnet' });
    expect(result.model).toBe('inherit');
    expect(started).toBe(1);
    expect(fixture.warnings.length).toBe(1);
    expect(fixture.calls[0].context.models).toMatchObject({ tag: metadataFails ? 'failed' : 'unsupported' });
  });
}

for (const row of [
  { name: 'core exit', response: selected, exit: 1 },
  { name: 'invalid protocol', response: { ...selected, protocol: 'other' }, exit: 0 },
  { name: 'deferred result', response: { ...selected, resolution: { tag: 'deferred-class' } }, exit: 0 },
  { name: 'missing selector', response: { ...selected, resolution: { tag: 'selected', selection: {} } }, exit: 0 },
  { name: 'managed read failure', response: { ...selected, resolution: { tag: 'refused', code: 'agent-request-unreadable' } }, exit: 1 },
]) {
  test(`${row.name} starts no child`, async ($, on) => {
    install(on, row.response, {}, false, row.exit);
    let started = 0;
    on('agent.spawn', () => { started += 1; return { model: 'opus', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    expect(result.deny).toContain('model-resolution: integration=');
    expect(started).toBe(0);
  });
}

test('the warning latch spans repeated child dispatch and honors the managed launcher', async ($, on) => {
  const fixture = install(on, nativeDefault, { KENDEX_MODEL_WARNING_EMITTED: '1' });
  on('agent.spawn', ($, e) => ({ model: e.model ?? 'parent', agentId: 'child' }));
  await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
  await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
  expect(fixture.warnings.length).toBe(0);
  expect(fixture.variables.get('KENDEX_MODEL_WARNING_EMITTED')).toBe('1');
});
