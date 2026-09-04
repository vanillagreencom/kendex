// tool_batch must not hang indefinitely when an
// inner tool never resolves. The fix wraps each inner call in a
// Promise.race against a per-call timeout and aborts the child signal so
// cooperative tools can clean up subprocess handles.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { registerToolBatch } from "../tool-renderer/batch.js";
import { recordProjectTrust } from "../tool-renderer/settings.js";

const RENDERER_CONFIG_ID = "@vanillagreen/pi-tool-renderer";

function writeBatchSettings(cwd: string, overrides: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(
		join(cwd, ".pi", "settings.json"),
		JSON.stringify({
			kendex: {
				extensionManager: {
					config: { [RENDERER_CONFIG_ID]: overrides },
				},
			},
		}),
		"utf8",
	);
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
}

interface CapturedDef {
	execute: (
		toolCallId: string,
		params: unknown,
		signal: AbortSignal | undefined,
		onUpdate: unknown,
		context: unknown,
	) => Promise<{ details?: unknown; isError?: boolean; content?: Array<{ text: string; type: string }> }>;
	[key: string]: unknown;
}

function makeFakePi(): { tools: CapturedDef[]; registerTool: (def: CapturedDef) => void } {
	const tools: CapturedDef[] = [];
	return {
		registerTool(def: CapturedDef): void {
			tools.push(def);
		},
		tools,
	};
}

function fakeSuccessTool(text: string): { execute: (id: string, args: unknown) => Promise<unknown> } {
	return {
		execute: async () => ({
			content: [{ text, type: "text" }],
			details: { ok: true },
			isError: false,
		}),
	};
}

function fakeHangingTool(onAbort: () => void): { execute: (id: string, args: unknown, signal: AbortSignal) => Promise<never> } {
	return {
		execute: (_id: string, _args: unknown, signal: AbortSignal) =>
			new Promise<never>((_, reject) => {
				const abortHandler = () => {
					onAbort();
					reject(new DOMException("aborted", "AbortError"));
				};
				if (signal.aborted) {
					abortHandler();
					return;
				}
				signal.addEventListener("abort", abortHandler, { once: true });
			}),
	};
}

function fakeAgent(opts: { hangingTool: ReturnType<typeof fakeHangingTool> }): Record<string, () => unknown> {
	return {
		createBashTool: () => fakeSuccessTool("ok-bash"),
		createEditTool: () => null,
		createFindTool: () => null,
		createGrepTool: () => fakeSuccessTool("ok-grep"),
		createLsTool: () => null,
		createReadTool: () => opts.hangingTool,
		createWriteTool: () => null,
	};
}

describe("tool_batch per-call timeout (kendex#96)", () => {
	test(
		"inner tool that never resolves times out, siblings succeed, child signal is aborted",
		async () => {
			const cwd = mkdtempSync(join(tmpdir(), "tool-batch-timeout-"));
			// Floor is 1000ms so anything below clamps up; pass that exact value so
			// the asserted message and elapsed budget match without surprise.
			writeBatchSettings(cwd, { batchCallTimeoutMs: 1000 });

			let abortCount = 0;
			const hangingTool = fakeHangingTool(() => {
				abortCount += 1;
			});
			const agent = fakeAgent({ hangingTool });
			const pi = makeFakePi();
			registerToolBatch(pi as unknown as Parameters<typeof registerToolBatch>[0], agent, cwd);
			expect(pi.tools.length).toBe(1);
			const def = pi.tools[0]!;

			const started = Date.now();
			const result = await def.execute(
				"toolcall-1",
				{
					calls: [
						{ args: {}, tool: "bash" },
						{ args: { path: "wedged.md" }, tool: "read" },
						{ args: { pattern: "foo" }, tool: "grep" },
					],
				},
				undefined,
				undefined,
				{ cwd },
			);
			const elapsedMs = Date.now() - started;

			// Budget: the 1s timeout plus generous slack for slow CI hosts.
			expect(elapsedMs).toBeLessThan(5_000);
			const details = result.details as {
				failed: number;
				items: Array<{ isError: boolean; resultText: string; toolName: string }>;
				succeeded: number;
				total: number;
			};
			expect(details.total).toBe(3);
			expect(details.succeeded).toBe(2);
			expect(details.failed).toBe(1);
			const readItem = details.items.find((item) => item.toolName === "read");
			expect(readItem).toBeDefined();
			expect(readItem!.isError).toBe(true);
			expect(readItem!.resultText).toContain("timed out");
			expect(readItem!.resultText).toContain("1000ms");
			expect(readItem!.resultText).toContain("read");
			const bashItem = details.items.find((item) => item.toolName === "bash");
			expect(bashItem!.isError).toBe(false);
			expect(bashItem!.resultText).toContain("ok-bash");
			const grepItem = details.items.find((item) => item.toolName === "grep");
			expect(grepItem!.isError).toBe(false);
			// Cooperative cleanup: the child signal was aborted on timeout so
			// long-running inners can release subprocess handles.
			expect(abortCount).toBe(1);
			expect(result.isError).toBe(true);
		},
		10_000,
	);

	test(
		"explicit timeout below the floor clamps to the 1s minimum",
		async () => {
			const cwd = mkdtempSync(join(tmpdir(), "tool-batch-floor-"));
			// Configure an absurdly low timeout — the floor must override it so
			// quick happy-path callers still get a sane window on slow hosts.
			writeBatchSettings(cwd, { batchCallTimeoutMs: 1 });

			const hangingTool = fakeHangingTool(() => {});
			const agent = fakeAgent({ hangingTool });
			const pi = makeFakePi();
			registerToolBatch(pi as unknown as Parameters<typeof registerToolBatch>[0], agent, cwd);
			const def = pi.tools[0]!;

			const started = Date.now();
			const result = await def.execute(
				"toolcall-2",
				{ calls: [{ args: { path: "x" }, tool: "read" }] },
				undefined,
				undefined,
				{ cwd },
			);
			const elapsedMs = Date.now() - started;

			// Must wait at least the 1s floor before rejecting.
			expect(elapsedMs).toBeGreaterThanOrEqual(900);
			const details = result.details as {
				failed: number;
				items: Array<{ resultText: string }>;
			};
			expect(details.failed).toBe(1);
			expect(details.items[0]!.resultText).toContain("1000ms");
		},
		10_000,
	);
});
