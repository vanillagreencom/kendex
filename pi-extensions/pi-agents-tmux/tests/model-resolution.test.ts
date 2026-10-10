import { afterEach, expect, spyOn, test } from "bun:test";
import { join } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { discoverAgents } from "../extensions/subagent/agents.js";
import * as settings from "../extensions/subagent/settings.js";
import { resetModelWarning, resolveAgentModel } from "../extensions/subagent/settings.js";
import { cleanupTempRuntimes, installMockSpawn, modelRegistryFixture, tempRuntime, writeSettings } from "./single-agent-fixture.js";
import { importRuntimeCopy, writeProjectAgent } from "./browser-fixture.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import { setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { withExtensionTools } from "./extension-fixture.js";

const agent = { name: "runtime", model: "standard", source: "project" } as AgentConfig;
const nativeModel = { provider: "custom", id: "chat", contextWindow: 123456 } as Model<Api>;
const registry = modelRegistryFixture(() => [nativeModel]);
const selected = { protocol: "model-resolution-v1", harness: "pi", resolution: { tag: "selected", selection: { nativeSelector: "custom/chat" }, diagnostics: [] } };
const capture = async () => ({ code: 0, stdout: JSON.stringify(selected), stderr: "" });
afterEach(() => { setPaneExecCaptureForTests(); setSingleAgentSpawnForTests(); resetModelWarning(); clearPackageConfigCache(); cleanupTempRuntimes(); });

for (const row of [
  { model: "light:medium", request: "light", selector: "custom/light-chat", effort: "medium" },
  { model: undefined, request: "standard", selector: "custom/chat", effort: "high" },
]) {
  test(`single tool dispatch transports model and effort, override=${row.model !== undefined}`, async () => {
    await withExtensionTools(async (tools, ctx) => {
      writeProjectAgent(ctx.cwd, "call-model-test", ["model: standard:high"]);
      ctx.modelRegistry = registry;
      const requests: string[] = [];
      setPaneExecCaptureForTests(async (command, args) => {
        expect(command).toBe("kendex");
        requests.push(args[3]);
        return { code: 0, stdout: JSON.stringify({ ...selected, resolution: { tag: "selected", selection: { nativeSelector: row.selector }, diagnostics: [] } }), stderr: "" };
      });
      const spawns = installMockSpawn([{}]);
      const result = await tools.get("subagent").execute("call", { agent: "call-model-test", task: "review", model: row.model }, undefined, undefined, ctx);
      expect(requests).toEqual([row.request]);
      expect(spawns).toHaveLength(1);
      const args = spawns[0].args;
      expect(args[args.indexOf("--model") + 1]).toBe(row.selector);
      expect(args[args.indexOf("--thinking") + 1]).toBe(row.effort);
      expect(result.details.results[0].model).toBe(row.selector);
      expect(discoverAgents(ctx.cwd, "project").agents.find(item => item.name === "call-model-test")?.model).toBe("standard:high");
    });
  });
}

test("an unresolvable call model starts on file intent and warns once per session", async () => {
  await withExtensionTools(async (tools, ctx) => {
    writeProjectAgent(ctx.cwd, "call-model-test", ["model: standard:high"]);
    ctx.modelRegistry = registry;
    const requests: string[] = [];
    setPaneExecCaptureForTests(async (command, args) => {
      expect(command).toBe("kendex");
      requests.push(args[3]);
      return args[3] === "typo"
        ? { code: 1, stdout: "", stderr: "model-resolution: invalid=request" }
        : capture();
    });
    const warnings = spyOn(console, "warn").mockImplementation(() => undefined);
    const spawns = installMockSpawn([{}, {}]);
    try {
      for (const task of ["review", "review again"]) {
        const result = await tools.get("subagent").execute("call", { agent: "call-model-test", task, model: "typo:medium" }, undefined, undefined, ctx);
        expect(result.isError).not.toBe(true);
        expect(result.details.results[0].model).toBe("custom/chat");
        expect(result.details.results[0].effort).toBe("high");
      }
      expect(requests).toEqual(["typo", "standard", "typo", "standard"]);
      expect(spawns).toHaveLength(2);
      for (const { args } of spawns) {
        expect(args[args.indexOf("--model") + 1]).toBe("custom/chat");
        expect(args[args.indexOf("--thinking") + 1]).toBe("high");
      }
      expect(warnings.mock.calls).toHaveLength(1);
    } finally { warnings.mockRestore(); }
  });
});

