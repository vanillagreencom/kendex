import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test, { after } from "node:test";
import { registerPaneSupportTools } from "../extensions/subagent/pane-support-tools.js";
import { execCapture } from "../extensions/subagent/pane.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const INDEX_SRC = resolve(HERE, "../extensions/subagent/index.ts");

interface CapturedTool {
	name: string;
	execute: (toolCallId: string, params: any, signal: AbortSignal | undefined, onUpdate: any, ctx: any) => Promise<any>;
}

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});
after(cleanupTempRuntimes);

function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-steer-status-"));
	tempDirs.push(dir);
	return dir;
}

function buildDeps(opts: {
	runtimeRoot: string;
	dashboardStatusForFn: ((status: any, kind: any) => any) | undefined;
	dashboardStatusForCallCount: { count: number };
	updateDashboardSpy: { calls: any[] };
}): { deps: Record<string, any>; capturedTools: CapturedTool[] } {
	const capturedTools: CapturedTool[] = [];
	const record: PaneTaskRecord = {
		taskId: "task-steer-1",
		agent: "planner",
		task: "Plan.",
		status: "running",
		paneId: "%42",
		createdAt: "2026-05-15T00:00:00.000Z",
	};
	const paneEntry = {
		paneId: "%42",
		sessionFile: join(opts.runtimeRoot, "sessions", "planner.jsonl"),
		cwd: opts.runtimeRoot,
	};
	const deps: Record<string, any> = {
		pi: {
			registerTool(tool: any) {
				capturedTools.push({ name: tool.name, execute: tool.execute });
			},
		},
		bridgeTargetArgs: () => [],
		backfillTaskSummaryFromTranscript: async (_r: string, rec: PaneTaskRecord) => ({ record: rec }),
		createFollowUpTask: async () => ({ taskId: "follow-up", outboxFile: "" }),
		dashboardStatusFor: opts.dashboardStatusForFn
			? (status: any, kind: any) => {
					opts.dashboardStatusForCallCount.count += 1;
					return opts.dashboardStatusForFn!(status, kind);
				}
			: undefined,
		emitSubagentEvent: () => {},
		ensurePaneBridgeMetadata: async () => undefined,
		execCapture: async () => ({ code: 0, stdout: "", stderr: "" }),
		formatSteeringForChild: (_agent: string, message: string) => `STEER:${message}`,
		formatTaskRecordResult: () => "",
		inferTaskRecordKind: () => "pane",
		isFollowUpDelivery: (mode: string) => mode === "follow-up",
		latestTaskRecord: () => record,
		paneExists: async () => true,
		paneSessionBelongsToRuntime: () => true,
		patchDashboard: () => {},
		pollPaneCompletions: async () => 0,
		queueSteeringFallback: async (runtimeRoot: string, agentName: string, message: string) => {
			const inbox = join(runtimeRoot, "inbox", agentName);
			mkdirSync(inbox, { recursive: true });
			const filePath = join(inbox, `steer-${Date.now()}.md`);
			writeFileSync(filePath, `STEER:${agentName}:${message}`, "utf-8");
			return filePath;
		},
		readPaneRegistry: async () => ({ planner: paneEntry }),
		readTaskRegistry: async () => ({ [record.taskId]: record }),
		refreshTaskDiagnostics: async (_r: string, rec: PaneTaskRecord) => ({ record: rec, diagnostics: [] }),
		taskNeedsSummaryBackfill: () => false,
		removeDashboardAgent: () => {},
		resolvePiBridgeBin: async () => undefined,
		retireSubagent: async () => ({ kind: "pane", entry: { agent: "planner", ...paneEntry } }),
		runtimeSessionId: () => "session-test",
		sessionRuntimeDir: () => opts.runtimeRoot,
		steerDiagnostics: () => [],
		updateDashboard: (item: any) => {
			opts.updateDashboardSpy.calls.push(item);
		},
		updateDashboardFromTaskRecord: () => {},
		persistRuntimeSnapshot: async () => {},
		waitForPaneIdle: async () => ({ text: "", details: {}, isError: false }),
	};
	return { deps, capturedTools };
}

