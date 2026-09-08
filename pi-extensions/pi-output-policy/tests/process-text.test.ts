import { describe, expect, test, beforeEach } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { __resetSessionCountersForTests, processText } from "../extensions/output-policy.ts";
import { withConfig, fakeCtx } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

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
			expect(result.text).toContain(`[output-policy:truncated-bytes=${Buffer.byteLength(text)}]`);
			expect(result.meta?.direction).toBe("head");
			expect(result.meta!.shownLines).toBeLessThan(result.meta!.totalLines);
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
			expect(result.text).toContain(artifactPath);
		});
	});

	test("compat mode preserves a short multiline result", () => {
		withConfig({ policyMode: "compat" }, (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 1000 }, (_, i) => `compat line ${i}`).join("\n");
			const result = processText({ toolName: "grep", toolCallId: "compat1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBeFalsy();
			expect(result.text).toBe(text);
		});
	});

	test("per-block byte caps apply below spill and line limits", () => {
		for (const row of [
			{ mode: "balanced", count: 100, width: 320, fill: "a", cap: 24, spill: 48, maxLines: 400, maxWidth: 3000 },
			{ mode: "compact", count: 60, width: 200, fill: "b", cap: 8, spill: 16, maxLines: 200, maxWidth: 2000 },
		]) {
			withConfig({ policyMode: row.mode }, (cwd) => {
				const lines = Array.from({ length: row.count }, (_, i) => `${String(i).padStart(4, "0")} ${row.fill.repeat(row.width - 5)}`);
				const text = lines.join("\n");
				expect(text.length).toBeGreaterThan(row.cap * 1024);
				expect(text.length).toBeLessThan(row.spill * 1024);
				expect(lines.length).toBeLessThanOrEqual(row.maxLines);
				expect(lines.every(line => line.length <= row.maxWidth)).toBe(true);
				const result = processText({ toolName: "grep", toolCallId: row.mode, input: {} }, fakeCtx(cwd), text);
				expect(result.meta?.truncated).toBe(true);
				expect(result.meta?.reason).toBe("max-text-block");
				expect(result.meta?.artifactPath).toBeString();
				expect(result.meta?.shownBytes).toBeLessThanOrEqual(row.cap * 1024);
			});
		}
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
			const outputLines = new Set(result.text.split("\n"));
			const removed = text.split("\n").filter(line => !outputLines.has(line)).length;
			const summary = result.text.split("\n\n").at(-1)!;
			expect(removed).toBeGreaterThan(0);
			expect(summary.split("\n")[0]).toBe(`[output-policy:minimized-lines=${removed}]`);
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
			expect(result.text).toContain(`[output-policy:minimized-lines=${result.meta!.minimizedDroppedLines}]`);
			expect(result.text).toContain("test result: ok");
			expect(result.meta?.artifactPath).toBeTruthy();
			// Artifact retains the ORIGINAL pre-minimizer text so the model can recover full context.
			expect(readFileSync(result.meta!.artifactPath!, "utf8")).toBe(text);
		});
	});
});