test("the shared child preparation transports registry and child directory to core", async () => {
  let calls = 0;
  const model = await resolveAgentModel(agent, undefined, process.cwd(), registry, async (command, args, options) => {
    calls += 1;
    expect(command).toBe("kendex");
    expect(args.slice(0, 5)).toEqual(["tier-model", "pi", "--model", "standard", "--runtime-context-json"]);
    expect(options.cwd).toBe(process.cwd());
    const context = JSON.parse(args[5]);
    expect(context.models.models).toEqual([{ provider: "custom", id: "chat", nativeSelector: "custom/chat", allowed: true, chat: true, isDefault: false }]);
    expect(context.capacity[0].context_window).toBe(123456);
    return capture();
  });
  expect(calls).toBe(1);
  expect(model).toBe("custom/chat");
});

test("exact Haiku frontmatter reaches core unchanged and its warning names the original pin", async () => {
  const cwd = tempRuntime();
  const requested = "anthropic/claude-haiku-4-5";
  const chosen = "anthropic/claude-sonnet-4-6";
  writeSettings(cwd, { subagentModelSource: "frontmatter" });
  writeProjectAgent(cwd, "exact-haiku", [`model: ${requested}`]);
  const declared = discoverAgents(cwd, "project").agents.find(item => item.name === "exact-haiku");
  expect(declared?.model).toBe(requested);
  if (!declared) throw new Error("Pi exact Haiku fixture agent was not discovered");
  const live = modelRegistryFixture(() => [
    { provider: "anthropic", id: "claude-haiku-4-5", contextWindow: 123456 } as Model<Api>,
    { provider: "anthropic", id: "claude-sonnet-4-6", contextWindow: 123456 } as Model<Api>,
  ]);
  const warnings = spyOn(console, "warn").mockImplementation(() => undefined);
  let calls = 0;
  try {
    const resolved = await resolveAgentModel(declared, undefined, cwd, live, async (_command, args, options) => {
      calls += 1;
      expect(args[3]).toBe(requested);
      expect(options.cwd).toBe(cwd);
      expect(JSON.parse(args[5]).models.models.map((model: { nativeSelector: string }) => model.nativeSelector))
        .toEqual([requested, chosen]);
      // Rust's render/runtime regressions establish the policy. This peer
      // checks Pi's intent transport and consumption of that core decision.
      return { code: 0, stdout: JSON.stringify({ ...selected, resolution: {
        tag: "selected", selection: { nativeSelector: chosen },
        diagnostics: [{ code: "excluded-haiku", source: "core:fixture" }],
      } }), stderr: "" };
    });
    expect(calls).toBe(1);
    expect(resolved).toBe(chosen);
    expect(warnings.mock.calls).toHaveLength(1);
    expect(warnings.mock.calls[0][0]).toContain(`requested=${requested} selected=${chosen} causes=excluded-haiku`);
  } finally { warnings.mockRestore(); }
});

for (const failed of [false, true]) {
  test(`native default retains the parent with unknown metadata, failed=${failed}`, async () => {
    const fallback = { ...selected, resolution: { tag: "harness-default", path: { tag: "native-default" }, diagnostics: [] } };
    const broken = failed ? modelRegistryFixture(() => { throw new Error("registry failed"); }) : undefined;
    expect(await resolveAgentModel(agent, "custom/chat", process.cwd(), broken, async (_command, args) => {
      expect(JSON.parse(args[5]).models.tag).toBe(failed ? "failed" : "unsupported");
      return { code: 0, stdout: JSON.stringify(fallback), stderr: "" };
    })).toBe("custom/chat");
  });
}

