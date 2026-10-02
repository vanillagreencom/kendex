// The neutral world the dashboard, Monitor and Agents-tab suites render in:
// a pass-through theme, record and item builders, the settings writers and
// an observer that reads a rendered pane back as `label=value` pairs.
// Nothing here plants a defect; a row that needs one builds it inline.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { execFileSync } from "node:child_process";
import * as childProcess from "node:child_process";
import { spyOn } from "bun:test";
import * as tui from "@earendil-works/pi-tui";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import type { AgentBrowserUiState, AgentPaneStatus, PaneTaskRecord, SubagentDashboardItem } from "../extensions/subagent/types.js";
import { PANE_LAUNCHER_VERSION } from "../extensions/subagent/types.js";
import { tempRuntime } from "./single-agent-fixture.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import type { TaskRegistryReader } from "../extensions/subagent/task-records.js";
import { patchTaskRecordUsage } from "../extensions/subagent/index.js";

export { cleanupTempRuntimes, tempRuntime, writeSettings } from "./single-agent-fixture.js";

export const ABSENT = "ABSENT";

/** Assert prompt scrolling does not repeat Markdown layout after the first frame. */
export function assertPromptLayoutReuse(render: typeof import("../extensions/subagent/browser/agents-tab.js").renderAgentInspector): void {
   const config = agent("layout", false, { systemPrompt: Array.from({ length: 100 }, (_, i) => `Prompt row ${i}`).join("\n") });
   const ui = uiState();
   const spy = spyOn(tui.Markdown.prototype, "render");
   try {
      render(config, new Map(), ui, 80, 25, theme as unknown as Theme);
      const firstCalls = spy.mock.calls.length;
      assert.equal(firstCalls, 1);
      for (let scroll = 1; scroll <= 10; scroll++) {
         ui.inspectorScroll = scroll;
         const lines = render(config, new Map(), ui, 80, 25, theme as unknown as Theme);
         assert.ok(lines.some((line) => line === `Prompt row ${scroll}`));
      }
      assert.equal(spy.mock.calls.length - firstCalls, 0, "scrolling repeated Markdown layout");
   } finally { spy.mockRestore(); }
}

/** Assert scrolling reuses trace wrapping without freezing the visible viewport. */
export function assertTraceLayoutReuse(render: typeof import("../extensions/subagent/browser/monitor-task-detail.js").renderMonitorDetail): void {
   const task = record("layout", "layout-task", "2026-05-14T05:00:00.000Z");
   const cache = new Map([[task.taskId, { items: [{ label: "Trace", text: Array.from({ length: 100 }, (_, i) => `Trace row ${i}`).join("\n"), type: "transcript" as const }] }]]);
   const ui = uiState();
   const spy = spyOn(tui, "wrapTextWithAnsi");
   try {
      render(task, cache, ui, 80, 20, theme as unknown as Theme);
      const firstCalls = spy.mock.calls.length;
      assert.equal(firstCalls, 100);
      for (let scroll = 1; scroll <= 10; scroll++) {
         ui.inspectorScroll = scroll;
         const lines = render(task, cache, ui, 80, 20, theme as unknown as Theme);
         assert.ok(lines.some((line) => line === `Trace row ${scroll}`));
      }
      assert.equal(spy.mock.calls.length - firstCalls, 0, "scrolling repeated trace layout");
   } finally { spy.mockRestore(); }
}

/** Assert the trace cache evicts the least recently viewed task at its bound. */
export function assertMonitorCacheBound(cache: Map<string, import("../extensions/subagent/types.js").MonitorDetailEntry>): void {
   for (let i = 0; i < 16; i++) cache.set(String(i), { loading: true });
   const first = cache.get("0");
   cache.set("16", { error: "fixture-error" });
   assert.equal(cache.size, 16, "trace cache exceeded its bound");
   assert.equal(cache.has("1"), false);
   assert.equal(cache.get("0"), first);
   cache.clear();
   assert.equal(cache.size, 0);
}

/** Count synchronous filesystem work during a warmed renderer call. */
export function filesystemCalls(run: () => void): number[] {
	const spies = [
		spyOn(fs, "readFileSync"), spyOn(fs, "readdirSync"), spyOn(fs, "statSync"),
		spyOn(fs, "realpathSync"), spyOn(fs, "existsSync"),
	];
	try {
		run();
		return spies.map((spy) => spy.mock.calls.length);
	} finally {
		for (const spy of spies) spy.mockRestore();
	}
}

