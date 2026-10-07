import { expect, test } from 'claude-code/testing';
import { install, launch, observedOpus, spawnDefault, spawnSelected } from './lib/fixtures.ts';

test('core selector reaches one startup with the child directory and identity', async ($, on) => {
  const fixture = install(on, spawnSelected, { variables: { KENDEX_MODEL_CONTEXT: JSON.stringify(launch) } });
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
  expect(fixture.calls[0].context.models).toEqual(launch.models);
  expect(fixture.calls[0].context.default).toEqual({ tag: 'native-default' });
});

for (const tag of ['inherit', 'unmanaged']) {
  test(`${tag} preserves native input`, async ($, on) => {
    install(on, { ...spawnSelected, resolution: { tag } });
    let started = 0;
    on('agent.spawn', ($, e) => { started += 1; return { model: e.model ?? 'parent', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'opus' });
    expect(result.model).toBe('opus');
    expect(started).toBe(1);
  });
}

// A launch default names the root session's model, which the child does not run on.
for (const row of [
  { name: 'no launch context', variables: {} },
  { name: 'a launch default', variables: { KENDEX_MODEL_CONTEXT: JSON.stringify({ ...launch, models: { tag: 'unsupported', source: 'claude:mods-model-list' }, default: observedOpus }) } },
]) {
  test(`a kept default leaves the declared alias and asks about the native default, ${row.name}`, async ($, on) => {
    const fixture = install(on, spawnDefault, { variables: row.variables, metadataFails: true });
    let started = 0;
    on('agent.spawn', ($, e) => { started += 1; return { model: e.model ?? 'parent', agentId: 'child' }; });
    const result = await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime', model: 'haiku' });
    expect(result.model).toBe('haiku');
    expect(started).toBe(1);
    expect(fixture.calls[0].context.default).toEqual({ tag: 'native-default' });
    expect(fixture.calls[0].context.models).toEqual({ tag: 'unsupported', source: 'claude:mods-model-list' });
    expect(fixture.warnings).toEqual([spawnDefault.warning]);
  });
}

const unreadable = { code: 'agent-request-unreadable', source: 'runtime', cause: 'fixture unreadable' };
for (const row of [
  { name: 'core stderr failure', response: undefined, exitCode: 1, stderr: 'error: kendex.toml: fixture parse\nsecond line', deny: 'core-exit=1 stderr=error: kendex.toml: fixture parse' },
  { name: 'truncated response', response: spawnSelected, truncated: true, deny: 'invalid=truncated-response' },
  { name: 'invalid protocol', response: { ...spawnSelected, protocol: 'other' }, deny: 'invalid=protocol' },
  { name: 'another harness', response: { ...spawnSelected, harness: 'codex' }, deny: 'invalid=harness' },
  { name: 'deferred result', response: { ...spawnSelected, resolution: { tag: 'deferred-class' } }, deny: 'invalid=runtime-result' },
  { name: 'missing selector', response: { ...spawnSelected, resolution: { tag: 'selected', selection: {} } }, deny: 'invalid=selector' },
  { name: 'unknown default path', response: { ...spawnDefault, resolution: { ...spawnDefault.resolution, path: { tag: 'bogus' } } }, deny: 'invalid=default-path' },
  { name: 'managed read failure', exitCode: 1, deny: 'refused=agent-request-unreadable cause=fixture unreadable',
    response: { ...spawnSelected, request: { tag: 'inherit' }, resolution: { tag: 'refused', code: 'agent-request-unreadable', diagnostics: [unreadable] } } },
  { name: 'refusal without a diagnostics list', exitCode: 1, deny: 'refused=agent-request-unreadable invalid=diagnostics',
    response: { ...spawnSelected, request: { tag: 'inherit' }, resolution: { tag: 'refused', code: 'agent-request-unreadable', diagnostics: unreadable } } },
]) {
  test(`${row.name} starts no child`, async ($, on) => {
    install(on, row.response, { exitCode: row.exitCode, stderr: row.stderr, truncated: row.truncated });
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
    const fixture = install(on, spawnDefault, { variables: row.preset });
    on('agent.spawn', ($, e) => ({ model: e.model ?? 'parent', agentId: 'child' }));
    await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    await $.agent.spawn({ prompt: 'fixture', subagentType: 'runtime' });
    expect(fixture.warnings.length).toBe(row.printed);
    expect(fixture.variables.get('KENDEX_MODEL_WARNING_EMITTED')).toBe('1');
  });
}
