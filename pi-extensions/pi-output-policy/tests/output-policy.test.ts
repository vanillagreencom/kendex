import { describe, expect, test, beforeEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import outputPolicy, {
	__resetSessionCountersForTests,
	isSanitizeExceptTool,
	minimizeShellOutput,
	processText,
	resolvePolicyMode,
	sanitizeDetails,
} from "../extensions/output-policy.ts";

const CONFIG_ID = "@vanillagreen/pi-output-policy";

function withConfig(config: Record<string, unknown>, run: (cwd: string) => void): void {
	const dir = mkdtempSync(join(tmpdir(), "pi-output-policy-test-"));
	try {
		mkdirSync(join(dir, ".pi"), { recursive: true });
		writeFileSync(join(dir, ".pi", "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { [CONFIG_ID]: config } } },
		}, null, 2));
		run(dir);
	} finally {
		rmSync(dir, { force: true, recursive: true });
	}
}

let testSeq = 0;
function fakeCtx(cwd: string): any {
	testSeq += 1;
	const sessionId = `test-${testSeq}-${process.hrtime.bigint().toString(36)}`;
	return {
		cwd,
		sessionManager: {
			getSessionId: () => sessionId,
			getSessionFile: () => null,
		},
	};
}

beforeEach(() => {
	__resetSessionCountersForTests();
});

describe("shell minimizer", () => {
	test("minimizes noisy successful cargo output by default", () => {
		withConfig({}, (cwd) => {
			const noisy = Array.from({ length: 180 }, (_, i) => `   Compiling crate_${i} v0.1.0`).join("\n");
			const text = `${noisy}\n    Finished test profile [unoptimized] target(s) in 4.72s\ntest result: ok. 41 passed; 0 failed`;
			const result = minimizeShellOutput(text, "cargo test", cwd);
			expect(result.dropped).toBeGreaterThan(0);
			expect(result.text).toContain("repetitive/noisy line(s) minimized");
			expect(result.text).toContain("Finished test profile");
			expect(result.text).toContain("test result: ok");
		});
	});

	test("respects shellMinimizer.enabled=false", () => {
		withConfig({ "shellMinimizer.enabled": false }, (cwd) => {
			const text = Array.from({ length: 130 }, (_, i) => `line ${i}`).join("\n");
			const result = minimizeShellOutput(text, "cargo test", cwd);
			expect(result.dropped).toBe(0);
			expect(result.text).toBe(text);
		});
	});
});

describe("policy mode resolution", () => {
	test("defaults to balanced when unset", () => {
		withConfig({}, (cwd) => {
			expect(resolvePolicyMode(cwd)).toBe("balanced");
		});
	});

	test("accepts compact and compat", () => {
		withConfig({ policyMode: "compact" }, (cwd) => {
			expect(resolvePolicyMode(cwd)).toBe("compact");
		});
		withConfig({ policyMode: "compat" }, (cwd) => {
			expect(resolvePolicyMode(cwd)).toBe("compat");
		});
	});

	test("falls back to balanced for unknown values", () => {
		withConfig({ policyMode: "ludicrous" }, (cwd) => {
			expect(resolvePolicyMode(cwd)).toBe("balanced");
		});
	});
});

