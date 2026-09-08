// diagnostics discipline.
//
// 1. diagDump is gated on CLAUDE_BRIDGE_DEBUG exactly like debug(): a host
//    that has not opted into debugging gets NO diag file. This includes
//    every "should never happen" path.
//    60-char previews of user-authored prompt text, outside any host app's
//    retention boundary.
// 2. The deferred_user_messages_dropped entry carries counts/sites/lengths
//    only — never message content.
// 3. debug() evaluates function args lazily (after the DEBUG early return),
//    and the per-SDK-message call site in consumeQuery uses that: the payload
//    must not be built when DEBUG is off, because stream_event arrives once
//    per streamed token.
//
// The DEBUG flag is read once at module load, so the two gating states are
// exercised in child processes with a controlled environment; the in-process
// tests below scrub CLAUDE_BRIDGE_DEBUG before importing any bridge module.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";

// In-process modules must load with DEBUG off regardless of the runner's env.
delete process.env.CLAUDE_BRIDGE_DEBUG;
const { DEBUG, diagGuidance, diagLogPath } = await import("../src/debug.ts");
const { summarizeDroppedUserMessages } = await import("../src/query-state.ts");
const { consumeQuery } = await import("../src/consume-query.ts");

const pkgRoot = fileURLToPath(new URL("..", import.meta.url));
let dir;

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "bridge-diag-"));
});

afterEach(() => {
	rmSync(dir, { recursive: true, force: true });
});

// Run a child that imports src/debug.ts and exercises diagDump + a debug
// thunk, with CLAUDE_BRIDGE_DEBUG controlled and both logs routed into `dir`.
function runProbeChild({ debugOn }) {
	const scriptPath = join(dir, "probe.mjs");
	writeFileSync(scriptPath, [
		`import { debug, diagDump } from ${JSON.stringify(pathToFileURL(join(pkgRoot, "src/debug.ts")).href)};`,
		`diagDump("test_entry", { probe: 42 });`,
		`debug("thunk check", () => "thunk-payload-123");`,
	].join("\n"));
	const env = { ...process.env, PI_CODING_AGENT_DIR: join(dir, "agent") };
	env.CLAUDE_BRIDGE_DIAG_PATH = join(dir, "diag.log");
	env.CLAUDE_BRIDGE_DEBUG_PATH = join(dir, "debug.log");
	if (debugOn) env.CLAUDE_BRIDGE_DEBUG = "1";
	else delete env.CLAUDE_BRIDGE_DEBUG;
	execFileSync(process.execPath, ["--import", "tsx", scriptPath], { cwd: pkgRoot, env });
}

describe("debug() formatting failures are non-fatal", () => {
	it("renders each failing argument without losing adjacent arguments", () => {
		for (const { name, setup = "", arg, expected } of [
			{ name: "throwing thunk", arg: '() => { throw new Error("thunk boom"); }', expected: /\[unprintable: thunk boom\]/ },
			{ name: "circular object", setup: "const circular = {}; circular.self = circular;", arg: "circular", expected: /\[unprintable: [\s\S]+\]/ },
			{ name: "BigInt", arg: "10n", expected: /\[unprintable: [\s\S]+\]/ },
			{ name: "unprintable thrown value", arg: "() => { throw Object.create(null); }", expected: /\[unprintable: [^\]]+\]/ },
			{ name: "undefined", arg: "undefined", expected: /^undefined$/ },
			{ name: "symbol", arg: 'Symbol("naked-symbol")', expected: /^Symbol\(naked-symbol\)$/ },
			{ name: "symbol error message", setup: 'const symErr = new Error(); symErr.message = Symbol("sym-reason");', arg: "() => { throw symErr; }", expected: /\[unprintable: Symbol\(sym-reason\)\]/ },
			{ name: "throwing fallback conversion", arg: '{ toJSON: () => undefined, toString: () => { throw new Error("hostile toString"); } }', expected: /\[unprintable: [^\]]+\]/ },
		]) {
			const scriptPath = join(dir, "format.mjs");
			const logPath = join(dir, "debug.log");
			writeFileSync(scriptPath, [
				`import { debug } from ${JSON.stringify(pathToFileURL(join(pkgRoot, "src/debug.ts")).href)};`,
				setup,
				`debug("before-args", ${arg}, "after-args");`,
			].join("\n"));
			rmSync(logPath, { force: true });
			// A nonzero child status fails before the log assertion.
			execFileSync(process.execPath, ["--import", "tsx", scriptPath], {
				cwd: pkgRoot,
				env: { ...process.env, PI_CODING_AGENT_DIR: join(dir, "agent"), CLAUDE_BRIDGE_DEBUG: "1", CLAUDE_BRIDGE_DEBUG_PATH: logPath, CLAUDE_BRIDGE_DIAG_PATH: join(dir, "diag.log") },
			});
			const rendered = readFileSync(logPath, "utf8").match(/before-args ([\s\S]+) after-args\n$/)?.[1];
			assert.match(rendered ?? "", expected, name);
		}
	});
});

