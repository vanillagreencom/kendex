import type { On } from 'claude-code';

// Each response below is what `kendex tier-model claude --model <class> --json` answers for the
// context its row sends; skills/orch/tests/claude-model-classes.sh holds them to that core.

const protocol = 'model-resolution-v1';
const unread = { code: 'model-availability-unknown', source: 'claude:mods-model-list', cause: 'model list interface is unavailable' };
const unreadWarning = (requested: string, selected: string) =>
  `model-resolution: requested=${requested} selected=${selected} causes=model-availability-unknown source=claude:mods-model-list detail=model list interface is unavailable`;

/** A launch context with a complete Claude model list, as KENDEX_MODEL_CONTEXT carries it. */
export const launch = {
  protocol, harness: 'claude', account: 'fixture', host: 'fixture',
  providers: ['anthropic'], currentProvider: 'anthropic',
  models: { tag: 'complete', source: 'fixture:launch', account: 'fixture', host: 'fixture', models: [
    { provider: 'anthropic', id: 'claude-opus-5-5', nativeSelector: 'opus', allowed: true, chat: true, isDefault: true },
    { provider: 'anthropic', id: 'claude-sonnet-5-5', nativeSelector: 'sonnet', allowed: true, chat: true, isDefault: false },
  ] },
  default: { tag: 'native-default' },
  capacity: [
    { tag: 'known', selector: 'sonnet', account: 'fixture', host: 'fixture', source: 'fixture:capacity', context_window: 200000 },
    { tag: 'known', selector: 'opus', account: 'fixture', host: 'fixture', source: 'fixture:capacity', context_window: 200000 },
  ],
  rejected: [],
};

/** A `fast` child under `launch`. */
export const spawnSelected = {
  protocol, harness: 'claude', request: { tag: 'class', class: 'fast' },
  resolution: { tag: 'selected',
    selection: { effectiveClass: 'light', provider: 'anthropic', nativeSelector: 'sonnet', concreteId: 'claude-sonnet-5-5',
      source: 'fixture:launch', capacity: launch.capacity[0] },
    diagnostics: [{ code: 'fallback' }] },
  warning: 'model-resolution: requested=fast selected=sonnet causes=fallback source=',
};

/** An `inherit` child, or one kendex does not manage when `tag` is `unmanaged`. */
export const passThrough = (tag: 'inherit' | 'unmanaged') => ({ protocol, harness: 'claude', request: { tag: 'inherit' }, resolution: { tag } });

/** A `standard` child with no model list. */
export const spawnDefault = {
  protocol, harness: 'claude', request: { tag: 'class', class: 'standard' },
  resolution: { tag: 'harness-default', request: { tag: 'class', class: 'standard' }, path: { tag: 'native-default' },
    capacity: { tag: 'unknown', source: 'runtime:native-default', cause: 'native default model is not observed' },
    diagnostics: [unread] },
  warning: unreadWarning('standard', 'native-default'),
};

/** A root `fast` request under `launch`, the receipt `opus` and the step on `claude-opus-5-5`. */
export const stepSelected = { ...spawnSelected, selectorChange: { tag: 'equivalent' } };

/** The default path core keeps for the fixture session model `opus`, as the root step sends it. */
export const observedOpus = {
  tag: 'observed-session-or-default', selector: 'opus', provider: null, id: null,
  account: 'native-session', host: 'native-process', source: 'claude:session.model',
};

/** A root `standard` request with no model list, the receipt `opus` and the step on `claude-opus-5-5`. */
export const stepObserved = {
  protocol, harness: 'claude', request: { tag: 'class', class: 'standard' },
  resolution: { tag: 'harness-default', request: { tag: 'class', class: 'standard' }, path: observedOpus,
    capacity: { tag: 'unknown', source: 'runtime:capacity', cause: 'missing model-bound capacity/admission evidence' },
    diagnostics: [unread] },
  warning: unreadWarning('standard', 'opus'),
  selectorChange: { tag: 'equivalent' },
};

/** As `stepObserved`, the step on `claude-fable-5-5`. */
export const stepChanged = { ...stepObserved, selectorChange: { tag: 'changed' } };

/** As `stepObserved`, with no receipt and the step on `opus`. */
export const stepUnknown = { ...stepObserved, selectorChange: { tag: 'unknown' } };

const metadataCause = 'HooksError: kendex-model-classes: $.session.model: metadata unread';

/** As `stepObserved`, the session model read failing. */
export const stepNative = {
  ...stepObserved,
  resolution: { ...spawnDefault.resolution,
    diagnostics: [{ code: 'model-availability-unknown', source: 'claude:session.model' },
      { code: 'model-list-failed', source: 'claude:session.model', cause: metadataCause }] },
  warning: `model-resolution: requested=standard selected=native-default causes=model-availability-unknown,model-list-failed source=claude:session.model,claude:session.model detail=${metadataCause}`,
};

type Native = { variables?: Record<string, string>; metadataFails?: boolean; exitCode?: number; stderr?: string; truncated?: boolean };

/** Supply native APIs beneath the production callback, and retain its real calls. `response` undefined prints no stdout. */
export function install(on: On, response: unknown, { variables: initial = {}, metadataFails = false, exitCode = 0, stderr = '', truncated = false }: Native = {}) {
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
      isStdoutTruncated: truncated, isStderrTruncated: false } };
  });
  return { variables, calls, warnings };
}