test("failed registry refresh is passed to core without stale model evidence", async () => {
  const failedRefreshes = [
    { refresh: async () => { throw new Error("refresh rejected"); }, getError: () => undefined },
    { refresh: async () => ({ aborted: true, errors: new Map() }), getError: () => undefined },
    { refresh: async () => ({ aborted: false, errors: new Map([["custom", new Error("catalog failed")]]) }), getError: () => undefined },
    { refresh: async () => ({ aborted: false, errors: new Map() }), getError: () => "configuration failed" },
  ];
  for (const failed of failedRefreshes) {
    const live = { ...registry, ...failed, getAvailable: () => { throw new Error("stale registry must not be read"); } };
    await resolveAgentModel(agent, "custom/chat", process.cwd(), live, async (_command, args) => {
      const evidence = JSON.parse(args[5]).models;
      expect(evidence.tag).toBe("failed");
      expect(evidence.source).toBe("pi:modelRegistry.refresh");
      expect(evidence.cause).not.toContain("stale registry");
      return { code: 0, stdout: JSON.stringify({ ...selected, resolution: { tag: "harness-default", path: { tag: "native-default" }, diagnostics: [] } }), stderr: "" };
    });
  }
});

async function missingCoreExactContract(runtime: typeof settings): Promise<void> {
  const error = Object.assign(new Error("spawn kendex ENOENT"), { code: "ENOENT" });
  const missing = async () => ({ code: 1, stdout: "", stderr: "missing", error });
  expect(await runtime.resolveAgentModel({ ...agent, model: "inherit" }, "custom/chat", process.cwd(), registry, missing)).toBe("custom/chat");
  expect(await runtime.resolveAgentModel({ ...agent, model: "custom/chat" }, undefined, process.cwd(), registry, missing)).toBe("custom/chat");
  await expect(runtime.resolveAgentModel(agent, undefined, process.cwd(), registry, missing)).rejects.toThrow("resolver-missing: command=kendex");
  await expect(runtime.resolveAgentModel({ ...agent, model: "custom/unlisted" }, undefined, process.cwd(), registry, missing)).rejects.toThrow("resolver-missing: command=kendex");
  const openrouter = modelRegistryFixture(() => [{ ...nativeModel, provider: "openrouter", id: "anthropic/claude-sonnet-4" }]);
  const haiku = modelRegistryFixture(() => [{ ...nativeModel, provider: "anthropic", id: "claude-haiku-4-5" }]);
  const rows = [
    { request: "chat", registry, selector: "custom/chat" },
    { request: "openrouter/anthropic/claude-sonnet-4", registry: openrouter, selector: "openrouter/anthropic/claude-sonnet-4" },
    { request: "anthropic/claude-sonnet-4", registry: openrouter, selector: undefined },
    { request: "anthropic/claude-haiku-4-5", registry: haiku, selector: "anthropic/claude-haiku-4-5" },
    { request: "anthropic/claude-haiku-4-5", registry, selector: undefined },
  ];
  for (const row of rows) {
    const resolved = runtime.resolveAgentModel({ ...agent, model: row.request }, undefined, process.cwd(), row.registry, missing);
    if (row.selector === undefined) {
      try { await expect(resolved).rejects.toThrow("resolver-missing: command=kendex"); }
      catch (cause) { throw new Error("Pi qualified exact identity assertion failed", { cause }); }
    } else {
      expect(await resolved).toBe(row.selector);
    }
  }
}

test("missing core permits native inherit and authenticated exact models only", async () => {
  await missingCoreExactContract(settings);
  const mutant = await importRuntimeCopy("settings.ts", '!request.includes("/") && model.id === request', 'true && model.id === request') as typeof settings;
  await expect(missingCoreExactContract(mutant)).rejects.toThrow("Pi qualified exact identity assertion failed");
});

for (const response of [{ ...selected, protocol: "other" }, { ...selected, resolution: { tag: "deferred-class" } }]) {
  test(`invalid core result refuses ${JSON.stringify(response)}`, async () => {
    await expect(resolveAgentModel(agent, undefined, process.cwd(), registry, async () => ({ code: 0, stdout: JSON.stringify(response), stderr: "" }))).rejects.toThrow("model-resolution: invalid=");
  });
}

