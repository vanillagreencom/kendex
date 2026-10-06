import type { On } from 'claude-code';

export const selected = {
  protocol: 'model-resolution-v1', harness: 'claude',
  request: { tag: 'class', class: 'fast' },
  resolution: { tag: 'selected', selection: { nativeSelector: 'sonnet' }, diagnostics: [] },
};

export const nativeDefault = {
  ...selected,
  resolution: { tag: 'harness-default', path: { tag: 'native-default' },
    diagnostics: [{ code: 'model-availability-unknown', source: 'fixture:metadata', cause: 'unread' }] },
};

/** Supply native APIs beneath the production callback, and retain its real calls. */
export function install(on: On, response: unknown, initial: Record<string, string> = {}, metadataFails = false, exitCode = 0) {
  const variables = new Map(Object.entries(initial));
  const calls: { argv: readonly string[]; cwd: string | undefined; context: Record<string, unknown> }[] = [];
  const warnings: string[] = [];
  on('env.get', ($, e) => ({ value: variables.get(e.name) }));
  on('env.set', ($, e) => {
    if (e.value === undefined) variables.delete(e.name);
    else variables.set(e.name, e.value);
    return { value: undefined };
  });
  on('session.cwd', () => ({ value: '/fixture/session' }));
  on('session.model', () => metadataFails ? { deny: 'metadata unread' } : { value: 'opus' });
  on('ui.log', ($, e) => { warnings.push(e.text); return { value: undefined }; });
  on('process.run', ($, e) => {
    const position = e.argv.indexOf('--runtime-context-json');
    calls.push({ argv: e.argv, cwd: e.init?.cwd, context: JSON.parse(e.argv[position + 1]) });
    return { value: { exitCode, stdout: JSON.stringify(response), stderr: '',
      isStdoutTruncated: false, isStderrTruncated: false } };
  });
  return { variables, calls, warnings };
}
