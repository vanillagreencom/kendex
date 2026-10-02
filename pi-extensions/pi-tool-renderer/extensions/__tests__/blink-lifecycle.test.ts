import { afterEach, expect, jest, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import * as agent from "@earendil-works/pi-coding-agent";

import { clearPackageConfigCache } from "../tool-renderer/package-config.js";
import { CONFIG_ID } from "../tool-renderer/settings.js";
import { clearBlink, registerBlinkEvents, renderPendingCall } from "../tool-renderer/text.js";
import { registerWrite } from "../tool-renderer/tools.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { fg: (_tone: string, text: string) => text, bg: (_tone: string, text: string) => text, bold: (text: string) => text };
const animated = JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { pendingStatusAnimation: true } } } } });

type Handler = (event: unknown, ctx: unknown) => void;

/** The subset of Pi's extension API the blink events register on. */
function fakePi() {
	const handlers = new Map<string, Handler[]>();
	return {
		on(name: string, handler: Handler) {
			handlers.set(name, [...(handlers.get(name) ?? []), handler]);
		},
		emit(name: string) {
			for (const handler of handlers.get(name) ?? []) handler({}, {});
		},
	};
}

const pi = fakePi();
registerBlinkEvents(pi as any);

// Settled rows outlive a case until session_shutdown, so each case ends one.
afterEach(() => {
	pi.emit("session_shutdown");
	jest.useRealTimers();
});

function animatedWorld(): string {
	const { cwd } = world();
	writeFileSync(join(cwd, ".pi", "settings.json"), animated);
	clearPackageConfigCache();
	jest.useFakeTimers();
	return cwd;
}

function pendingRow(cwd: string, toolCallId: string) {
	const row = { invalidations: 0, context: { cwd, executionStarted: true, isPartial: true, toolCallId, invalidate: () => row.invalidations++ } };
	return row;
}

// Pi drops a pending row with no final render at each of these events, so a
// row that never reached renderResult must stop blinking there, and must not
// keep the next row's interval alive.
for (const event of ["agent_end", "session_shutdown"]) {
	test(`${event} clears an animated pending row that got no final render`, () => {
		const cwd = animatedWorld();
		const dropped = pendingRow(cwd, `${event}-dropped`);

		renderPendingCall("Read file", theme, dropped.context, cwd);
		jest.advanceTimersByTime(450);
		expect([jest.getTimerCount(), dropped.invalidations]).toEqual([1, 1]);

		pi.emit(event);
		expect(jest.getTimerCount()).toBe(0);

		const next = pendingRow(cwd, `${event}-next`);
		renderPendingCall("Read file", theme, next.context, cwd);
		jest.advanceTimersByTime(450);
		expect([jest.getTimerCount(), next.invalidations]).toEqual([1, 1]);
		clearBlink(next.context);
		expect(jest.getTimerCount()).toBe(0);
		jest.advanceTimersByTime(4500);
		expect([dropped.invalidations, next.invalidations]).toEqual([1, 1]);
	});
}

// Pi leaves a row the run dropped on screen and redraws it as pending on
// ctrl+o, a theme change or a settings refresh.
test("a row agent_end dropped stays still when Pi draws it again", () => {
	const cwd = animatedWorld();
	const dropped = pendingRow(cwd, "redrawn");
	renderPendingCall("Read file", theme, dropped.context, cwd);
	pi.emit("agent_end");

	renderPendingCall("Read file", theme, dropped.context, cwd);
	expect(jest.getTimerCount()).toBe(0);
	jest.advanceTimersByTime(4500);
	expect(dropped.invalidations).toBe(0);
});

test("agent_end releases a dropped write row's snapshot, and a later read stores none", async () => {
	const { cwd } = world();
	writeFileSync(join(cwd, "a.txt"), "old\n");
	const tools: any[] = [];
	registerWrite({ registerTool: (tool: any) => tools.push(tool) } as any, agent, cwd);
	expect(tools.length).toBe(1);
	const args = { path: "a.txt", content: "new\n" };
	const writeRow = (toolCallId: string) => {
		let redrawn!: () => void;
		const redraw = new Promise<void>((resolve) => { redrawn = resolve; });
		const row = { redraws: 0, redraw, context: { args, argsComplete: true, cwd, executionStarted: true, isPartial: true, state: {} as Record<string, unknown>, toolCallId, invalidate: () => { row.redraws++; redrawn(); } } };
		return row;
	};

	const read = writeRow("read");
	tools[0].renderCall(args, theme, read.context);
	await read.redraw;
	expect(read.context.state.kendexWriteSnapshot).toMatchObject({ snapshot: { kind: "text", text: "old\n" } });
	const inFlight = writeRow("in-flight");
	tools[0].renderCall(args, theme, inFlight.context);
	pi.emit("agent_end");
	expect([read.context.state.kendexWriteSnapshot, inFlight.context.state.kendexWriteSnapshot]).toEqual([undefined, undefined]);

	// A row the next run draws still reads its snapshot.
	const control = writeRow("control");
	tools[0].renderCall(args, theme, control.context);
	await control.redraw;
	// A settled row's read has no observable end; 200 ms covers a stat and a
	// read of a 4-byte file, and a read that stored or redrew would show here.
	await new Promise((resolve) => setTimeout(resolve, 200));
	expect([inFlight.context.state.kendexWriteSnapshot, inFlight.redraws]).toEqual([undefined, 0]);

	for (const row of [read, inFlight]) tools[0].renderCall(args, theme, row.context);
	expect([read.context.state.kendexWriteSnapshot, inFlight.context.state.kendexWriteSnapshot]).toEqual([undefined, undefined]);
});

// The extension entry point patches Pi's component prototypes for the whole
// process, so it loads in a child, never in this shared test process.
test("the extension entry point stops a dropped row's blink at agent_end", () => {
	const { cwd, agent: agentDir } = world();
	writeFileSync(join(agentDir, "settings.json"), animated);
	const extensions = fileURLToPath(new URL("../", import.meta.url));
	const script = `
		const { default: toolRenderer } = await import(${JSON.stringify(join(extensions, "tool-renderer.ts"))});
		const { renderPendingCall } = await import(${JSON.stringify(join(extensions, "tool-renderer/text.ts"))});
		const handlers = new Map();
		const pi = {
			on: (name, handler) => handlers.set(name, [...(handlers.get(name) ?? []), handler]),
			events: { on: () => () => {}, emit: () => {} },
			registerTool: () => {},
		};
		await toolRenderer(pi);
		let invalidations = 0;
		const cwd = ${JSON.stringify(cwd)};
		const context = { cwd, executionStarted: true, isPartial: true, toolCallId: "call", invalidate: () => invalidations++ };
		renderPendingCall("Read file", { fg: (_tone, text) => text, bold: (text) => text }, context, cwd);
		for (const handler of handlers.get("agent_end") ?? []) await handler({}, { cwd });
		// Two blink periods of 450 ms: an interval agent_end missed redraws the row.
		await new Promise((resolve) => setTimeout(resolve, 1000));
		console.log(\`invalidations=\${invalidations}\`);
	`;
	const run = spawnSync(process.execPath, ["-e", script], {
		cwd,
		env: { HOME: cwd, PI_CODING_AGENT_DIR: agentDir },
		encoding: "utf8",
		timeout: 20_000,
	});
	expect(run.error).toBeUndefined();
	expect(run.stderr).toBe("");
	expect([run.status, run.stdout]).toEqual([0, "invalidations=0\n"]);
});
