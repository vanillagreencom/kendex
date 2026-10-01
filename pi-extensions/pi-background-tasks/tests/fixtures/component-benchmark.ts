import { mock } from "bun:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import asyncFs from "node:fs/promises";
import { performance } from "node:perf_hooks";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { DashboardDeps } from "../../extensions/dashboard.js";
import { dashboardHost } from "./dashboard-host.js";
import { fakeSnapshot } from "./lifecycle.js";

const logFile = `${process.cwd()}/restored.log`;
const secondLog = `${process.cwd()}/second.log`;
const logs = new Set([logFile, secondLog]);
const logBytes = 50_000_000;
const tailChars = 12_000;
fs.writeFileSync(logFile, Buffer.alloc(logBytes, "a"));
fs.writeFileSync(secondLog, "second tail");
const settingsPath = `${process.env.PI_CODING_AGENT_DIR}/settings.json`;
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
settings.kendex.extensionManager.config["@vanillagreen/pi-background-tasks"].logTailMaxChars = tailChars;
fs.writeFileSync(settingsPath, JSON.stringify(settings));

const counts = { wholeLogReads: 0, syncReads: 0, asyncReads: 0, bytes: 0, syncOpens: 0, asyncOpens: 0 };
const native = { ...fs };
const descriptors = new Set<number>();
mock.module("node:fs", () => ({ ...native,
	readFileSync: (...args: Parameters<typeof fs.readFileSync>) => {
		const result = native.readFileSync(...args);
		if (logs.has(String(args[0]))) { counts.wholeLogReads += 1; counts.bytes += Buffer.byteLength(result); }
		return result;
	},
	openSync: (...args: Parameters<typeof fs.openSync>) => {
		const fd = native.openSync(...args);
		if (logs.has(String(args[0]))) { descriptors.add(fd); counts.syncOpens += 1; }
		return fd;
	},
	readSync: (...args: Parameters<typeof fs.readSync>) => {
		const bytes = native.readSync(...args);
		if (descriptors.has(args[0])) { counts.syncReads += 1; counts.bytes += bytes; }
		return bytes;
	},
	closeSync: (fd: number) => { descriptors.delete(fd); native.closeSync(fd); },
}));
const nativeOpen = asyncFs.open;
const pendingReads = new Set<Promise<void>>();
mock.module("node:fs/promises", () => ({ ...asyncFs,
	open: async (...args: Parameters<typeof nativeOpen>) => {
		if (!logs.has(String(args[0]))) return nativeOpen(...args);
		counts.asyncOpens += 1;
		let finished!: () => void;
		const completion = new Promise<void>((resolve) => { finished = resolve; });
		pendingReads.add(completion);
		const handle = await nativeOpen(...args);
		return new Proxy(handle, { get(target, key) {
			if (key === "read") return async (buffer: Buffer, offset: number, length: number, position: number) => {
				const result = await target.read(buffer, offset, length, position);
				counts.asyncReads += 1;
				counts.bytes += result.bytesRead;
				return result;
			};
			if (key === "close") return async () => {
				try { await target.close(); } finally { pendingReads.delete(completion); finished(); }
			};
			const value: unknown = Reflect.get(target, key);
			return typeof value === "function" ? value.bind(target) : value;
		} });
	},
}));
const unused = () => { throw new Error("component benchmark reached an unrelated host operation"); };
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: unused }));
let deps: DashboardDeps | undefined;
// Capture the factory's production closures at the registration boundary, not a test export.
mock.module("../../extensions/registrations.js", () => ({ registerAll: (_pi: unknown, registered: { dashboardDeps: DashboardDeps }) => { deps = registered.dashboardDeps; } }));
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
const pi = {
	on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => events.set(name, handler),
	registerMessageRenderer() {}, appendEntry() {}, sendMessage: unused,
} as unknown as ExtensionAPI;
const snapshots = [
	fakeSnapshot({ id: "bg-1", status: "completed", startedAt: 2, command: "cache-me " + "c".repeat(8_000), logFile, notifyOnExit: false, exitNotified: true, cwd: process.cwd() }),
	fakeSnapshot({ id: "bg-2", status: "completed", startedAt: 1, command: "cache-me second", logFile: secondLog, notifyOnExit: false, exitNotified: true, cwd: process.cwd() }),
];
const phases: unknown[] = [];
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => "benchmark", getSessionFile: () => null, getBranch: () => [{ type: "custom", customType: "kendex-background-tasks:state", data: { tasks: snapshots } }] },
	ui: { notify: unused, setWidget() {}, custom: async (factory: (tui: unknown, theme: unknown, keys: unknown, done: () => void) => { render(width: number): string[]; handleInput(data: string): void; invalidate(): void; dispose(): void }) => {
		const component = factory({ terminal: { rows: 40 }, requestRender() {} }, {
			fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text,
			inverse: (text: string) => text,
		} satisfies Pick<Theme, "fg" | "bg" | "bold" | "inverse">, {}, () => {});
		const task = deps!.sortedTasks()[0];
		assert.equal(task.output, "", "the input must be a restored disk-backed task");
		const rows = [
			{ name: "steady", frames: 30, width: 120, change() {} },
			{ name: "expanded", frames: 10, width: 120, change: () => component.handleInput("x") },
			{ name: "width", frames: 10, width: 80, change() {} },
			{ name: "content", frames: 10, width: 80, change: () => { task.command += " changed"; } },
			{ name: "theme", frames: 10, width: 80, change: () => component.invalidate() },
			{ name: "second", frames: 1, width: 80, change: () => component.handleInput("down") },
			{ name: "return", frames: 1, width: 80, change: () => component.handleInput("up") },
		];
		try {
			for (const row of rows) {
				row.change();
				const before = { ...counts, commandWraps: dashboardHost.commandWraps };
				let maxFrameMs = 0;
				let maxStepMs = 0;
				for (let index = 0; index < row.frames; index += 1) {
					const started = performance.now();
					assert.ok(component.render(row.width).length > 0);
					maxFrameMs = Math.max(maxFrameMs, performance.now() - started);
					// Real I/O must close before measuring the next frame's cache hit.
					await Promise.all([...pendingReads]);
					await new Promise<void>((resolve) => setImmediate(resolve));
					maxStepMs = Math.max(maxStepMs, performance.now() - started);
				}
				const after = { ...counts, commandWraps: dashboardHost.commandWraps };
				const operations = Object.fromEntries(Object.entries(after).map(([key, value]) => [key, value - before[key as keyof typeof before]]));
				phases.push({ name: row.name, frames: row.frames, ...operations, maxFrameMs, maxStepMs });
			}
		} finally { component.dispose(); }
	} },
} as unknown as ExtensionContext;
const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
const { openDashboard } = await import("../../extensions/dashboard.js");
backgroundTasks(pi);
await events.get("session_start")!({}, ctx);
assert.ok(deps, "the extension must supply its dashboard dependencies");
ctx.hasUI = true;
try { await openDashboard(ctx, deps); } finally { await events.get("session_shutdown")!({}, ctx); }
process.stdout.write(JSON.stringify({ logBytes, tailChars, commandChars: snapshots[0].command.length, phases }));