test("child model and effort use effective directory settings and preserve raw suffix precedence", async () => {
  const root = tempRuntime();
  const child = tempRuntime();
  writeSettings(root, { subagentModelSource: "frontmatter", subagentThinkingSource: "frontmatter" });
  writeSettings(child, { subagentModelSource: "parent", subagentThinkingSource: "parent" });
  for (const [cwd, expected, effort] of [[root, "standard", "high"], [child, "inherit", "low"]]) {
    const config = { ...agent, model: "standard:high", effort: "medium" };
    const raw = settings.selectedModelForAgent(config, "custom/chat", cwd);
    expect(settings.selectedEffortForAgent(config, raw, settings.selectedThinkingLevelForAgent("low", cwd))).toBe(effort);
    await resolveAgentModel(config, "custom/chat", cwd, registry, async (_command, args, options) => {
      expect(args[3]).toBe(expected);
      expect(options.cwd).toBe(cwd);
      return capture();
    });
  }
  expect(settings.selectedEffortForAgent({ ...agent, effort: "medium" }, "standard:high", "low")).toBe("low");
  expect(settings.selectedEffortForAgent({ ...agent, effort: "medium" }, "standard:high", undefined)).toBe("high");
  expect(settings.selectedEffortForAgent({ ...agent, effort: "medium" }, "standard", undefined)).toBe("medium");
});

async function inheritContract(runtime: typeof settings): Promise<void> {
  const warnings = spyOn(console, "warn").mockImplementation(() => undefined);
  const openrouter = "openrouter/anthropic/claude-sonnet-4";
  // Native Pi sessions can use models absent from the child registry.
  const rows = [
    { model: undefined, source: "frontmatter", parent: "custom/unlisted" },
    { model: undefined, source: "frontmatter", parent: openrouter },
    { model: "standard:high", source: "parent", parent: "custom/unlisted" },
    { model: "standard:high", source: "parent", parent: openrouter },
    { model: "standard:high", source: "parent", parent: undefined },
  ];
  try {
    for (const row of rows) {
      const cwd = tempRuntime();
      writeSettings(cwd, { subagentModelSource: row.source });
      const resolved = await runtime.resolveAgentModel({ ...agent, model: row.model }, row.parent, cwd, registry, async (_command, args) => {
        try { expect(args[3]).toBe("inherit"); }
        catch (cause) { throw new Error("Pi inherited request assertion failed", { cause }); }
        const context = JSON.parse(args[5]);
        expect(context.default).toEqual(row.parent === undefined ? { tag: "native-default" } : {
          tag: "observed-session-or-default", selector: row.parent, provider: null,
          id: null, account: "pi-session", host: "pi-process", source: "pi:parent-model",
        });
        return { code: 0, stdout: JSON.stringify({ ...selected, resolution: { tag: "inherit", diagnostics: [] } }), stderr: "" };
      });
      expect(runtime.modelWithoutEffortSuffix(resolved)).toBe(row.parent);
    }
    expect(warnings.mock.calls).toHaveLength(0);
  } finally { warnings.mockRestore(); }
}

test("absent child models and parent settings preserve inheritance without a pin warning", async () => inheritContract(settings));

for (const control of [
  { name: "absent agent model", after: 'false || subagentModelSource(cwd) === "parent"' },
  { name: "parent model source", after: 'agent.model === undefined || false' },
]) {
  test(`${control.name} pin control fails the inherited request fixture`, async () => {
    const before = 'agent.model === undefined || subagentModelSource(cwd) === "parent"';
    const mutant = await importRuntimeCopy("settings.ts", before, control.after) as typeof settings;
    await expect(inheritContract(mutant)).rejects.toThrow("Pi inherited request assertion failed");
  });
}

test("OpenRouter registry, parent and exact pin retain the full provider model selector", async () => {
  const model = { provider: "openrouter", id: "anthropic/claude-sonnet-4", contextWindow: 123456 } as Model<Api>;
  const selector = `${model.provider}/${model.id}`;
  const live = modelRegistryFixture(() => [model]);
  for (const request of ["standard", "inherit", selector]) {
    const resolved = await resolveAgentModel({ ...agent, model: request }, selector, process.cwd(), live, async (_command, args) => {
      expect(args[3]).toBe(request);
      const context = JSON.parse(args[5]);
      expect(context.models.models).toEqual([{ provider: "openrouter", id: "anthropic/claude-sonnet-4", nativeSelector: selector, allowed: true, chat: true, isDefault: false }]);
      expect(context.default).toEqual({ tag: "observed-session-or-default", selector, provider: "openrouter", id: model.id, account: "pi-session", host: "pi-process", source: "pi:parent-model" });
      expect(context.capacity[0].selector).toBe(selector);
      return { code: 0, stdout: JSON.stringify({ ...selected, resolution: { tag: "selected", selection: { nativeSelector: selector }, diagnostics: [] } }), stderr: "" };
    });
    expect(resolved).toBe(selector);
  }
});

