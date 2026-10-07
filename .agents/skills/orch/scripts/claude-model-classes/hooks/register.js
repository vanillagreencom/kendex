// Claude Code 2.1.287 is the first version with the model rewrites and fail-closed catches used here.
// `kendex tier-model` owns request parsing, selector equivalence, access, fallback and the warning line; no class table lives here.
// kendex 1.7.0 is the floor for `--runtime-context-json`; the first kendex release after 1.11.0 is the first to send the `warning` line.
const protocol = 'model-resolution-v1';
// kendex 1.7.0 through 1.11.0 answer a fallback with diagnostics and no `warning`; drop this when the floor passes 1.11.0.
const warningAbsent = 'model-resolution: warning=absent cause=kendex 1.11.0 or older sends diagnostics without the warning line; upgrade kendex to read them';

function record(value, name) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`model-resolution: invalid=${name}`);
  }
  return value;
}

function selector(value) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('model-resolution: invalid=selector');
  }
  return value;
}

// Core states its own failure: stderr's first line, and for a refused response its warning line on stdout.
function coreFailure(result) {
  let warning;
  try {
    warning = JSON.parse(result.stdout)?.warning;
  } catch {
    warning = undefined;
  }
  const line = result.stderr.trim().split('\n')[0];
  const stderr = line === '' ? '' : ` stderr=${line}`;
  return new Error(`model-resolution: core-exit=${result.exitCode}${stderr}${typeof warning === 'string' ? ` warning=${warning}` : ''}`);
}

// The decided record: `model` is core's selected selector, `fallback` the observed default it kept.
function readResponse(result) {
  if (result.exitCode !== 0) throw coreFailure(result);
  if (result.isStdoutTruncated === true) throw new Error('model-resolution: invalid=truncated-response');
  const response = record(JSON.parse(result.stdout), 'response');
  if (response.protocol !== protocol) throw new Error('model-resolution: invalid=protocol');
  if (response.harness !== 'claude') throw new Error('model-resolution: invalid=harness');
  if (response.warning !== undefined && typeof response.warning !== 'string') {
    throw new Error('model-resolution: invalid=warning');
  }
  const decision = record(response.resolution, 'resolution');
  const diagnosed = Array.isArray(decision.diagnostics) && decision.diagnostics.length > 0;
  const warning = response.warning ?? (diagnosed ? warningAbsent : undefined);
  const decided = { model: undefined, fallback: undefined, change: response.selectorChange, warning };
  switch (decision.tag) {
    case 'selected':
      decided.model = selector(record(decision.selection, 'selection').nativeSelector);
      break;
    case 'harness-default':
      switch (record(decision.path, 'path').tag) {
        case 'native-default': break;
        case 'observed-session-or-default': decided.fallback = selector(decision.path.selector); break;
        default: throw new Error('model-resolution: invalid=default-path');
      }
      break;
    case 'inherit':
    case 'unmanaged':
      break;
    default:
      throw new Error('model-resolution: invalid=runtime-result');
  }
  return decided;
}

async function launchContext($) {
  const transport = await $.env.get('KENDEX_MODEL_CONTEXT');
  // This identity binds unknown facts to this native process. It grants no model access.
  if (transport === undefined) {
    return {
      protocol, harness: 'claude', account: 'native-session', host: 'native-process',
      providers: [], currentProvider: null,
      models: { tag: 'unsupported', source: 'claude:mods-model-list' },
      default: { tag: 'native-default' }, capacity: [], rejected: [],
    };
  }
  // A person may set this by hand, so a bad value names the variable rather than reading as core's output.
  let context;
  try {
    context = JSON.parse(transport);
  } catch (error) {
    throw new Error(`model-resolution: invalid=KENDEX_MODEL_CONTEXT cause=${error.message}`);
  }
  return { ...record(context, 'KENDEX_MODEL_CONTEXT') };
}

// A kept default runs the root step on the session's model, so core judges that model.
async function sessionContext($) {
  const context = await launchContext($);
  let observed;
  try {
    observed = await $.session.model();
    if (typeof observed !== 'string' || observed.length === 0) {
      context.models = { tag: 'unsupported', source: 'claude:session.model' };
    }
  } catch (error) {
    context.models = { tag: 'failed', source: 'claude:session.model', cause: String(error) };
  }
  context.default = typeof observed === 'string' && observed.length > 0 ? {
    tag: 'observed-session-or-default', selector: observed,
    provider: null, id: null, account: context.account, host: context.host, source: 'claude:session.model',
  } : { tag: 'native-default' };
  return context;
}

async function resolve($, args, cwd, context, next) {
  const result = await $.process.run([
    'kendex', 'tier-model', 'claude', ...args,
    '--runtime-context-json', JSON.stringify(context), '--json',
  ], { cwd, timeoutMs: 30000 });
  if (next.signal.aborted) throw new Error('model-resolution: abandoned=request');
  return readResponse(result);
}

// Core writes the line; this session prints it once.
async function warn($, line) {
  if (line === undefined || await $.env.get('KENDEX_MODEL_WARNING_EMITTED') === '1') return;
  await $.env.set('KENDEX_MODEL_WARNING_EMITTED', '1');
  await $.ui.log(line);
}

/** Register native model callbacks. Known integration errors stop downstream startup. */
export function register(on) {
  on('agent.spawn', async ($, e, next) => {
    const cwd = e.cwd === undefined ? await $.session.cwd() : selector(e.cwd);
    // A kept default leaves the child on its declared alias, which Claude resolves; the parent's model is not the child's.
    const context = { ...await launchContext($), default: { tag: 'native-default' } };
    const decided = await resolve($, ['--agent', selector(e.subagentType)], cwd, context, next);
    await warn($, decided.warning);
    // Without a selection the spawn goes on unchanged, so Claude applies the declared child's own alias.
    return decided.model === undefined ? next(e) : next({ ...e, model: decided.model });
  }).catch(($, e, next) => ({ deny: `model-resolution: integration=${next.error.kind} cause=${next.error.message}` }));

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e);
    const request = await $.env.get('KENDEX_MODEL_REQUEST');
    if (request === undefined) return yield* next(e);
    const context = await sessionContext($);
    const receipt = await $.env.get('KENDEX_MODEL_SELECTED_SELECTOR');
    context.selectorObservation = { priorSelector: receipt ?? null, currentSelector: e.model };
    const cwd = await $.session.cwd();
    const decided = await resolve($, ['--model', request], cwd, context, next);
    switch (record(decided.change, 'selector-change').tag) {
      case 'changed':
        await $.env.set('KENDEX_MODEL_REQUEST', undefined);
        return yield* next(e);
      case 'unknown':
      case 'equivalent':
        break;
      default:
        throw new Error('model-resolution: invalid=selector-change');
    }
    await warn($, decided.warning);
    const model = decided.model ?? decided.fallback;
    return yield* next(model === undefined ? e : { ...e, model });
  }).catch(async function* ($, e, next) {
    // Streamed chunks are what the person sees and the transcript keeps; the result alone shows nothing.
    const answer = `model-resolution: refused=${next.error.kind} cause=${next.error.message}`;
    yield { kind: 'text', index: 0, text: answer };
    return { turnId: e.turnId, index: e.index, answer, toolUses: [], stopReason: null, usage: null };
  });
}