describe("balanced policy caps inline text", () => {
	test("non-read text >25 KB is truncated below the cap", () => {
		withConfig({}, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 4000 }, (_, i) => `payload line ${i.toString().padStart(6, "0")} ${"x".repeat(40)}`).join("\n");
			expect(text.length).toBeGreaterThan(150_000);
			const result = processText({ toolName: "grep", toolCallId: "t1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBe(true);
			expect(result.meta?.policyMode).toBe("balanced");
			expect(result.meta?.shownBytes).toBeLessThanOrEqual(25 * 1024);
			expect(result.text).toContain("[Output truncated");
			expect(result.text).toContain("Continue with the same tool");
		});
	});

	test("artifact path is preserved on the result and the file holds full content", () => {
		withConfig({}, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 4000 }, (_, i) => `line ${i} ${"q".repeat(60)}`).join("\n");
			const result = processText({ toolName: "bash", toolCallId: "art1", input: { command: "echo hello" } }, ctx, text);
			expect(result.meta?.artifactPath).toBeTruthy();
			const artifactPath = result.meta!.artifactPath!;
			expect(existsSync(artifactPath)).toBe(true);
			expect(readFileSync(artifactPath, "utf8")).toBe(text);
			expect(result.text).toContain(`Full output: ${artifactPath}`);
		});
	});

	test("compat mode allows the old 200 KB block size", () => {
		withConfig({ policyMode: "compat" }, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 1000 }, (_, i) => `compat line ${i}`).join("\n");
			const result = processText({ toolName: "grep", toolCallId: "compat1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBeFalsy();
			expect(result.text).toBe(text);
		});
	});

	test("payload between maxTextBlockKb and spillThresholdKb still truncates in balanced", () => {
		// balanced caps: spill 48 KB, maxTextBlockKb 24 KB, maxLineCount 400,
		// maxLineWidth 3000. Construct ~32 KB with every other cap comfortably
		// under threshold so ONLY the per-block byte cap can fire — that proves
		// the round-2 trigger and is not satisfied by line-width/line-count
		// fallback if maxTextBlockKb were removed from the predicate.
		withConfig({}, (cwd) => {
			const ctx = fakeCtx(cwd);
			const lineCount = 100;
			const lineWidth = 320;
			const lines = Array.from({ length: lineCount }, (_, i) => `${String(i).padStart(4, "0")} ${"a".repeat(lineWidth - 5)}`);
			const text = lines.join("\n");
			expect(text.length).toBeGreaterThan(24 * 1024);
			expect(text.length).toBeLessThan(48 * 1024);
			expect(lineCount).toBeLessThanOrEqual(400);
			expect(lines.every((line) => line.length <= 3000)).toBe(true);
			const result = processText({ toolName: "grep", toolCallId: "gap1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBe(true);
			expect(result.meta?.reason).toBe("max-text-block");
			expect(result.meta?.artifactPath).toBeTruthy();
			expect(result.meta?.shownBytes).toBeLessThanOrEqual(24 * 1024);
		});
	});

	test("payload between maxTextBlockKb and spillThresholdKb still truncates in compact", () => {
		// compact caps: spill 16 KB, maxTextBlockKb 8 KB, maxLineCount 200,
		// maxLineWidth 2000. Same isolation discipline as the balanced case.
		withConfig({ policyMode: "compact" }, (cwd) => {
			const ctx = fakeCtx(cwd);
			const lineCount = 60;
			const lineWidth = 200;
			const lines = Array.from({ length: lineCount }, (_, i) => `${String(i).padStart(4, "0")} ${"b".repeat(lineWidth - 5)}`);
			const text = lines.join("\n");
			expect(text.length).toBeGreaterThan(8 * 1024);
			expect(text.length).toBeLessThan(16 * 1024);
			expect(lineCount).toBeLessThanOrEqual(200);
			expect(lines.every((line) => line.length <= 2000)).toBe(true);
			const result = processText({ toolName: "grep", toolCallId: "gap2", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBe(true);
			expect(result.meta?.reason).toBe("max-text-block");
			expect(result.meta?.artifactPath).toBeTruthy();
			expect(result.meta?.shownBytes).toBeLessThanOrEqual(8 * 1024);
		});
	});

	test("explicit knob overrides mode default", () => {
		// compact caps: spill 16 KB / maxTextBlockKb 8 KB. Lift every triggering
		// cap explicitly and verify a ~26 KB text passes through untruncated.
		withConfig({ policyMode: "compact", spillThresholdKb: 80, maxTextBlockKb: 80, maxLineCount: 2000, maxLineWidth: 4000 }, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 600 }, (_, i) => `line ${i} ${"y".repeat(30)}`).join("\n");
			const result = processText({ toolName: "grep", toolCallId: "ov1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBeFalsy();
		});
	});
});

describe("shell minimizer + truncation interaction", () => {
	test("minimizer-only path emits inline minimized marker without meta", () => {
		withConfig({}, (cwd) => {
			const ctx = fakeCtx(cwd);
			const noisy = Array.from({ length: 500 }, (_, i) => `   Compiling noisy_crate_${i} v0.1.0`).join("\n");
			const tail = "    Finished release\ntest result: ok. 999 passed; 0 failed";
			const text = `${noisy}\n${tail}`;
			const result = processText({ toolName: "bash", toolCallId: "sm-min", input: { command: "cargo test" } }, ctx, text);
			expect(result.text).toContain("Output minimized: removed");
			expect(result.text).toContain("test result: ok");
			expect(result.meta).toBeUndefined();
		});
	});

	test("minimizer + truncation: meta reports minimization and artifact holds original full text", () => {
		// Force truncation by tightening the spill threshold below post-minimizer
		// size, so we exercise minimizer → truncate → artifact persistence in order.
		withConfig({ spillThresholdKb: 2 }, (cwd) => {
			const ctx = fakeCtx(cwd);
			const noisy = Array.from({ length: 4000 }, (_, i) => `   Compiling noisy_crate_${i} v0.1.0`).join("\n");
			const tail = "    Finished release\ntest result: ok. 999 passed; 0 failed";
			const text = `${noisy}\n${tail}`;
			const result = processText({ toolName: "bash", toolCallId: "sm-trunc", input: { command: "cargo test --release" } }, ctx, text);
			expect(result.meta?.truncated).toBe(true);
			expect(result.meta?.minimized).toBe(true);
			expect(result.meta?.minimizedDroppedLines ?? 0).toBeGreaterThan(0);
			expect(result.text).toContain("Minimized");
			expect(result.text).toContain("test result: ok");
			expect(result.meta?.artifactPath).toBeTruthy();
			// Artifact retains the ORIGINAL pre-minimizer text so the model can recover full context.
			expect(readFileSync(result.meta!.artifactPath!, "utf8")).toBe(text);
		});
	});
});

describe("sanitize details", () => {
	test("nested strings are truncated", () => {
		const big = "a".repeat(20_000);
		const result = sanitizeDetails({ note: big });
		expect(result.changed).toBe(true);
		expect((result.value as { note: string }).note.length).toBeLessThanOrEqual(8 * 1024 + 64);
		expect((result.value as { note: string }).note).toContain("[detail string truncated]");
	});

	test("oversized arrays are capped at 50 entries", () => {
		const huge = Array.from({ length: 200 }, (_, i) => ({ i }));
		const result = sanitizeDetails(huge);
		expect(result.changed).toBe(true);
		expect(Array.isArray(result.value)).toBe(true);
		expect((result.value as unknown[]).length).toBe(50);
	});

	test("deeply nested objects are bounded", () => {
		let nested: any = { leaf: true };
		for (let i = 0; i < 10; i += 1) nested = { child: nested };
		const result = sanitizeDetails(nested);
		expect(result.changed).toBe(true);
		const serialized = JSON.stringify(result.value);
		expect(serialized).toContain("[Max detail depth reached]");
	});

	test("small objects pass through unchanged", () => {
		const value = { ok: true, count: 3, label: "x" };
		const result = sanitizeDetails(value);
		expect(result.changed).toBe(false);
		expect(result.value).toEqual(value);
	});
});

describe("state-bearing details allowlist", () => {
	test("default allowlist covers tasks_write, bg_task, subagent", () => {
		withConfig({}, (cwd) => {
			expect(isSanitizeExceptTool("tasks_write", cwd)).toBe(true);
			expect(isSanitizeExceptTool("bg_task", cwd)).toBe(true);
			expect(isSanitizeExceptTool("subagent", cwd)).toBe(true);
			expect(isSanitizeExceptTool("grep", cwd)).toBe(false);
		});
	});

	test("custom allowlist replaces the default", () => {
		withConfig({ "sanitizeDetails.exceptTools": "my_state_tool,other" }, (cwd) => {
			expect(isSanitizeExceptTool("my_state_tool", cwd)).toBe(true);
			expect(isSanitizeExceptTool("tasks_write", cwd)).toBe(false);
		});
	});

	test("dotted suffix matching covers namespaced tools", () => {
		withConfig({}, (cwd) => {
			expect(isSanitizeExceptTool("ext.tasks_write", cwd)).toBe(true);
		});
	});
});

describe("saved-bytes counter", () => {
	test("accumulates across multiple truncations within a turn", () => {
		withConfig({}, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 4000 }, (_, i) => `payload ${i} ${"z".repeat(40)}`).join("\n");
			const first = processText({ toolName: "grep", toolCallId: "a", input: {} }, ctx, text);
			const second = processText({ toolName: "grep", toolCallId: "b", input: {} }, ctx, text);
			expect(first.meta?.savedBytes).toBeGreaterThan(0);
			expect(second.meta?.savedBytes).toBeGreaterThan(0);
			expect(second.meta!.turnSavedBytes!).toBeGreaterThan(first.meta!.turnSavedBytes!);
			expect(second.meta!.sessionSavedBytes!).toBe(second.meta!.turnSavedBytes!);
		});
	});
});

