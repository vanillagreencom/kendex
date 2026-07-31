import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";

import type { AgentConfig } from "../agents.js";
import { runPersistentPaneAgent, setPaneExecCaptureForTests } from "../pane.js";
import { subagentToolRenderers } from "../subagent-render.js";
import { writePaneRegistry } from "../tasks.js";
import type { PiActivityEvent } from "../activity.js";
import { PANE_LAUNCHER_VERSION, type SingleResult, type SubagentDetails } from "../types.js";

const BROKER_SYMBOL = Symbol.for("vstack.pi.activity");

function tempDir(prefix: string): string {
	return mkdtempSync(join(tmpdir(), prefix));
}

function testAgent(): AgentConfig {
	return {
		name: "rust",
		description: "Rust engineer",
		pane: true,
		source: "project",
		systemPrompt: "",
		filePath: "rust.md",
	};
}

function spawnSleeper(cwd: string): ChildProcess {
	return spawn("node", ["-e", "setInterval(() => {}, 1000)"], { cwd, stdio: "ignore" });
}

// Tone-tagging theme so assertions can pin the status colour, not just the text.
const renderTheme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (tone: string, text: string) => (tone === "warning" || tone === "error" ? `<${tone}>${text}</${tone}>` : text),
	inverse: (text: string) => text,
};

// The pi-tui Container stub in tests/preload.ts renders to [] and only records
// its children, so expanded output has to be flattened from the child tree.
function flatten(component: any, width = 220): string {
	const children = component?.children;
	if (Array.isArray(children)) return children.map((child) => flatten(child, width)).join("\n");
	const lines = component?.render?.(width);
	return Array.isArray(lines) ? lines.join("\n") : "";
}

function renderSingle(result: SingleResult, expanded = false): string {
	const details: SubagentDetails = { mode: "single", agentScope: "project", projectAgentsDir: null, results: [result] };
	const component = subagentToolRenderers.renderResult(
		{ content: [{ type: "text", text: "done" }], details },
		{ expanded },
		renderTheme,
		{ cwd: process.cwd() },
	);
	return flatten(component);
}

// Shape of the result runPersistentPaneAgent returns when the preflight refuses:
// paneId but deliberately no taskId, because nothing was queued.
function refusedPaneResult(patch: Partial<SingleResult> = {}): SingleResult {
	const stderr = [
		"pane-cwd-stale: refusing to queue task for generalist; pane process cwd was deleted.",
		"Stop the pane with stop_subagent agent=generalist and retry with forceSpawn for a fresh process.",
	].join("\n");
	return {
		agent: "generalist",
		agentSource: "project",
		task: "do work",
		kind: "pane",
		refused: true,
		exitCode: 1,
		messages: [],
		stderr,
		stopReason: "pane-cwd-stale",
		errorMessage: stderr,
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		paneId: "%67",
		...patch,
	};
}

async function waitForProcCwd(pid: number): Promise<string> {
	const procCwd = join("/proc", String(pid), "cwd");
	let lastError: unknown;
	for (let i = 0; i < 50; i += 1) {
		try {
			return readlinkSync(procCwd);
		} catch (error) {
			lastError = error;
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
	}
	throw lastError instanceof Error ? lastError : new Error("timed out waiting for proc cwd");
}

afterEach(() => {
	setPaneExecCaptureForTests();
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL];
});

