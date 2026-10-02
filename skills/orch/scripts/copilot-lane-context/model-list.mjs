// SDK-owned model discovery starts no conversation and keeps no local cache.
const source = 'copilot:sdk.listModels';
const [account, host] = process.argv.slice(2);
if (!account || !host) throw new Error('copilot-model-list: missing=account-or-host');
let evidence;
let client;
let timer;
try {
  let sdkUrl;
  try {
    sdkUrl = import.meta.resolve('@github/copilot-sdk');
  } catch (error) {
    if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
    evidence = { providers: [], models: { tag: 'unsupported', source }, capacity: [] };
  }
  if (sdkUrl !== undefined) {
    const { CopilotClient, RuntimeConnection } = await import(sdkUrl);
    if (typeof CopilotClient !== 'function' || typeof RuntimeConnection?.forStdio !== 'function'
        || ['start', 'listModels', 'stop', 'forceStop'].some(method => typeof CopilotClient.prototype[method] !== 'function')) {
      evidence = { providers: [], models: { tag: 'unsupported', source }, capacity: [] };
    } else {
      client = new CopilotClient({ connection: RuntimeConnection.forStdio({ env: { ...process.env } }) });
      const list = await Promise.race([
        (async () => { await client.start(); return client.listModels(); })(),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('model-list deadline exceeded')), 30000); }),
      ]);
      if (!Array.isArray(list)) throw new Error('model list is not an array');
      const models = [];
      const capacity = [];
      for (const model of list) {
        if (typeof model.id !== 'string' || model.id.length === 0) throw new Error('listed model has no id');
        const supports = model.capabilities?.supports;
        const window = model.capabilities?.limits?.max_context_window_tokens;
        const chat = typeof supports?.vision === 'boolean' && typeof supports?.reasoningEffort === 'boolean';
        const state = model.policy?.state;
        if (state !== undefined && !['enabled', 'disabled', 'unconfigured'].includes(state)) throw new Error('unknown model policy');
        models.push({ provider: 'github-copilot', id: model.id, nativeSelector: model.id,
          allowed: state === undefined || state === 'enabled', chat, isDefault: false });
        if (Number.isSafeInteger(window) && window > 0) {
          capacity.push({ tag: 'known', selector: model.id, account, host, source, context_window: window });
        }
      }
      evidence = { providers: ['github-copilot'], models: { tag: 'complete', source, account, host, models }, capacity };
    }
  }
} catch (error) {
  evidence = { providers: [], models: { tag: 'failed', source, cause: String(error) }, capacity: [] };
} finally {
  clearTimeout(timer);
  if (client !== undefined) {
    let stopTimer;
    try {
      const errors = await Promise.race([
        client.stop(),
        new Promise((_, reject) => { stopTimer = setTimeout(() => reject(new Error('shutdown deadline exceeded')), 30000); }),
      ]);
      if (Array.isArray(errors) && errors.length > 0) throw new Error(errors.map(String).join(';'));
    } catch (error) {
      if (evidence.models.tag === 'failed') evidence.models.cause += `; disconnect: ${String(error)}`;
      else evidence = { providers: [], models: { tag: 'failed', source, cause: `disconnect: ${String(error)}` }, capacity: [] };
      try { await client.forceStop(); }
      catch (failure) { evidence.models.cause += `; force-stop: ${String(failure)}`; }
    } finally {
      clearTimeout(stopTimer);
    }
  }
}
process.stdout.write(`${JSON.stringify(evidence)}\n`);
