import { expect, test } from 'claude-code/testing';
import { install, nativeDefault, observedDefault, selected } from './lib/fixtures.ts';

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
  test(`unknown metadata keeps the declared model, failed read=${metadataFails}`, async ($, on) => {
    const fixture = install(on, observedDefault, { metadataFails });
    let started = 0;
    on('agent.spawn', ($, e) => { started += 1; return { model: e.model ?? 'parent', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'haiku' });
    expect(result.model).toBe('haiku');
    expect(started).toBe(1);
    expect(fixture.warnings).toEqual([observedDefault.warning]);
    expect(fixture.calls[0].context.models).toMatchObject({ tag: metadataFails ? 'failed' : 'unsupported' });
  });
}

for (const row of [
  { name: 'core stderr failure', response: undefined, exitCode: 1, stderr: 'error: kendex.toml: fixture parse\nsecond line', deny: 'core-exit=1 stderr=error: kendex.toml: fixture parse' },
  { name: 'invalid protocol', response: { ...selected, protocol: 'other' }, deny: 'invalid=protocol' },
  { name: 'deferred result', response: { ...selected, resolution: { tag: 'deferred-class' } }, deny: 'invalid=runtime-result' },
  { name: 'missing selector', response: { ...selected, resolution: { tag: 'selected', selection: {} } }, deny: 'invalid=selector' },
  { name: 'managed read failure', exitCode: 1, deny: 'refused=agent-request-unreadable cause=fixture unreadable',
    response: { ...selected, request: { tag: 'inherit' }, resolution: { tag: 'refused', code: 'agent-request-unreadable',
      diagnostics: [{ code: 'agent-request-unreadable', source: 'runtime', cause: 'fixture unreadable' }] } } },
]) {
  test(`${row.name} starts no child`, async ($, on) => {
    install(on, row.response, { exitCode: row.exitCode, stderr: row.stderr });
    let started = 0;
    on('agent.spawn', () => { started += 1; return { model: 'opus', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    expect(result.deny).toContain('model-resolution: integration=');
    expect(result.deny).toContain(row.deny);
    expect(started).toBe(0);
  });
}

for (const row of [{ preset: {}, printed: 1 }, { preset: { KENDEX_MODEL_WARNING_EMITTED: '1' }, printed: 0 }]) {
  test(`the warning latch spans repeated child dispatch, preset=${row.printed === 0}`, async ($, on) => {
    const fixture = install(on, nativeDefault, { variables: row.preset });
    on('agent.spawn', ($, e) => ({ model: e.model ?? 'parent', agentId: 'child' }));
    await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    expect(fixture.warnings.length).toBe(row.printed);
    expect(fixture.variables.get('KENDEX_MODEL_WARNING_EMITTED')).toBe('1');
  });
}