async function warningLifetime(runtime: typeof settings): Promise<void> {
  runtime.resetModelWarning();
  const warnings = spyOn(console, "warn").mockImplementation(() => undefined);
  let reads = 0;
  let refreshes = 0;
  const live = modelRegistryFixture(() => {
    if (refreshes !== reads + 1) throw new Error("registry read before refresh completed");
    reads += 1;
    return [nativeModel];
  });
  live.refresh = async (options) => {
    expect(options).toEqual({ allowNetwork: false });
    await Promise.resolve();
    refreshes += 1;
    return { aborted: false, errors: new Map() };
  };
  const diagnostics = [{ code: "model-availability-unknown", source: "pi:fixture", cause: "registry unavailable" }];
  const fallback = { ...selected, resolution: { tag: "harness-default", path: { tag: "native-default" }, diagnostics } };
  const peer = async () => ({ code: 0, stdout: JSON.stringify(fallback), stderr: "" });
  try {
    await runtime.resolveAgentModel(agent, undefined, process.cwd(), live, peer);
    await runtime.resolveAgentModel(agent, undefined, process.cwd(), live, peer);
    try { expect(warnings.mock.calls).toHaveLength(1); }
    catch (cause) { throw new Error("Pi warning lifetime assertion failed", { cause }); }
    expect(warnings.mock.calls[0][0]).toContain("source=pi:fixture cause=registry unavailable");
    try { expect(refreshes).toBe(2); }
    catch (cause) { throw new Error("Pi registry refresh assertion failed", { cause }); }
    expect(reads).toBe(2);
    runtime.resetModelWarning();
    await runtime.resolveAgentModel(agent, undefined, process.cwd(), live, peer);
    expect(warnings.mock.calls).toHaveLength(2);
    const invalid = { ...fallback, resolution: { ...fallback.resolution, diagnostics: [{ code: "" }] } };
    await expect(runtime.resolveAgentModel(agent, undefined, process.cwd(), live, async () => ({ code: 0, stdout: JSON.stringify(invalid), stderr: "" }))).rejects.toThrow("model-resolution: invalid=selector");
  } finally { warnings.mockRestore(); runtime.resetModelWarning(); }
}

test("registry facts refresh and warning receipt lasts until session shutdown", async () => {
  await warningLifetime(settings);
  const mutant = await importRuntimeCopy("settings.ts", "&& !modelWarningEmitted)", "&& true)") as typeof settings;
  await expect(warningLifetime(mutant)).rejects.toThrow("Pi warning lifetime assertion failed");
  const stale = await importRuntimeCopy("settings.ts", "await registry.refresh({ allowNetwork: false })", "({ aborted: false, errors: new Map() })") as typeof settings;
  await expect(warningLifetime(stale)).rejects.toThrow("Pi registry refresh assertion failed");
});

test("missing core rejects ambiguous or unauthenticated matches and keeps directory failures distinct", async () => {
  const error = Object.assign(new Error("spawn kendex ENOENT"), { code: "ENOENT" });
  const missing = async () => ({ code: 1, stdout: "", stderr: "missing", error });
  const sameId = modelRegistryFixture(() => [nativeModel, { ...nativeModel, provider: "other" }]);
  for (const live of [sameId, undefined, modelRegistryFixture(() => { throw new Error("registry failed"); })]) {
    await expect(resolveAgentModel({ ...agent, model: "chat" }, undefined, process.cwd(), live, missing)).rejects.toThrow("resolver-missing: command=kendex");
  }
  const absent = join(tempRuntime(), "absent-child");
  await expect(resolveAgentModel(agent, undefined, absent, registry, missing)).rejects.toThrow("ENOENT");
  for (const model of ["inherit", "custom/chat", "standard"]) {
    let calls = 0;
    await resolveAgentModel({ ...agent, model }, undefined, process.cwd(), registry, async () => { calls += 1; return capture(); });
    expect(calls).toBe(1);
  }
  await expect(resolveAgentModel(agent, undefined, process.cwd(), registry, async () => ({ code: 1, stdout: "", stderr: "permission denied" }))).rejects.toThrow("core-exit=1 cause=permission denied");
});