/** Load a disposable production edit with the real package's modules and dependencies. */
export async function importRuntimeCopy(fileName: string, before: string, after: string, additionalEdits: Array<{ before: string; after: string }> = []): Promise<unknown> {
	return import(writeRuntimeCopy(fileName, before, after, additionalEdits));
}

/** Write a disposable production edit for a separate process to load; returns its path. */
export function writeRuntimeCopy(fileName: string, before: string, after: string, additionalEdits: Array<{ before: string; after: string }> = []): string {
	const runtimeDir = resolve(import.meta.dir, "../extensions/subagent");
	const original = fs.readFileSync(join(runtimeDir, fileName), "utf8");
	let modified = original;
	for (const edit of [{ before, after }, ...additionalEdits]) {
		assert.equal(modified.split(edit.before).length - 1, 1, "control must match exactly one production site");
		const next = modified.replace(edit.before, edit.after);
		assert.notEqual(next, modified);
		modified = next;
	}
	assert.notEqual(modified, original);
	const source = modified.replace(/from "(\.{1,2}\/[^\"]+)\.js"/g, (_match, name: string) => `from ${JSON.stringify(resolve(dirname(join(runtimeDir, fileName)), `${name}.ts`))}`);
	const copyDir = tempRuntime();
	// Bare imports resolve from the copy, outside the package's dependency tree.
	fs.symlinkSync(resolve(import.meta.dir, "../node_modules"), join(copyDir, "node_modules"), "dir");
	const copy = join(copyDir, fileName);
	mkdirSync(dirname(copy), { recursive: true });
	writeFileSync(copy, source);
	return copy;
}

/** Check duplicate queueing through the existing pane transport, without launching Pi. */
export async function assertQueuedPaneDedup(runtime: typeof import("../extensions/subagent/pane.js")): Promise<void> {
	const root = tempRuntime();
	// The real Linux cwd check reads this process, whose cwd remains alive.
	const cwd = fs.realpathSync(process.cwd());
	const paneId = "%42";
	const previousTmux = process.env.TMUX;
	process.env.TMUX = join(root, "tmux.sock") + ",0,0";
	runtime.setPaneExecCaptureForTests(async (command, args) => {
		assert.equal(command, "tmux");
		assert.equal(args[0], "display-message", "queue must reuse the seeded pane");
		const format = args.at(-1);
		if (format === "#S") return { code: 0, stdout: "test\n", stderr: "" };
		assert.equal(args[args.indexOf("-t") + 1], paneId);
		if (format === "#{pane_id}") return { code: 0, stdout: `${paneId}\n`, stderr: "" };
		assert.equal(format, "#{pane_pid}");
		return { code: 0, stdout: `${process.pid}\n`, stderr: "" };
	});
	try {
		const tasks = await import("../extensions/subagent/tasks.js");
		const profile = agent("scout", true);
		await tasks.writePaneRegistry(root, { scout: { agent: "scout", paneId, cwd, windowName: "scout", sessionFile: join(root, "session.jsonl"), promptFile: "", launcherFile: "", launcherVersion: PANE_LAUNCHER_VERSION, startedAt: "2026-05-14T05:00:00Z" } });
		await tasks.writeTaskRegistry(root, { active: record("scout", "active", "2026-05-14T05:00:00Z", { status: "running", kind: "pane", paneId, task: "map files" }) });
		const result = await runtime.queuePersistentPaneTask(root, "test", cwd, profile, "map files", undefined, undefined, undefined, { events: { emit() {} } } as unknown as Parameters<typeof runtime.queuePersistentPaneTask>[8]);
		assert.deepEqual([result.taskId, result.duplicate], ["active", true], "working task must remain the only queued task");
	} finally {
		runtime.setPaneExecCaptureForTests();
		if (previousTmux === undefined) delete process.env.TMUX;
		else process.env.TMUX = previousTmux;
	}
}

