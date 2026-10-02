import { afterEach, expect, spyOn, test } from "bun:test";
import { join } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import * as settings from "../extensions/subagent/settings.js";
import { resetModelWarning, resolveAgentModel } from "../extensions/subagent/settings.js";
import { cleanupTempRuntimes, modelRegistryFixture, tempRuntime, writeSettings } from "./single-agent-fixture.js";
import { importRuntimeCopy } from "./browser-fixture.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";

const agent = { name: "runtime", model: "standard", source: "project" } as AgentConfig;
const nativeModel = { provider: "custom", id: "chat", contextWindow: 123456 } as Model<Api>;
const registry = modelRegistryFixture(() => [nativeModel]);
const selected = { protocol: "model-resolution-v1", harness: "pi", resolution: { tag: "selected", selection: { nativeSelector: "custom/chat" }, diagnostics: [] } };
const capture = async () => ({ code: 0, stdout: JSON.stringify(selected), stderr: "" });
afterEach(() => { resetModelWarning(); clearPackageConfigCache(); cleanupTempRuntimes(); });

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

test("missing core permits native inherit and authenticated exact models only", async () => {
  const error = Object.assign(new Error("spawn kendex ENOENT"), { code: "ENOENT" });
  const missing = async () => ({ code: 1, stdout: "", stderr: "missing", error });
  expect(await resolveAgentModel({ ...agent, model: "inherit" }, "custom/chat", process.cwd(), registry, missing)).toBe("custom/chat");
  expect(await resolveAgentModel({ ...agent, model: "custom/chat" }, undefined, process.cwd(), registry, missing)).toBe("custom/chat");
  await expect(resolveAgentModel(agent, undefined, process.cwd(), registry, missing)).rejects.toThrow("resolver-missing: command=kendex");
  await expect(resolveAgentModel({ ...agent, model: "custom/unlisted" }, undefined, process.cwd(), registry, missing)).rejects.toThrow("resolver-missing: command=kendex");
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
  for (const [cwd, expected, effort] of [[root, "standard", "high"], [child, "custom/chat", "low"]]) {
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
