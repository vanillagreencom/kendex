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
  warning: 'model-resolution: fixture warning',
};

export const observedDefault = {
  ...nativeDefault,
  resolution: { ...nativeDefault.resolution, path: { tag: 'observed-session-or-default', selector: 'claude-opus-5-5' } },
};

type Native = { variables?: Record<string, string>; metadataFails?: boolean; exitCode?: number; stderr?: string };

/** Supply native APIs beneath the production callback, and retain its real calls. `response` undefined prints no stdout. */
export function install(on: On, response: unknown, { variables: initial = {}, metadataFails = false, exitCode = 0, stderr = '' }: Native = {}) {
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
    return { value: { exitCode, stdout: response === undefined ? '' : JSON.stringify(response), stderr,
      isStdoutTruncated: false, isStderrTruncated: false } };
  });
  return { variables, calls, warnings };
}