/** A reset removes a queued pane's handoff file; the diagnostics reader must stop calling it queued. */
export async function assertMissingArtifactStatus(runtime: typeof import("../extensions/subagent/tasks.js")): Promise<void> {
	const root = tempRuntime();
	const inboxFile = join(root, "handoff.md");
	const queued = record("scout", "queued", "2026-05-14T05:00:00Z", { status: "queued", kind: "pane", paneId: "%1", inboxFile });
	writeFileSync(inboxFile, "map files");
	await runtime.writeTaskRegistry(root, { queued });
	fs.unlinkSync(inboxFile);
	const refreshed = await runtime.refreshTaskDiagnostics(root, queued);
	assert.equal(refreshed.record.status, "unknown");
}

/** Immutable pre-change components, also fetched by the existing CI suite. */
export const BENCHMARK_BASELINE = "f8b9eff8b1aaf7c8698fdead68c00f6eb7c12382";

/** Load baseline components from git objects without changing a checkout. */
export async function importMainRuntime(repo = resolve(import.meta.dir, "../../..")): Promise<{
	pane: typeof import("../extensions/subagent/pane.js");
	dispatch: typeof import("../extensions/subagent/dispatch.js");
	runner: typeof import("../extensions/subagent/runner.js");
	config: typeof import("../extensions/subagent/package-config.js");
	ref: string;
}> {
	const root = tempRuntime();
	const env = { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root };
	const ref = execFileSync("git", ["rev-parse", `${BENCHMARK_BASELINE}^{commit}`], { cwd: repo, env, encoding: "utf8" }).trim();
	const archive = execFileSync("git", ["archive", ref, "pi-extensions/pi-agents-tmux/extensions", "pi-extensions/pi-agents-tmux/scripts", "pi-extensions/pi-agents-tmux/package.json"], { cwd: repo, env, maxBuffer: 16 * 1024 * 1024 });
	execFileSync("tar", ["-x", "-C", root], { input: archive, env });
	const pkg = join(root, "pi-extensions/pi-agents-tmux");
	fs.symlinkSync(resolve(import.meta.dir, "../node_modules"), join(pkg, "node_modules"), "dir");
	const runtime = join(pkg, "extensions/subagent");
	const paneFile = join(runtime, "pane.ts");
	const before = "cwd: options?.cwd, shell: false";
	const source = fs.readFileSync(paneFile, "utf8");
	// Main lacks a capture env option. Instrument only its child environment so
	// both measured components run the same isolated faux bridge workload.
	assert.equal(source.split(before).length - 1, 1, "main capture environment instrumentation must match once");
	fs.writeFileSync(paneFile, source.replace(before, "cwd: options?.cwd, env: options?.env, shell: false"));
	return {
		pane: await import(join(runtime, "pane.ts")), dispatch: await import(join(runtime, "dispatch.ts")),
		runner: await import(join(runtime, "runner.ts")), config: await import(join(runtime, "package-config.ts")), ref,
	};
}

/** Count reads of registry content through both Node file APIs, without replacing their behavior. */
export async function taskRegistryReads(root: string, run: () => Promise<unknown>): Promise<number> {
	const filePath = taskRegistryPath(root);
	const sync = spyOn(fs, "readFileSync");
	const asyncRead = spyOn(fs.promises, "readFile");
	try {
		await run();
		return [...sync.mock.calls, ...asyncRead.mock.calls].filter(([file]) => String(file) === filePath).length;
	} finally {
		sync.mockRestore();
		asyncRead.mockRestore();
	}
}

/** Pin the no-content-read contract on the real completion poll. */
export async function assertCachedCompletionPoll(runtime: Pick<typeof import("../extensions/subagent/tasks.js"), "pollPaneCompletions" | "writeTaskRegistry">): Promise<void> {
	const root = tempRuntime();
	mkdirSync(join(root, "outbox"), { recursive: true });
	await runtime.writeTaskRegistry(root, {});
	const pi = { events: { emit() {} }, sendMessage() {} } as unknown as Parameters<typeof runtime.pollPaneCompletions>[1];
	assert.equal(await taskRegistryReads(root, () => runtime.pollPaneCompletions(root, pi)), 0);
	assert.equal(await taskRegistryReads(root, () => runtime.pollPaneCompletions(root, pi)), 0);
}