interface FakePi {
	pi: any;
	fire: (event: string, payload: any, ctx: any) => Promise<any>;
}

function createFakePi(): FakePi {
	const handlers = new Map<string, (event: any, ctx: any) => any>();
	const pi = {
		on(event: string, handler: any) {
			handlers.set(event, handler);
		},
	};
	return {
		pi,
		fire: async (event, payload, ctx) => {
			const handler = handlers.get(event);
			if (!handler) return undefined;
			return await handler(payload, ctx);
		},
	};
}

describe("tool_result handler (default-on sanitization & metadata)", () => {
	test("oversized non-allowlisted details are sanitized and carry a marker", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const ctx = fakeCtx(cwd);
				const details: Record<string, unknown> = { big: "x".repeat(20_000) };
				for (let i = 0; i < 200; i += 1) details[`field_${i}`] = i;
				fake.fire("tool_result", {
					toolName: "grep",
					toolCallId: "h1",
					input: {},
					content: [{ type: "text", text: "hello" }],
					details,
					isError: false,
				}, ctx).then((result: any) => {
					expect(result).toBeTruthy();
					expect(Object.keys(result.details).length).toBeLessThanOrEqual(81 + 1);
					expect(result.details["[output-policy:truncated]"]).toMatch(/object truncated/);
					expect(result.details.vstackOutputPolicySanitized).toBeTruthy();
					expect(result.details.vstackOutputPolicySanitized.policyMode).toBe("balanced");
					expect(typeof result.details.big).toBe("string");
					expect(result.details.big.length).toBeLessThanOrEqual(8 * 1024 + 64);
					expect(result.details.big).toContain("[detail string truncated]");
					resolveTest();
				});
			});
		});
	});

	test("tasks_write details pass through untouched (state-bearing allowlist)", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const ctx = fakeCtx(cwd);
				const details: Record<string, unknown> = {};
				for (let i = 0; i < 200; i += 1) details[`task_${i}`] = { id: i, title: "x".repeat(20_000) };
				fake.fire("tool_result", {
					toolName: "tasks_write",
					toolCallId: "h2",
					input: {},
					content: [{ type: "text", text: "ok" }],
					details,
					isError: false,
				}, ctx).then((result: any) => {
					// `tasks_write` text isn't oversized and details are exempt → handler returns undefined (no changes).
					expect(result).toBeUndefined();
					resolveTest();
				});
			});
		});
	});

	test("vstackOutputPolicy meta is attached when text is truncated", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const ctx = fakeCtx(cwd);
				const huge = Array.from({ length: 4000 }, (_, i) => `match ${i} ${"q".repeat(40)}`).join("\n");
				fake.fire("tool_result", {
					toolName: "grep",
					toolCallId: "h3",
					input: {},
					content: [{ type: "text", text: huge }],
					details: { ok: true },
					isError: false,
				}, ctx).then((result: any) => {
					expect(result.details.vstackOutputPolicy).toBeInstanceOf(Array);
					expect(result.details.vstackOutputPolicy[0].truncated).toBe(true);
					expect(result.details.vstackOutputPolicy[0].artifactPath).toBeTruthy();
					expect(result.content[0].text).toContain("[Output truncated");
					resolveTest();
				});
			});
		});
	});

	test("compat mode skips default sanitization", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({ policyMode: "compat" }, (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const ctx = fakeCtx(cwd);
				const details: Record<string, unknown> = {};
				for (let i = 0; i < 200; i += 1) details[`field_${i}`] = i;
				fake.fire("tool_result", {
					toolName: "grep",
					toolCallId: "h4",
					input: {},
					content: [{ type: "text", text: "ok" }],
					details,
					isError: false,
				}, ctx).then((result: any) => {
					// compat: no sanitization, no text truncation → no change.
					expect(result).toBeUndefined();
					resolveTest();
				});
			});
		});
	});

	test("array details get a sentinel when capped", () => {
		const huge = Array.from({ length: 300 }, (_, i) => ({ i }));
		const result = sanitizeDetails(huge);
		expect(result.changed).toBe(true);
		const arr = result.value as unknown[];
		expect(arr.length).toBe(50);
		expect(typeof arr[arr.length - 1]).toBe("string");
		expect(arr[arr.length - 1]).toMatch(/array truncated, dropped/);
	});
});

