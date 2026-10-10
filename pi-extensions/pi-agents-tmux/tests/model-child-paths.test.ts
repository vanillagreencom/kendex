import { afterEach, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import * as discovery from "../extensions/subagent/agents.js";
import * as runner from "../extensions/subagent/runner.js";
import * as pane from "../extensions/subagent/pane.js";
import * as agentsCommand from "../extensions/subagent/agents-command.js";
import { runtimeDirForContext } from "../extensions/subagent/settings.js";
import { readPaneRegistry } from "../extensions/subagent/tasks.js";
import { paneSessionPath } from "../extensions/subagent/paths.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime, withTempPiUserDir, writeProjectAgent } from "./browser-fixture.js";
import { modelRegistryFixture } from "./single-agent-fixture.js";
import { createHarness, fakeCtx, teardown } from "./extension-fixture.js";

const agent: AgentConfig = { name: "resolver-test", description: "model test", model: "standard:high", pane: false, source: "project", filePath: "resolver-test.md", systemPrompt: "" };
const registry = modelRegistryFixture(() => [{ provider: "custom", id: "chat", contextWindow: 123456 } as Model<Api>]);
const oldTmux = process.env.TMUX;
afterEach(() => { runner.setSingleAgentSpawnForTests(); pane.setPaneExecCaptureForTests(); if (oldTmux === undefined) delete process.env.TMUX; else process.env.TMUX = oldTmux; cleanupTempRuntimes(); });

function classIntent(runtime: typeof discovery): void {
  withTempPiUserDir(() => {
    const root = tempRuntime();
    writeProjectAgent(root, agent.name, ["model: fable:high"]);
    try { expect(runtime.discoverAgents(root, "project").agents.find(item => item.name === agent.name)?.model).toBe("fable:high"); }
    catch (cause) { throw new Error("Pi discovery class-intent assertion failed", { cause }); }
  });
}

test("discovery retains class intent for the core resolver", async () => {
  classIntent(discovery);
  const mutant = await importRuntimeCopy("agents.ts", "return trimmed;", "return trimmed === \"fable:high\" ? undefined : trimmed;") as typeof discovery;
  expect(() => classIntent(mutant)).toThrow("Pi discovery class-intent assertion failed");
});

async function childPath(kind: "background" | "pane", fallback: boolean, runtime: typeof runner | typeof pane): Promise<void> {
  const root = tempRuntime();
  const calls: string[][] = [];
  const capture: Parameters<typeof pane.setPaneExecCaptureForTests>[0] = async (command, args, options) => {
    if (command === "kendex") {
      calls.push(args);
      expect(options?.cwd).toBe(root);
      expect(args[3]).toBe("standard");
      const resolution = fallback ? { tag: "harness-default", path: { tag: "native-default" }, diagnostics: [] }
        : { tag: "selected", selection: { nativeSelector: "custom/chat" }, diagnostics: [] };
      return { code: 0, stdout: JSON.stringify({ protocol: "model-resolution-v1", harness: "pi", resolution }), stderr: "" };
    }
    if (command === "bash") {
      expect(args).toEqual(["-lc", "command -v pi-bridge || true"]);
      return { code: 0, stdout: "pi-bridge\n", stderr: "" };
    }
    if (args[0] === "list" && args[1] === "--json") {
      expect(basename(command)).toMatch(/^pi-bridge(?:\.js)?$/);
      expect(args).toEqual(["list", "--json"]);
      return { code: 0, stdout: JSON.stringify([{ sessionFile: paneSessionPath(root, agent.name), pid: process.pid, stale: false }]), stderr: "" };
    }
    expect(command).toBe("tmux");
    return { code: 0, stdout: args[0] === "list-panes" ? "" : args[0] === "split-window" ? "%42" : "%10", stderr: "" };
  };
  let argv: string[] | undefined;
  let script: string | undefined;
  if (kind === "background") {
    const r = runtime as typeof runner;
    pane.setPaneExecCaptureForTests(capture);
    r.setSingleAgentSpawnForTests(((_command: string, args: string[]) => {
      argv = args;
      const proc = Object.assign(new EventEmitter(), { kill: () => true, killed: false, stdout: new EventEmitter(), stderr: new EventEmitter() });
      queueMicrotask(() => proc.emit("close", 0, null));
      return proc;
    }) as unknown as Parameters<typeof runner.setSingleAgentSpawnForTests>[0]);
    try {
      const pi = { events: { emit: () => undefined }, getActiveTools: () => [] } as unknown as Parameters<typeof runner.runSingleAgent>[9];
      await r.runSingleAgent(root, root, [agent], agent.name, "inspect", root, undefined, undefined, undefined, pi, undefined, undefined,
        results => ({ agentScope: "project", mode: "single", projectAgentsDir: null, results }), undefined, false, registry);
    } finally { r.setSingleAgentSpawnForTests(); }
  } else {
    const p = runtime as typeof pane;
    process.env.TMUX = "fixture,0,0";
    p.setPaneExecCaptureForTests(capture);
    try { const entry = await p.ensurePersistentPane(root, "parent", root, { ...agent, pane: true }, undefined, undefined, [], registry); script = readFileSync(entry.launcherFile, "utf8"); }
    finally { p.setPaneExecCaptureForTests(); }
  }
  try { expect(calls).toHaveLength(1); }
  catch (cause) { throw new Error(`${kind} model core-call assertion failed`, { cause }); }
  if (kind === "background") {
    expect(argv).toBeDefined();
    expect(argv!.includes("--model")).toBe(!fallback);
    if (!fallback) expect(argv![argv!.indexOf("--model") + 1]).toBe("custom/chat");
    expect(argv![argv!.indexOf("--thinking") + 1]).toBe("high");
  } else {
    expect(script).toBeDefined();
    expect(script!.includes("--model")).toBe(!fallback);
    if (!fallback) expect(script).toContain("custom/chat");
    expect(script).toContain("high");
  }
}

for (const kind of ["background", "pane"] as const) {
  test(`${kind} resolves the current registry before child arguments`, async () => childPath(kind, false, kind === "background" ? runner : pane));
  test(`${kind} native default starts without inventing a model id`, async () => childPath(kind, true, kind === "background" ? runner : pane));
  test(`${kind} bypass control fails the core-call and child-argument assertions`, async () => {
    const before = kind === "background" ? "const selectedModel = await resolveAgentModel(agent, parentModel, cwd ?? defaultCwd, modelRegistry, execCapture);"
      : "const selectedModel = await resolveAgentModel(agent, parentModel, cwd, modelRegistry, execCapture);";
    const mutant = await importRuntimeCopy(kind === "background" ? "runner.ts" : "pane.ts", before, "const selectedModel = agent.model;") as typeof runner | typeof pane;
    await expect(childPath(kind, false, mutant)).rejects.toThrow(`${kind} model core-call assertion failed`);
  });
}

async function commandPath(kind: "start" | "send", runtime: typeof agentsCommand): Promise<void> {
  const harness = createHarness({});
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  const messages: Array<{ details?: unknown }> = [];
  const ctx = fakeCtx(harness) as ExtensionCommandContext;
  ctx.modelRegistry = registry as ExtensionCommandContext["modelRegistry"];
  const runtimeRoot = runtimeDirForContext(ctx);
  let coreCalls = 0;
  process.env.TMUX = "fixture,0,0";
  writeProjectAgent(ctx.cwd, agent.name, ["model: standard:high", "pane: true"]);
  pane.setPaneExecCaptureForTests(async (command, args, options) => {
    if (command === "kendex") {
      coreCalls += 1;
      expect(options?.cwd).toBe(ctx.cwd);
      expect(args[3]).toBe("standard");
      const context = JSON.parse(options!.input!);
      try {
        expect(context.models.tag).toBe("complete");
        expect(context.models.models).toEqual([{ provider: "custom", id: "chat", nativeSelector: "custom/chat", allowed: true, chat: true, isDefault: false }]);
      } catch (cause) { throw new Error(`${kind} command registry assertion failed`, { cause }); }
      return { code: 0, stdout: JSON.stringify({ protocol: "model-resolution-v1", harness: "pi", resolution: { tag: "selected", selection: { nativeSelector: "custom/chat" }, diagnostics: [] } }), stderr: "" };
    }
    if (command === "bash") {
      expect(args).toEqual(["-lc", "command -v pi-bridge || true"]);
      return { code: 0, stdout: "pi-bridge\n", stderr: "" };
    }
    if (args[0] === "list" && args[1] === "--json") {
      expect(basename(command)).toMatch(/^pi-bridge(?:\.js)?$/);
      return { code: 0, stdout: JSON.stringify([{ sessionFile: paneSessionPath(runtimeRoot, agent.name), pid: process.pid, stale: false }]), stderr: "" };
    }
    expect(command).toBe("tmux");
    return { code: 0, stdout: args[0] === "list-panes" ? "" : args[0] === "split-window" ? "%42" : "%10", stderr: "" };
  });
  try {
    const pi = {
      registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
      sendMessage: (message: { details?: unknown }) => messages.push(message),
      getActiveTools: () => [], getThinkingLevel: () => undefined,
      events: { emit: () => undefined },
    } as unknown as ExtensionAPI;
    runtime.registerAgentsCommands({ pi, agentCommandCompletions: [], agentsArgumentCompletions: () => null,
      dashboardState: { items: {}, visible: true, mode: "normal" }, formatRelativeTime: () => "",
      persistRuntimeSnapshot: async () => undefined, removeDashboardAgent: () => undefined, syncDashboard: () => undefined });
    await commands.get(`agents:${kind}`)!.handler(`${agent.name}${kind === "send" ? " inspect" : ""}`, ctx);
    expect(coreCalls).toBe(1);
    const result = messages.at(-1)?.details;
    if (result && typeof result === "object" && "error" in result) throw new Error(String(result.error));
    expect(result).toMatchObject({ action: kind, agent: agent.name });
    const launched = (await readPaneRegistry(runtimeRoot))[agent.name];
    expect(launched.model).toBe("custom/chat");
    expect(launched.effort).toBe("high");
    expect(readFileSync(launched.launcherFile, "utf8")).toContain("custom/chat");
  } finally { pane.setPaneExecCaptureForTests(); teardown(harness); }
}

for (const kind of ["start", "send"] as const) {
  test(`/agents:${kind} resolves the active registry before launching a class pane`, async () => {
    await commandPath(kind, agentsCommand);
  });
  test(`/agents:${kind} missing-registry control fails the command fixture`, async () => {
    const call = kind === "start"
      ? "ensurePersistentPane(runtimeRoot, parentSessionId, ctx.cwd, agent, parentModel, parentThinkingLevel, pi.getActiveTools(), ctx.modelRegistry)"
      : "queuePersistentPaneTask(runtimeRoot, parentSessionId, ctx.cwd, agent, task, undefined, parentModel, parentThinkingLevel, pi, pi.getActiveTools(), ctx.modelRegistry)";
    const mutant = await importRuntimeCopy("agents-command.ts", call, call.replace(", ctx.modelRegistry)", ", undefined)")) as typeof agentsCommand;
    await expect(commandPath(kind, mutant)).rejects.toThrow(`${kind} command registry assertion failed`);
  });
}