describe("persistent pane cwd preflight", () => {
	test("refuses to queue into a live pane whose process cwd was deleted", async () => {
		if (process.platform !== "linux") return;
		const runtimeRoot = tempDir("pi-agents-pane-cwd-runtime-");
		const staleCwd = tempDir("pi-agents-pane-cwd-stale-");
		const requestedCwd = tempDir("pi-agents-pane-cwd-requested-");
		const child = spawnSleeper(staleCwd);
		const events: Array<{ name: string; payload: any }> = [];
		const activity: PiActivityEvent[] = [];
		(globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL] = {
			publish(event: PiActivityEvent) { activity.push(event); },
		};
		try {
			expect(child.pid).toBeTruthy();
			await waitForProcCwd(child.pid!);
			rmSync(staleCwd, { recursive: true, force: true });
			expect((await waitForProcCwd(child.pid!)).endsWith(" (deleted)")).toBe(true);

			await writePaneRegistry(runtimeRoot, {
				rust: {
					agent: "rust",
					paneId: "%42",
					windowName: "agent:rust",
					cwd: staleCwd,
					sessionFile: join(runtimeRoot, "sessions", "rust.jsonl"),
					promptFile: join(runtimeRoot, "sessions", "rust.prompt.md"),
					launcherFile: join(runtimeRoot, "sessions", "rust.launcher.sh"),
					launcherVersion: PANE_LAUNCHER_VERSION,
					startedAt: new Date().toISOString(),
				},
			});
			setPaneExecCaptureForTests(async (command, args) => {
				if (command === "tmux" && args[0] === "display-message" && args.includes("#S")) return { code: 0, stdout: "test\n", stderr: "" };
				if (command === "tmux" && args[0] === "display-message" && args.includes("#{pane_id}")) return { code: 0, stdout: "%42\n", stderr: "" };
				if (command === "tmux" && args[0] === "display-message" && args.includes("#{pane_pid}")) return { code: 0, stdout: `${child.pid}\n`, stderr: "" };
				return { code: 1, stdout: "", stderr: `unexpected command: ${command} ${args.join(" ")}` };
			});

			const result = await runPersistentPaneAgent(
				requestedCwd,
				runtimeRoot,
				"parent-session",
				[testAgent()],
				"rust",
				"do work",
				requestedCwd,
				undefined,
				undefined,
				undefined,
				{ getActiveTools: () => [], events: { emit: (name: string, payload: unknown) => events.push({ name, payload }) } } as any,
				false,
				undefined,
				() => undefined,
			);

			expect(result.exitCode).toBe(1);
			expect(result.stopReason).toBe("pane-cwd-stale");
			expect(result.stderr).toContain("pane-cwd-stale");
			expect(result.stderr).toContain(requestedCwd);
			expect(JSON.parse(result.errorEnvelope ?? "{}").error.code).toBe("pane-cwd-stale");
			expect(existsSync(join(runtimeRoot, "inbox", "rust"))).toBe(false);

			const failed = events.find((event) => event.name === "subagents:failed");
			expect(failed?.payload.reason).toBe("pane-cwd-stale");
			expect(failed?.payload.expectedCwd).toBe(requestedCwd);
			expect(failed?.payload.actualCwdRaw).toContain("(deleted)");
			expect(failed?.payload.cwdPid).toBe(String(child.pid));

			expect(activity.some((event) => event.type === "agent.pane_cwd_stale")).toBe(true);

			// End to end: the result the guard actually returns must render in the
			// pane lane. The synthetic fixtures below cannot catch a dispatch that
			// stops stamping `kind`.
			expect(result.kind).toBe("pane");
			expect(result.refused).toBe(true);
			expect(result.taskId).toBeUndefined();
			const rendered = renderSingle(result);
			expect(rendered).toContain("· pane");
			expect(rendered).not.toContain("· bg");
			expect(rendered).toContain("refused");
		} finally {
			child.kill("SIGTERM");
			rmSync(runtimeRoot, { recursive: true, force: true });
			rmSync(requestedCwd, { recursive: true, force: true });
			rmSync(staleCwd, { recursive: true, force: true });
		}
	});

	test("refuses to queue when live pane cwd differs from requested cwd", async () => {
		if (process.platform !== "linux") return;
		const runtimeRoot = tempDir("pi-agents-pane-cwd-runtime-");
		const paneCwd = tempDir("pi-agents-pane-cwd-a-");
		const requestedCwd = tempDir("pi-agents-pane-cwd-b-");
		const child = spawnSleeper(paneCwd);
		const events: Array<{ name: string; payload: any }> = [];
		try {
			expect(child.pid).toBeTruthy();
			expect(await waitForProcCwd(child.pid!)).toBe(paneCwd);
			await writePaneRegistry(runtimeRoot, {
				rust: {
					agent: "rust",
					paneId: "%43",
					windowName: "agent:rust",
					cwd: paneCwd,
					sessionFile: join(runtimeRoot, "sessions", "rust.jsonl"),
					promptFile: join(runtimeRoot, "sessions", "rust.prompt.md"),
					launcherFile: join(runtimeRoot, "sessions", "rust.launcher.sh"),
					launcherVersion: PANE_LAUNCHER_VERSION,
					startedAt: new Date().toISOString(),
				},
			});
			setPaneExecCaptureForTests(async (command, args) => {
				if (command === "tmux" && args[0] === "display-message" && args.includes("#S")) return { code: 0, stdout: "test\n", stderr: "" };
				if (command === "tmux" && args[0] === "display-message" && args.includes("#{pane_id}")) return { code: 0, stdout: "%43\n", stderr: "" };
				if (command === "tmux" && args[0] === "display-message" && args.includes("#{pane_pid}")) return { code: 0, stdout: `${child.pid}\n`, stderr: "" };
				return { code: 1, stdout: "", stderr: `unexpected command: ${command} ${args.join(" ")}` };
			});

			const result = await runPersistentPaneAgent(
				requestedCwd,
				runtimeRoot,
				"parent-session",
				[testAgent()],
				"rust",
				"do other work",
				requestedCwd,
				undefined,
				undefined,
				undefined,
				{ getActiveTools: () => [], events: { emit: (name: string, payload: unknown) => events.push({ name, payload }) } } as any,
				false,
				undefined,
				() => undefined,
			);

			expect(result.exitCode).toBe(1);
			expect(result.stopReason).toBe("pane-cwd-stale");
			const envelope = JSON.parse(result.errorEnvelope ?? "{}");
			expect(envelope.error.code).toBe("pane-cwd-stale");
			expect(envelope.error.details.reason).toBe("mismatch");
			expect(envelope.error.details.actualCwd).toBe(paneCwd);
			expect(envelope.error.details.expectedCwd).toBe(requestedCwd);
			expect(existsSync(join(runtimeRoot, "inbox", "rust"))).toBe(false);

			const failed = events.find((event) => event.name === "subagents:failed");
			expect(failed?.payload.reason).toBe("pane-cwd-stale");
			expect(failed?.payload.cwdReason).toBe("mismatch");
			expect(failed?.payload.actualCwd).toBe(paneCwd);
			expect(failed?.payload.expectedCwd).toBe(requestedCwd);
		} finally {
			child.kill("SIGTERM");
			rmSync(runtimeRoot, { recursive: true, force: true });
			rmSync(requestedCwd, { recursive: true, force: true });
			rmSync(paneCwd, { recursive: true, force: true });
		}
	});
});