/** Pin the cached read and mutable-copy contract on the real registry update. */
export async function assertCachedRegistryUpdate(runtime: Pick<typeof import("../extensions/subagent/tasks.js"), "updateTaskRegistry" | "writeTaskRegistry">, reader: TaskRegistryReader): Promise<void> {
	const root = tempRuntime();
	await runtime.writeTaskRegistry(root, { child: { agent: "engineer", taskId: "child", task: "work", status: "running", createdAt: "2026-09-30T00:00:00Z", filesChanged: ["before.ts"] } });
	const snapshot = reader.read(root);
	assert.equal(await taskRegistryReads(root, () => runtime.updateTaskRegistry(root, (records) => {
		records.child!.filesChanged!.push("after.ts");
	})), 0);
	assert.deepEqual(snapshot.child?.filesChanged, ["before.ts"]);
	assert.equal(await taskRegistryReads(root, async () => {
		assert.deepEqual(reader.read(root).child?.filesChanged, ["before.ts", "after.ts"]);
	}), 0);
}

/** Drive patchDashboardUsage's per-child writes and the real following poll. */
export async function assertSequentialUsageUpdates(runtime: Pick<typeof import("../extensions/subagent/tasks.js"), "updateTaskRegistry" | "writeTaskRegistry" | "pollPaneCompletions" | "readTaskRegistry">, reader: TaskRegistryReader): Promise<void> {
	const root = tempRuntime();
	mkdirSync(join(root, "outbox"), { recursive: true });
	const records = Object.fromEntries(["engineer", "scout", "planner"].map((agent) => [agent, {
		taskId: agent, agent, task: "work", status: "running" as const, createdAt: "2026-09-30T00:00:00Z",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
	}]));
	await runtime.writeTaskRegistry(root, records);
	const before = reader.read(root);
	const pi = { events: { emit() {} }, sendMessage() {} } as unknown as Parameters<typeof runtime.pollPaneCompletions>[1];
	assert.equal(await taskRegistryReads(root, async () => {
		for (const taskId of Object.keys(records)) {
			const updated = await runtime.updateTaskRegistry(root, (registry) => {
				assert.equal(patchTaskRecordUsage(registry, taskId, { usage: { ...records[taskId]!.usage, input: 4, output: 2, turns: 1 }, model: "test-model" }), true);
			});
			const written = reader.read(root);
			assert.equal(written[taskId]?.usage?.input, 4);
			assert.equal(Object.isFrozen(written[taskId]?.usage), true);
			// The caller may retain and mutate both the returned record and its nested fields.
			updated[taskId]!.usage!.input = 999;
			updated[taskId]!.model = "caller-model";
			assert.equal(reader.read(root), written);
			assert.equal(written[taskId]?.usage?.input, 4);
			assert.equal(written[taskId]?.model, "test-model");
		}
		assert.equal(await runtime.pollPaneCompletions(root, pi), 0);
	}), 0, "local usage writes and the following poll must read no registry content");
	assert.deepEqual(Object.values(before).map((record) => record.usage?.input), [0, 0, 0]);
	assert.deepEqual(Object.values(await runtime.readTaskRegistry(root)).map((record) => [record.usage?.input, record.model]), [[4, "test-model"], [4, "test-model"], [4, "test-model"]]);
}

/** Exercise reuse, cross-runtime eviction and teardown through the reader's public API. */
export async function assertRegistryReaderCache(reader: TaskRegistryReader): Promise<void> {
	const roots = [tempRuntime(), tempRuntime()];
	for (const [index, root] of roots.entries()) writeFileSync(taskRegistryPath(root), JSON.stringify({ [index]: { taskId: String(index) } }));
	assert.deepEqual(reader.read(roots[0]!), { 0: { taskId: "0" } });
	assert.equal(await taskRegistryReads(roots[0]!, async () => reader.read(roots[0]!)), 0);
	assert.deepEqual(reader.read(roots[1]!), { 1: { taskId: "1" } });
	assert.equal(await taskRegistryReads(roots[0]!, async () => reader.read(roots[0]!)), 1);
	reader.clear();
	assert.equal(await taskRegistryReads(roots[0]!, async () => reader.read(roots[0]!)), 1);
	const content = JSON.stringify({ child: { taskId: "child", filesChanged: ["written.ts"] } });
	writeFileSync(taskRegistryPath(roots[0]!), content);
	reader.rememberWrite(roots[0]!, content);
	assert.equal(await taskRegistryReads(roots[0]!, async () => {
		const copy = reader.mutableCopy(roots[0]!);
		copy.child!.filesChanged!.push("caller.ts");
		assert.deepEqual(reader.read(roots[0]!).child?.filesChanged, ["written.ts"]);
	}), 0);
}

