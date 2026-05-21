import { describe, expect, test, beforeEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
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

	test("explicit knob overrides mode default", () => {
		// compact spill threshold is 16 KB; explicitly lifting it to 80 plus lifting
		// the line/width caps should let a ~26 KB text pass through untruncated.
		withConfig({ policyMode: "compact", spillThresholdKb: 80, maxLineCount: 2000, maxLineWidth: 4000 }, (cwd) => {
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
