// Claude Code 2.1.287 is the first version with the model rewrites and fail-closed catches used here.
// `kendex tier-model` owns request parsing, selector equivalence, access, fallback and the warning line; no class table lives here.
const protocol = 'model-resolution-v1';

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

// Core prints a refused response on stdout and exits 1; every other failure speaks on stderr.
function coreFailure(result) {
  let response;
  try {
    response = JSON.parse(result.stdout);
  } catch {
    response = undefined;
  }
  const decision = response?.protocol === protocol ? response.resolution : undefined;
  if (decision?.tag === 'refused') {
    const causes = (Array.isArray(decision.diagnostics) ? decision.diagnostics : [])
      .map(d => d?.cause).filter(c => typeof c === 'string');
    const cause = causes.length === 0 ? '' : ` cause=${causes.join(',')}`;
    return new Error(`model-resolution: refused=${selector(decision.code)}${cause}`);
  }
  const line = result.stderr.trim().split('\n')[0];
  return new Error(`model-resolution: core-exit=${result.exitCode}${line === '' ? '' : ` stderr=${line}`}`);
}

// The decided record: `model` is core's selected selector, `fallback` the observed default it kept.
function readResponse(result) {
  if (result.exitCode !== 0) throw coreFailure(result);
  if (result.isStdoutTruncated === true) throw new Error('model-resolution: invalid=truncated-response');
  const response = record(JSON.parse(result.stdout), 'response');
  if (response.protocol !== protocol || response.harness !== 'claude') {
    throw new Error('model-resolution: invalid=protocol');
  }
  if (response.warning !== undefined && typeof response.warning !== 'string') {
    throw new Error('model-resolution: invalid=warning');
  }
  const decided = { model: undefined, fallback: undefined, change: response.selectorChange, warning: response.warning };
  const decision = record(response.resolution, 'resolution');
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

async function runtimeContext($, parentModel) {
  const transport = await $.env.get('KENDEX_MODEL_CONTEXT');
  // This identity binds unknown facts to this native process. It grants no model access.
  let context = transport === undefined ? {
    protocol, harness: 'claude', account: 'native-session', host: 'native-process',
    providers: [], currentProvider: null,
    models: { tag: 'unsupported', source: 'claude:mods-model-list' },
    default: { tag: 'native-default' }, capacity: [], rejected: [],
  } : record(JSON.parse(transport), 'launch-context');
  context = { ...context };
  let observed;
  try {
    observed = await $.session.model();
    if (typeof observed !== 'string' || observed.length === 0) {
      context.models = { tag: 'unsupported', source: 'claude:session.model' };
    }
  } catch (error) {
    context.models = { tag: 'failed', source: 'claude:session.model', cause: String(error) };
  }
  const nativeModel = parentModel === undefined ? observed : parentModel;
  context.default = typeof nativeModel === 'string' && nativeModel.length > 0 ? {
    tag: 'observed-session-or-default', selector: nativeModel,
    provider: null, id: null, account: context.account, host: context.host,
    source: parentModel === undefined ? 'claude:session.model' : 'claude:agent.spawn.parentModel',
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
    const context = await runtimeContext($, e.parentModel);
    const decided = await resolve($, ['--agent', selector(e.subagentType)], cwd, context, next);
    await warn($, decided.warning);
    // Without a selection the spawn goes on unchanged, so Claude applies the declared child's own alias.
    return decided.model === undefined ? next(e) : next({ ...e, model: decided.model });
  }).catch(($, e, next) => ({ deny: `model-resolution: integration=${next.error.kind} cause=${next.error.message}` }));

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e);
    const request = await $.env.get('KENDEX_MODEL_REQUEST');
    if (request === undefined) return yield* next(e);
    const context = await runtimeContext($);
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