/** Deliver Node's file-check notification without waiting for its polling clock. */
export function notifyFileCheck(watch: { mock: { calls: unknown[][] } }, filePath: string): void {
	const call = watch.mock.calls.find((args) => String(args[0]) === filePath);
	assert.ok(call, `file check missing: ${filePath}`);
	const listener = call.at(-1);
	assert.equal(typeof listener, "function");
	const stat = fs.existsSync(filePath) ? fs.statSync(filePath) : new fs.Stats();
	(listener as (current: fs.Stats, previous: fs.Stats) => void)(stat, stat);
}

/** Model kendex's bulk WriteFile agent updates without waiting for Node's polling clock. */
export function assertBulkDiscoveryUpdate(runtime: Pick<typeof import("../extensions/subagent/agents.js"), "discoverAgents" | "cachedAgentDiscovery">, combinations: number): void {
	withTempPiUserDir(() => {
		const roots = Array.from({ length: combinations }, () => tempRuntime());
		const names = Array.from({ length: 17 }, (_, index) => `agent-${index}`);
		const watch = spyOn(fs, "watchFile");
		try {
			for (const cwd of roots) {
				for (const name of names) writeProjectAgent(cwd, name, ["pane: false"]);
				runtime.discoverAgents(cwd, "both");
				for (const name of names) writeProjectAgent(cwd, name, ["pane: true", "allowed-subagents: scout"]);
			}
			const calls = filesystemCalls(() => {
				for (const cwd of roots) {
					for (const name of names) notifyFileCheck(watch, join(cwd, `.pi/agents/${name}.md`));
				}
			});
			assert.equal(calls[0], names.length * roots.length, "each changed file is read once");
			assert.equal(calls[1], 0, "listed-file notifications must not scan directories");
			// notifyFileCheck takes one stat; discovery may take only the changed file's stat.
			assert.equal(calls[2], 2 * names.length * roots.length, "unchanged files must not be checked again");
			for (const cwd of roots) {
				const agents = runtime.cachedAgentDiscovery(cwd, "project")?.agents;
				assert.equal(agents?.length, names.length);
				assert.deepEqual(agents?.map(({ name, pane, allowedSubagents }) => ({ name, pane, allowedSubagents })),
					names.toSorted().map((name) => ({ name, pane: true, allowedSubagents: ["scout"] })));
			}
		} finally {
			for (const check of watch.mock.calls) {
				fs.unwatchFile(check[0] as string, check.at(-1) as (current: fs.Stats, previous: fs.Stats) => void);
			}
			watch.mockRestore();
		}
	});
}

/** Exercise inventory identity and release of every evicted path/listener pair. */
export function assertDiscoveryEviction(runtime: Pick<typeof import("../extensions/subagent/agents.js"), "discoverAgents" | "cachedAgentDiscovery">): void {
	withTempPiUserDir(() => {
		const roots = Array.from({ length: 9 }, () => tempRuntime());
		const watch = spyOn(fs, "watchFile");
		const unwatch = spyOn(fs, "unwatchFile");
		const inventory = (index: number) => [
			{ name: `local-${index}`, filePath: join(roots[index]!, `.pi/agents/local-${index}.md`) },
			{ name: "scout", filePath: join(roots[index]!, ".pi/agents/scout.md") },
		];
		const readInventory = (index: number) => runtime.cachedAgentDiscovery(roots[index]!, "project")?.agents
			.map(({ name, filePath }) => ({ name, filePath }));
		let evictedChecks: unknown[][] = [];
		try {
			for (const [index, cwd] of roots.entries()) {
				writeProjectAgent(cwd, "scout");
				writeProjectAgent(cwd, `local-${index}`);
				const start = watch.mock.calls.length;
				const discovery = runtime.discoverAgents(cwd, "project");
				assert.deepEqual(discovery.agents.map(({ name, filePath }) => ({ name, filePath })), inventory(index));
				if (index === 1) evictedChecks = watch.mock.calls.slice(start);
				if (index === 7) assert.deepEqual(readInventory(0), inventory(0));
			}
			assert.deepEqual(readInventory(0), inventory(0));
			assert.deepEqual(readInventory(8), inventory(8));
			assert.equal(runtime.cachedAgentDiscovery(roots[1]!, "project"), undefined);
			// The captured subscriptions include present directories and absent candidates.
			for (const relative of [".pi/agents/scout.md", ".pi/agents", ".claude/agents"]) {
				assert.ok(evictedChecks.some((args) => args[0] === join(roots[1]!, relative)));
			}
			for (const check of evictedChecks) {
				assert.ok(unwatch.mock.calls.some((args) => args[0] === check[0] && args[1] === check.at(-1)),
					`evicted subscription still registered: ${check[0]}`);
			}
		} finally {
			// Controls can retain subscriptions; release those too before deleting their files.
			for (const check of watch.mock.calls) {
				fs.unwatchFile(check[0] as string, check.at(-1) as (current: fs.Stats, previous: fs.Stats) => void);
			}
			watch.mockRestore();
			unwatch.mockRestore();
		}
	});
}