describe("refused pane dispatch rendering", () => {
	// The refusal carries paneId but no taskId, so any lane derivation keyed on
	// taskId reports the bg lane for an agent that only ever runs in a pane.
	test("collapsed row reports the pane lane, not bg", () => {
		const text = renderSingle(refusedPaneResult());
		expect(text).toContain("· pane");
		expect(text).not.toContain("· bg");
	});

	test("expanded header reports the pane lane, not bg", () => {
		const text = renderSingle(refusedPaneResult(), true);
		expect(text).toContain("· pane");
		expect(text).not.toContain("· bg");
	});

	test("lane badge survives a missing taskId on every terminal pane result", () => {
		// Not stale-specific: any pane result that ends before queueing must still
		// report its lane.
		const text = renderSingle(refusedPaneResult({ stopReason: "error", refused: false, errorMessage: "boom", stderr: "boom" }));
		expect(text).toContain("· pane");
		expect(text).not.toContain("· bg");
	});

	test("a bg one-shot result still reports the bg lane", () => {
		const text = renderSingle(refusedPaneResult({ kind: "oneshot", paneId: undefined }));
		expect(text).toContain("· bg");
		expect(text).not.toContain("· pane");
	});

	test("a refusal is reported as refused, not failed", () => {
		const collapsed = renderSingle(refusedPaneResult());
		expect(collapsed).toContain("refused");
		expect(collapsed).not.toContain("failed");
		// Warning, not error: the guard declined a dispatch, nothing crashed.
		expect(collapsed).toContain("<warning>refused</warning>");
		expect(collapsed).toContain("<warning>[pane-cwd-stale]</warning>");
	});

	test("the refusal message and its recovery hint are preserved verbatim", () => {
		for (const text of [renderSingle(refusedPaneResult()), renderSingle(refusedPaneResult(), true)]) {
			expect(text).toContain("pane-cwd-stale: refusing to queue task for generalist");
			expect(text).toContain("retry with forceSpawn for a fresh process");
		}
	});

	test("expanded refusal omits the ran-a-task sections", () => {
		const text = renderSingle(refusedPaneResult(), true);
		// Nothing ran, so no tool list, no final response, and no usage line.
		expect(text).not.toContain("Tools used");
		expect(text).not.toContain("(none)");
		expect(text).not.toContain("Final response");
		expect(text).toContain("Task");
	});

	test("a real failed bg run still renders as failed", () => {
		const text = renderSingle(refusedPaneResult({
			kind: "oneshot",
			paneId: undefined,
			refused: false,
			stopReason: "error",
			errorMessage: "boom",
			stderr: "boom",
		}));
		expect(text).toContain("<error>failed</error>");
		expect(text).not.toContain("refused");
	});
});