function getSteerHandler(tools: CapturedTool[]): CapturedTool {
	const handler = tools.find((tool) => tool.name === "steer_subagent");
	assert.ok(handler, "steer_subagent must be registered");
	return handler;
}

function paneSupportRegistrationSource(): string {
	const src = readFileSync(INDEX_SRC, "utf8");
	const callStart = src.indexOf("registerPaneSupportTools({");
	assert.notEqual(callStart, -1, "index.ts must register pane support tools");
	const callEnd = src.indexOf("\n\t});", callStart);
	assert.notEqual(callEnd, -1, "index.ts pane support registration must have a closing call");
	return src.slice(callStart, callEnd);
}

test("index wires ensurePaneBridgeMetadata into pane support tools (regression kendex#314)", () => {
	assert.match(
		paneSupportRegistrationSource(),
		/\bensurePaneBridgeMetadata,\n/,
		"steer_subagent must receive ensurePaneBridgeMetadata from index.ts; missing wiring reproduces 'ensurePaneBridgeMetadata is not a function'",
	);
});

test("steer_subagent delivers message when dashboardStatusFor is provided (regression kendex#62)", async () => {
	const runtimeRoot = tempRuntime();
	const callCounter = { count: 0 };
	const updateDashboardSpy = { calls: [] as any[] };
	const { deps, capturedTools } = buildDeps({
		runtimeRoot,
		dashboardStatusForFn: (status, _kind) => status,
		dashboardStatusForCallCount: callCounter,
		updateDashboardSpy,
	});
	registerPaneSupportTools(deps as any);
	const steer = getSteerHandler(capturedTools);

	const result = await steer.execute(
		"call-1",
		{ taskId: "task-steer-1", message: "please pivot" },
		undefined,
		undefined,
		{},
	);

	assert.equal(result.isError, undefined, "no error");
	assert.equal(callCounter.count, 1, "dashboardStatusFor invoked exactly once");
	assert.equal(updateDashboardSpy.calls.length, 1, "updateDashboard invoked exactly once");
	assert.equal(updateDashboardSpy.calls[0]?.status, "running");
	const fallbackFile = result.details?.fallbackFile;
	assert.ok(fallbackFile && existsSync(fallbackFile), "fallback inbox file written");
	const contents = readFileSync(fallbackFile, "utf-8");
	assert.ok(contents.includes("please pivot"), "steering message reaches inbox file");
});

test("steer_subagent still delivers message when dashboardStatusFor is missing (defensive guard)", async () => {
	const runtimeRoot = tempRuntime();
	const callCounter = { count: 0 };
	const updateDashboardSpy = { calls: [] as any[] };
	const { deps, capturedTools } = buildDeps({
		runtimeRoot,
		dashboardStatusForFn: undefined,
		dashboardStatusForCallCount: callCounter,
		updateDashboardSpy,
	});
	registerPaneSupportTools(deps as any);
	const steer = getSteerHandler(capturedTools);

	let threw = false;
	let result: any;
	try {
		result = await steer.execute(
			"call-2",
			{ taskId: "task-steer-1", message: "missing helper" },
			undefined,
			undefined,
			{},
		);
	} catch {
		threw = true;
	}
	assert.equal(threw, false, "steer must not throw when dashboardStatusFor is undefined");
	assert.equal(callCounter.count, 0, "dashboardStatusFor never invoked when missing");
	assert.equal(updateDashboardSpy.calls.length, 1, "updateDashboard still invoked with fallback status");
	assert.equal(updateDashboardSpy.calls[0]?.status, "running", "fallback uses raw record.status");
	const fallbackFile = result?.details?.fallbackFile;
	assert.ok(fallbackFile && existsSync(fallbackFile), "fallback inbox file still written");
	const contents = readFileSync(fallbackFile, "utf-8");
	assert.ok(contents.includes("missing helper"), "steering message still reaches inbox");
});