/** A managed agent and an editor response, without a kendex process. */
export function managedEditFixture(): { root: string; config: AgentConfig; ctx: ExtensionContext } {
   const root = tempRuntime();
   const filePath = join(root, ".pi/agents/managed.md");
   mkdirSync(dirname(filePath), { recursive: true });
   writeFileSync(filePath, "---\nname: managed\n---\nNever edit this file directly; kendex refresh writes it.\n");
   writeFileSync(join(root, "kendex.toml"), "[agent-frontmatter.pi]\n");
   const config = agent("managed", false, { filePath });
   const ctx = { cwd: root, ui: { editor: async () => "model: test/model\ndeny-tools: bash\ncolor: green" } } as unknown as ExtensionContext;
   return { root, config, ctx };
}

/** Drive an unfinished refresh callback and prove the editor yields before it exits. */
export async function assertAsyncManagedEdit(runtime: Pick<typeof import("../extensions/subagent/browser/frontmatter-editor.js"), "editAgentFrontmatterOverrides">): Promise<void> {
   const { root, config, ctx } = managedEditFixture();
   let complete: ((error: Error | null, stdout: string, stderr: string) => void) | undefined;
   let started!: () => void;
   const ready = new Promise<void>((resolve) => { started = resolve; });
   const asynchronous = spyOn(childProcess, "execFile").mockImplementation(((command: string, args: string[], options: childProcess.ExecFileOptions, callback: typeof complete) => {
      complete = callback;
      started();
      return {} as childProcess.ChildProcess;
   }) as typeof childProcess.execFile);
   const synchronous = spyOn(childProcess, "spawnSync").mockImplementation(() => {
      started();
      return { status: 0, stdout: "", stderr: "", pid: 0, output: [null, "", ""], signal: null };
   });
   const save = runtime.editAgentFrontmatterOverrides(ctx, config);
   try {
      await ready;
      assert.equal(synchronous.mock.calls.length, 0, "managed save used a blocking process");
      assert.equal(asynchronous.mock.calls.length, 1);
      const [command, args, options] = asynchronous.mock.calls[0]!;
      assert.equal(command, "kendex");
      assert.deepEqual(args, ["refresh", "--scope", "project"]);
      assert.equal((options as childProcess.ExecFileOptions).cwd, root);
      assert.equal((options as childProcess.ExecFileOptions).timeout, 120_000);
      assert.equal((options as childProcess.ExecFileOptions).killSignal, "SIGKILL");
      assert.equal((options as childProcess.ExecFileOptions).maxBuffer, 1024 * 1024);
      let settled = false;
      void save.then(() => { settled = true; });
      await Promise.resolve();
      assert.equal(settled, false, "save must await the refresh result");
      assert.ok(fs.readFileSync(join(root, "kendex.toml"), "utf8").includes('model = "test/model"'));
      complete!(null, "", "");
      complete = undefined;
      assert.equal(typeof await save, "string");
   } finally {
      complete?.(null, "", "");
      await save;
      synchronous.mockRestore();
      asynchronous.mockRestore();
   }
}

export const theme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (_tone: string, text: string) => text,
	inverse: (text: string) => text,
};

/** Observe semantic colors without an ANSI-dependent assertion. */
export const toneTheme = { ...theme, fg: (tone: string, text: string) => `<${tone}>${text}</${tone}>` };