describe("diagGuidance (kendex#1041)", () => {
	it("with DEBUG off points at the debug env var, never at the unwritten diag log", () => {
		assert.equal(DEBUG, false, "precondition: this test process must run with DEBUG off");
		const guidance = diagGuidance();
		assert.match(guidance, /CLAUDE_BRIDGE_DEBUG=1/);
		assert.ok(!guidance.includes(diagLogPath()), "no pointer to a diag file that was never written");
	});
});

describe("diagDump gating (VST-15)", () => {
	it("writes nothing to disk when CLAUDE_BRIDGE_DEBUG is off", () => {
		runProbeChild({ debugOn: false });
		assert.equal(existsSync(join(dir, "diag.log")), false, "no diag file without the debug flag");
		assert.equal(existsSync(join(dir, "debug.log")), false, "no debug log without the debug flag");
	});

	it("still dumps — and evaluates debug thunks — when the flag is on", () => {
		runProbeChild({ debugOn: true });
		const entry = JSON.parse(readFileSync(join(dir, "diag.log"), "utf8").trim().split("\n")[0]);
		assert.equal(entry.label, "test_entry");
		assert.equal(entry.probe, 42);
		// The lazy-arg mechanism must not LOSE payloads when debugging is on.
		assert.match(readFileSync(join(dir, "debug.log"), "utf8"), /thunk-payload-123/);
	});
});

describe("deferred_user_messages_dropped entry (VST-15)", () => {
	it("carries site, count, and lengths — never message content", () => {
		const dropped = [
			{ text: "the user's private prompt text" },
			{ text: "", blocks: [{ type: "image", source: {} }] },
		];
		const entry = summarizeDroppedUserMessages("terminal-failure", dropped);
		assert.deepEqual(entry, {
			site: "terminal-failure",
			count: 2,
			textLengths: [dropped[0].text.length, 0],
			imageOnlyCount: 1,
		});
		assert.ok(!JSON.stringify(entry).includes("private"), "no user-authored text in the diag entry");
	});
});

describe("consumeQuery managed-message debug is lazy (VST-15)", () => {
	it("does not build the payload when DEBUG is off", async () => {
		assert.equal(DEBUG, false, "precondition: this test process must run with DEBUG off");

		let payloadTouched = false;
		const message = {
			type: "stream_event",
			subtype: undefined,
			error: undefined,
			get event() {
				payloadTouched = true;
				return undefined;
			},
		};
		async function* fakeSdkQuery() {
			yield message;
		}
		// Minimal captured context: no turn output, so the loop falls through
		// right after the managed-message debug call under test.
		const queryCtx = { turnOutput: null, currentPiStream: null };
		const result = await consumeQuery(
			fakeSdkQuery(),
			queryCtx,
			new Map(),
			{ id: "test-model", provider: "test" },
			{},
			() => false,
			{ profileId: "profile-1", label: "Test account" },
		);

		assert.equal(payloadTouched, false, "the debug payload must not be evaluated when DEBUG is off");
		assert.equal(result.failure, undefined);
	});
});
