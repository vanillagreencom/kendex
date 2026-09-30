// The neutral world the dashboard, Monitor and Agents-tab suites render in:
// a pass-through theme, record and item builders, the settings writers and
// an observer that reads a rendered pane back as `label=value` pairs.
// Nothing here plants a defect; a row that needs one builds it inline.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { spyOn } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import type { AgentBrowserUiState, AgentPaneStatus, PaneTaskRecord, SubagentDashboardItem } from "../extensions/subagent/types.js";
import { tempRuntime } from "./single-agent-fixture.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import type { TaskRegistryReader } from "../extensions/subagent/task-records.js";
import { patchTaskRecordUsage } from "../extensions/subagent/index.js";

export { cleanupTempRuntimes, tempRuntime, writeSettings } from "./single-agent-fixture.js";

export const ABSENT = "ABSENT";

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
	const source = modified.replace(/from "(\.{1,2}\/[^\"]+)\.js"/g, (_match, name: string) => `from ${JSON.stringify(resolve(runtimeDir, `${name}.ts`))}`);
	const copyDir = tempRuntime();
	// Bare imports resolve from the copy, outside the package's dependency tree.
	fs.symlinkSync(resolve(import.meta.dir, "../node_modules"), join(copyDir, "node_modules"), "dir");
	const copy = join(copyDir, fileName);
	writeFileSync(copy, source);
	return import(copy);
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

export const theme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (_tone: string, text: string) => text,
	inverse: (text: string) => text,
};

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