describe("handler-level counter lifecycle", () => {
	async function runWithHandlers(
		cwd: string,
		fn: (fake: FakePi, ctx: any, oversized: string) => Promise<void>,
	): Promise<void> {
		const fake = createFakePi();
		outputPolicy(fake.pi);
		const ctx = fakeCtx(cwd);
		const oversized = Array.from({ length: 4000 }, (_, i) => `line ${i} ${"w".repeat(40)}`).join("\n");
		await fn(fake, ctx, oversized);
	}

	test("turn_start resets turnSavedBytes, sessionSavedBytes persists", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				runWithHandlers(cwd, async (fake, ctx, oversized) => {
					const r1: any = await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "t1",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					const meta1 = r1.details.vstackOutputPolicy[0];
					expect(meta1.turnSavedBytes).toBeGreaterThan(0);
					expect(meta1.sessionSavedBytes).toBe(meta1.turnSavedBytes);

					await fake.fire("turn_start", { type: "turn_start", turnIndex: 1, timestamp: 0 }, ctx);

					const r2: any = await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "t2",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					const meta2 = r2.details.vstackOutputPolicy[0];
					// Turn counter restarted from 0, then this call added saved bytes.
					expect(meta2.turnSavedBytes).toBe(meta2.savedBytes);
					expect(meta2.turnSavedBytes).toBeLessThan(meta1.sessionSavedBytes + meta2.savedBytes);
					expect(meta2.sessionSavedBytes).toBe(meta1.sessionSavedBytes + meta2.savedBytes);
					resolveTest();
				});
			});
		});
	});

	test("session_start clears all counters", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				runWithHandlers(cwd, async (fake, ctx, oversized) => {
					await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "s1",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					await fake.fire("session_start", { type: "session_start" }, ctx);
					const r2: any = await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "s2",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					const meta2 = r2.details.vstackOutputPolicy[0];
					// Session reset means sessionSavedBytes equals what this single call added.
					expect(meta2.sessionSavedBytes).toBe(meta2.savedBytes);
					expect(meta2.turnSavedBytes).toBe(meta2.savedBytes);
					resolveTest();
				});
			});
		});
	});

	test("session_shutdown clears counters", async () => {
		await new Promise<void>((resolveTest) => {
			withConfig({}, (cwd) => {
				runWithHandlers(cwd, async (fake, ctx, oversized) => {
					await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "sh1",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					await fake.fire("session_shutdown", { type: "session_shutdown" }, ctx);
					const r2: any = await fake.fire("tool_result", {
						toolName: "grep",
						toolCallId: "sh2",
						input: {},
						content: [{ type: "text", text: oversized }],
						details: {},
						isError: false,
					}, ctx);
					const meta2 = r2.details.vstackOutputPolicy[0];
					expect(meta2.sessionSavedBytes).toBe(meta2.savedBytes);
					expect(meta2.turnSavedBytes).toBe(meta2.savedBytes);
					resolveTest();
				});
			});
		});
	});
});