const deliveryRows = [
	{ name: "success", exitCode: 0, fallback: false, unknown: false },
	{ name: "nonzero exit", exitCode: 2, fallback: true, unknown: false },
	{ name: "deadline after delivery", exitCode: undefined, fallback: false, unknown: true },
] as const;

async function assertBridgeDelivery(row: typeof deliveryRows[number], register = registerPaneSupportTools): Promise<void> {
	for (const command of ["steer", "send", "follow-up"] as const) {
		const runtimeRoot = tempRuntime();
		const delivered = join(runtimeRoot, "delivered");
		const { deps, capturedTools } = buildDeps({ runtimeRoot, dashboardStatusForFn: (status) => status,
			dashboardStatusForCallCount: { count: 0 }, updateDashboardSpy: { calls: [] } });
		deps.ensurePaneBridgeMetadata = async () => ({ pid: "42", socket: "test.sock" });
		deps.bridgeTargetArgs = () => ["--pid", "42"];
		deps.resolvePiBridgeBin = async () => "faux-pi-bridge";
		deps.execCapture = async (bin: string, args: string[]) => {
			assert.equal(bin, "faux-pi-bridge");
			assert.equal(args[0], command);
			assert.equal(args.includes("--auto"), command === "send");
			// A real child records delivery before it exits or stalls. The real wait
			// lets the OS start that child and the command owner enforce its deadline.
			return execCapture(process.execPath, ["-e", `require("node:fs").writeFileSync(${JSON.stringify(delivered)}, "delivered"); ${row.exitCode === undefined ? "setInterval(() => {}, 1000)" : `process.exit(${row.exitCode})`}`], {
				cwd: runtimeRoot, timeoutMs: 500, env: { PATH: "/usr/bin:/bin", HOME: runtimeRoot, TMPDIR: runtimeRoot },
			});
		};
		const events: string[] = [];
		deps.emitSubagentEvent = (_pi: unknown, event: string) => { events.push(event); };
		register(deps as any);
		const warnings: string[] = [];
		const warn = console.warn;
		console.warn = (message: string) => { warnings.push(message); };
		let result: any;
		try {
			result = await getSteerHandler(capturedTools).execute("delivery", { taskId: "task-steer-1", message: "pivot", deliverAs: command }, undefined, undefined, {});
		} finally { console.warn = warn; }
		assert.equal(readFileSync(delivered, "utf8"), "delivered", "faux bridge must deliver before capture settles");
		assert.equal(existsSync(join(runtimeRoot, "inbox", "planner")), row.fallback, "deadline delivery must not queue a duplicate inbox fallback");
		assert.equal(result.details.fallbackFile !== undefined, row.fallback);
		if (row.fallback) assert.equal(readFileSync(result.details.fallbackFile, "utf8"), "STEER:planner:pivot");
		assert.equal(result.isError === true, row.unknown);
		assert.equal(result.content[0].text.startsWith(`bridge_delivery=unknown command=${command}\n`), row.unknown);
		assert.equal(warnings.length, row.unknown ? 1 : 0);
		assert.deepEqual(events, row.unknown ? [] : ["subagents:steered"]);
	}
}

for (const row of deliveryRows) test(`bridge delivery: ${row.name}`, () => assertBridgeDelivery(row));

test("must-fail control: inbox fallback after unknown delivery duplicates the message", async () => {
	const mutant = await importRuntimeCopy("pane-support-tools.ts", 'if (result.interruption === "timeout") {', 'if (false && result.interruption === "timeout") {') as typeof import("../extensions/subagent/pane-support-tools.js");
	await assert.rejects(() => assertBridgeDelivery(deliveryRows[2], mutant.registerPaneSupportTools), {
		name: "AssertionError", actual: true, expected: false, operator: "strictEqual",
	});
});