export function stripAnsi(text: string): string {
	return text.replace(/\x1b\[[0-9;]*m/g, "");
}

export function writeProjectAgent(cwd: string, name: string, frontmatter: string[] = []): void {
	mkdirSync(join(cwd, ".pi", "agents"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "agents", `${name}.md`), ["---", `name: ${name}`, `description: ${name} agent`, ...frontmatter, "---", ""].join("\n"));
}

// The user-level settings file lives under PI_CODING_AGENT_DIR; a temp dir
// there keeps the real user settings out of every row.
export function withTempPiUserDir<T>(fn: (userDir: string) => T): T {
	const previous = process.env.PI_CODING_AGENT_DIR;
	const userDir = tempRuntime();
	process.env.PI_CODING_AGENT_DIR = userDir;
	clearPackageConfigCache();
	try {
		return fn(userDir);
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		clearPackageConfigCache();
	}
}

export function writeUserSettings(userDir: string, config: Record<string, unknown>): void {
	mkdirSync(userDir, { recursive: true });
	writeFileSync(join(userDir, "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}));
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

export function record(agent: string, taskId: string, createdAt: string, patch: Partial<PaneTaskRecord> = {}): PaneTaskRecord {
	return {
		taskId,
		agent,
		task: `Task for ${agent}`,
		status: "completed",
		createdAt,
		completedAt: createdAt,
		updatedAt: createdAt,
		...patch,
	};
}

export function agent(name: string, pane = false, patch: Partial<AgentConfig> = {}): AgentConfig {
	return { name, pane, description: `${name} agent`, systemPrompt: "", source: "project", filePath: `${name}.md`, ...patch };
}

export function uiState(patch: Partial<AgentBrowserUiState> = {}): AgentBrowserUiState {
	return {
		inspectorScroll: 0,
		pane: "inspector",
		tab: "agents",
		scope: "both",
		selected: 0,
		scroll: 0,
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
		...patch,
	};
}

export function livePaneStatus(agentName: string, patch: Partial<NonNullable<AgentPaneStatus["entry"]>> = {}, live = true): AgentPaneStatus {
	return {
		live,
		entry: {
			agent: agentName,
			paneId: "%1",
			windowName: `agent-${agentName}`,
			cwd: process.cwd(),
			sessionFile: "/tmp/transcript.jsonl",
			promptFile: "/tmp/prompt.md",
			launcherFile: "/tmp/launcher.sh",
			startedAt: "2026-05-14T05:00:00.000Z",
			...patch,
		},
	};
}

export function dashboardItem(patch: Partial<SubagentDashboardItem> = {}): SubagentDashboardItem {
	return {
		agent: "reviewer-arch",
		kind: "oneshot",
		status: "completed",
		taskId: "reviewer-arch-1700000000-aaaaaaaa",
		updatedAt: "2026-05-14T05:02:00.000Z",
		...patch,
	};
}

// A rendered pane read back as `label` -> `value` for every line shaped
// `Label   value` (two or more spaces), `Label:   value`, or two such
// pairs four or more spaces apart. A label the render does not carry reads
// ABSENT through `fields`, so a row can pin an absence without a regex over
// the whole pane. The first occurrence of a label wins.
export function labelledLines(rendered: string): Map<string, string> {
	const out = new Map<string, string>();
	const set = (label: string, value: string) => {
		if (!out.has(label)) out.set(label, value.trim());
	};
	for (const raw of stripAnsi(rendered).split("\n")) {
		const line = raw.trim();
		const spaced = line.match(/^([A-Za-z][A-Za-z #]*?)\s{2,}(.*)$/);
		if (spaced) {
			set(spaced[1]!, spaced[2]!);
			continue;
		}
		const pairs = line.split(/\s{4,}/).map((part) => part.match(/^([A-Za-z][A-Za-z #]*?): (.*)$/));
		if (pairs.length > 1 && pairs.every(Boolean)) {
			for (const pair of pairs) set(pair![1]!, pair![2]!);
			continue;
		}
		const whole = line.match(/^([A-Za-z][A-Za-z #]*?):\s+(.*)$/);
		if (whole) set(whole[1]!, whole[2]!);
	}
	return out;
}

export function fields(map: Map<string, string>, keys: string[]): Record<string, string> {
	const out: Record<string, string> = {};
	for (const key of keys) out[key] = map.get(key) ?? ABSENT;
	return out;
}
