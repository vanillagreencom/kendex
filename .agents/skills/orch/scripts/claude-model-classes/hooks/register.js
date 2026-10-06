// Claude Code 2.1.287 is the first version with the model rewrites and fail-closed catches used here.
// `kendex tier-model` owns request parsing, selector equivalence, access and fallback; no class table lives here.
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

function readResponse(result, observation) {
  if (result.exitCode !== 0 || result.isStdoutTruncated === true) {
    throw new Error(`model-resolution: core-exit=${result.exitCode}`);
  }
  const response = record(JSON.parse(result.stdout), 'response');
  if (response.protocol !== protocol || response.harness !== 'claude') {
    throw new Error('model-resolution: invalid=protocol');
  }
  record(response.request, 'request');
  const decision = record(response.resolution, 'resolution');
  switch (decision.tag) {
    case 'selected':
      selector(record(decision.selection, 'selection').nativeSelector);
      break;
    case 'harness-default':
      switch (record(decision.path, 'path').tag) {
        case 'native-default': break;
        case 'observed-session-or-default': selector(decision.path.selector); break;
        default: throw new Error('model-resolution: invalid=default-path');
      }
      break;
    case 'inherit':
    case 'unmanaged':
      break;
    case 'refused':
      throw new Error(`model-resolution: refused=${selector(decision.code)}`);
    default:
      throw new Error('model-resolution: invalid=runtime-result');
  }
  if (observation) {
    switch (record(response.selectorChange, 'selector-change').tag) {
      case 'unknown':
      case 'equivalent':
      case 'changed': break;
      default: throw new Error('model-resolution: invalid=selector-change');
    }
  }
  return response;
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
  return readResponse(result, context.selectorObservation !== undefined);
}

// The original request spelling, as core's own warning line writes it.
function requested(request) {
  switch (request.tag) {
    case 'class': return request.class;
    case 'native-family': return `${request.provider}/${request.family}`;
    case 'exact': return request.selector;
    default: return request.tag;
  }
}

async function warn($, response) {
  const diagnostics = response.resolution.diagnostics;
  if (diagnostics === undefined || diagnostics.length === 0) return;
  if (!Array.isArray(diagnostics)) throw new Error('model-resolution: invalid=diagnostics');
  if (await $.env.get('KENDEX_MODEL_WARNING_EMITTED') === '1') return;
  const decision = response.resolution;
  const selected = decision.selection?.nativeSelector ?? decision.path?.selector ?? 'native-default';
  const causes = diagnostics.map(d => selector(record(d, 'diagnostic').code)).join(',');
  const sources = diagnostics.map(d => d.source).filter(s => typeof s === 'string').join(',');
  const failures = diagnostics.map(d => d.cause).filter(s => typeof s === 'string')
    .map(s => s.split(/\s+/).filter(Boolean).join(' '));
  const detail = failures.length === 0 ? '' : ` detail=${failures.join(',')}`;
  await $.env.set('KENDEX_MODEL_WARNING_EMITTED', '1');
  await $.ui.log(`model-resolution: requested=${requested(response.request)} selected=${selected} causes=${causes} source=${sources}${detail}`);
}

function chosenModel(response, nativeDefault) {
  const decision = response.resolution;
  switch (decision.tag) {
    case 'selected': return decision.selection.nativeSelector;
    case 'harness-default':
      return decision.path.tag === 'observed-session-or-default' ? decision.path.selector : nativeDefault;
    case 'inherit':
    case 'unmanaged': return undefined;
    default: throw new Error('model-resolution: invalid=forward-result');
  }
}

function stepRefusal(e, cause) {
  return { turnId: e.turnId, index: e.index, answer: `model-resolution: refused=${cause}`,
    toolUses: [], stopReason: null, usage: null };
}

/** Register native model callbacks. Known integration errors stop downstream startup. */
export function register(on) {
  on('agent.spawn', async ($, e, next) => {
    const cwd = e.cwd === undefined ? await $.session.cwd() : selector(e.cwd);
    const context = await runtimeContext($, e.parentModel);
    const response = await resolve($, ['--agent', selector(e.subagentType)], cwd, context, next);
    await warn($, response);
    const model = chosenModel(response, 'inherit');
    return model === undefined ? next(e) : next({ ...e, model });
  }).catch(($, e, next) => ({ deny: `model-resolution: integration=${next.error.kind} cause=${next.error.message}` }));

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e);
    const request = await $.env.get('KENDEX_MODEL_REQUEST');
    if (request === undefined) return yield* next(e);
    const context = await runtimeContext($);
    const receipt = await $.env.get('KENDEX_MODEL_SELECTED_SELECTOR');
    context.selectorObservation = { priorSelector: receipt ?? null, currentSelector: e.model };
    const cwd = await $.session.cwd();
    const response = await resolve($, ['--model', request], cwd, context, next);
    if (response.selectorChange.tag === 'changed') {
      await $.env.set('KENDEX_MODEL_REQUEST', undefined);
      return yield* next(e);
    }
    await warn($, response);
    const model = chosenModel(response, e.model);
    return yield* next(model === undefined ? e : { ...e, model });
  }).catch(async function* ($, e, next) {
    return stepRefusal(e, `${next.error.kind} cause=${next.error.message}`);
  });
}
