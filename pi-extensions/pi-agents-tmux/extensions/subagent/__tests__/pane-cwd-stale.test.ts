import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";

import type { AgentConfig } from "../agents.js";
import { runPersistentPaneAgent, setPaneExecCaptureForTests } from "../pane.js";
import { writePaneRegistry } from "../tasks.js";
import type { PiActivityEvent } from "../activity.js";
import { PANE_LAUNCHER_VERSION } from "../types.js";

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
