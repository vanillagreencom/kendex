import { describe, expect, test, beforeEach, spyOn } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import * as fsp from "node:fs/promises";
import { join } from "node:path";
import { __resetSessionCountersForTests, processContent } from "../extensions/output-policy.ts";
import { withConfigAsync, fakeCtx, processOne } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

describe("balanced policy caps inline text", () => {
	test("non-read text >25 KB is truncated below the cap", async () => {
		await withConfigAsync({}, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 4000 }, (_, i) => `payload line ${i.toString().padStart(6, "0")} ${"x".repeat(40)}`).join("\n");
			expect(text.length).toBeGreaterThan(150_000);
			const result = await processOne({ toolName: "grep", toolCallId: "t1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBe(true);
			expect(result.meta?.policyMode).toBe("balanced");
			expect(result.meta?.shownBytes).toBeLessThanOrEqual(25 * 1024);
			expect(result.text).toContain(`[output-policy:truncated-bytes=${Buffer.byteLength(text)}]`);
			expect(result.meta?.direction).toBe("head");
			expect(result.meta!.shownLines).toBeLessThan(result.meta!.totalLines);
		});
	});

	test("artifact path is preserved on the result and the file holds full content", async () => {
		await withConfigAsync({}, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 4000 }, (_, i) => `line ${i} ${"q".repeat(60)}`).join("\n");
			const result = await processOne({ toolName: "bash", toolCallId: "art1", input: { command: "echo hello" } }, ctx, text);
			expect(result.meta?.artifactPath).toBeTruthy();
			const artifactPath = result.meta!.artifactPath!;
			expect(existsSync(artifactPath)).toBe(true);
			expect(readFileSync(artifactPath, "utf8")).toBe(text);
			expect(result.text).toContain(artifactPath);
		});
	});

	test("compat mode preserves a short multiline result", async () => {
		await withConfigAsync({ policyMode: "compat" }, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 1000 }, (_, i) => `compat line ${i}`).join("\n");
			const result = await processOne({ toolName: "grep", toolCallId: "compat1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBeFalsy();
			expect(result.text).toBe(text);
		});
	});

	test("per-block byte caps apply below spill and line limits", async () => {
		for (const row of [
			{ mode: "balanced", count: 100, width: 320, fill: "a", cap: 24, spill: 48, maxLines: 400, maxWidth: 3000 },
			{ mode: "compact", count: 60, width: 200, fill: "b", cap: 8, spill: 16, maxLines: 200, maxWidth: 2000 },
		]) {
			await withConfigAsync({ policyMode: row.mode }, async (cwd) => {
				const lines = Array.from({ length: row.count }, (_, i) => `${String(i).padStart(4, "0")} ${row.fill.repeat(row.width - 5)}`);
				const text = lines.join("\n");
				expect(text.length).toBeGreaterThan(row.cap * 1024);
				expect(text.length).toBeLessThan(row.spill * 1024);
				expect(lines.length).toBeLessThanOrEqual(row.maxLines);
				expect(lines.every(line => line.length <= row.maxWidth)).toBe(true);
				const result = await processOne({ toolName: "grep", toolCallId: row.mode, input: {} }, fakeCtx(cwd), text);
				expect(result.meta?.truncated).toBe(true);
				expect(result.meta?.reason).toBe("max-text-block");
				expect(result.meta?.artifactPath).toBeString();
				expect(result.meta?.shownBytes).toBeLessThanOrEqual(row.cap * 1024);
			});
		}
	});

	test("explicit knob overrides mode default", async () => {
		// compact caps: spill 16 KB / maxTextBlockKb 8 KB. Lift every triggering
		// cap explicitly and verify a ~26 KB text passes through untruncated.
		await withConfigAsync({ policyMode: "compact", spillThresholdKb: 80, maxTextBlockKb: 80, maxLineCount: 2000, maxLineWidth: 4000 }, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const text = Array.from({ length: 600 }, (_, i) => `line ${i} ${"y".repeat(30)}`).join("\n");
			const result = await processOne({ toolName: "grep", toolCallId: "ov1", input: {} }, ctx, text);
			expect(result.meta?.truncated).toBeFalsy();
		});
	});
});


describe("shell minimizer + truncation interaction", () => {
	test("minimizer-only path emits inline minimized marker without meta", async () => {
		await withConfigAsync({}, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const noisy = Array.from({ length: 500 }, (_, i) => `   Compiling noisy_crate_${i} v0.1.0`).join("\n");
			const tail = "    Finished release\ntest result: ok. 999 passed; 0 failed";
			const text = `${noisy}\n${tail}`;
			const result = await processOne({ toolName: "bash", toolCallId: "sm-min", input: { command: "cargo test" } }, ctx, text);
			const outputLines = new Set(result.text.split("\n"));
			const removed = text.split("\n").filter(line => !outputLines.has(line)).length;
			const summary = result.text.split("\n\n").at(-1)!;
			expect(removed).toBeGreaterThan(0);
			expect(summary.split("\n")[0]).toBe(`[output-policy:minimized-lines=${removed}]`);
			expect(result.text).toContain("test result: ok");
			expect(result.meta).toBeUndefined();
		});
	});

	test("minimizer + truncation: meta reports minimization and artifact holds original full text", async () => {
		// Force truncation by tightening the spill threshold below post-minimizer
		// size, so we exercise minimizer → truncate → artifact persistence in order.
		await withConfigAsync({ spillThresholdKb: 2 }, async (cwd) => {
			const ctx = fakeCtx(cwd);
			const noisy = Array.from({ length: 4000 }, (_, i) => `   Compiling noisy_crate_${i} v0.1.0`).join("\n");
			const tail = "    Finished release\ntest result: ok. 999 passed; 0 failed";
			const text = `${noisy}\n${tail}`;
			const result = await processOne({ toolName: "bash", toolCallId: "sm-trunc", input: { command: "cargo test --release" } }, ctx, text);
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


describe("one inline budget per tool result", () => {
	const block = (label: string, lines: number) => Array.from({ length: lines }, (_, i) => `${label} ${String(i).padStart(4, "0")} ${"z".repeat(90)}`).join("\n");
	const textOf = (content: readonly unknown[]) => content.flatMap((part) => (part as { type: string }).type === "text" ? [(part as { text: string }).text] : []);

	test("text parts share the budget, notice included, and the artifact holds every part", async () => {
		const image = { type: "image", data: "aW1n", mimeType: "image/png" };
		// One-character lines under a lifted line cap fill the byte budget to the byte.
		const tight = { maxLineCount: 100_000, inlineTailLines: 100_000 };
		for (const row of [
			{ tool: "grep", input: {}, blocks: 20, lines: 300, budgetKb: 24, direction: "head", config: {} },
			{ tool: "grep", input: {}, blocks: 20, lines: 50, budgetKb: 24, direction: "head", config: {} },
			{ tool: "bash", input: { command: "printf" }, blocks: 3, lines: 100, budgetKb: 16, direction: "tail", config: {} },
			{ tool: "grep", input: {}, blocks: 2, lines: 20_000, budgetKb: 24, direction: "head", config: tight, fill: "x" },
			{ tool: "bash", input: { command: "printf" }, blocks: 2, lines: 20_000, budgetKb: 16, direction: "tail", config: tight, fill: "x" },
		]) {
			await withConfigAsync(row.config, async (cwd) => {
				const blocks = Array.from({ length: row.blocks }, (_, i) => row.fill ? Array(row.lines).fill(row.fill).join("\n") : block(`b${i}`, row.lines));
				const all = blocks.join("\n");
				const result = await processContent({ toolName: row.tool, toolCallId: row.tool, input: row.input }, fakeCtx(cwd), [image, ...blocks.map((text) => ({ type: "text", text }))]);
				expect(result.content[0]).toBe(image);
				const texts = textOf(result.content);
				expect(texts.reduce((sum, text) => sum + Buffer.byteLength(text), 0)).toBeLessThanOrEqual(row.budgetKb * 1024);
				expect(texts.length).toBeLessThan(row.blocks);
				const joined = texts.join("\n");
				const header = `\n\n[output-policy:truncated-bytes=${Buffer.byteLength(all)}]\n`;
				expect(texts.at(-1)!.includes(header)).toBe(true);
				const noticeAt = joined.lastIndexOf(header);
				const meta = result.meta!;
				expect(meta.direction).toBe(row.direction);
				expect(meta.totalLines).toBe(row.blocks * row.lines);
				const lines = all.split("\n");
				const expected = row.direction === "head" ? lines.slice(0, meta.shownLines) : lines.slice(-meta.shownLines);
				expect(joined.slice(0, noticeAt)).toBe(expected.join("\n"));
				expect(meta.shownRange).toBe(row.direction === "head" ? `lines 1-${meta.shownLines}` : `lines ${meta.totalLines - meta.shownLines + 1}-${meta.totalLines}`);
				expect(readFileSync(meta.artifactPath!, "utf8")).toBe(all);
			});
		}
	});

	test("a failed artifact write names its error in its own notice", async () => {
		await withConfigAsync({}, async (cwd) => {
			const blocker = join(cwd, "blocker");
			writeFileSync(blocker, "");
			const previousTmp = process.env.TMPDIR;
			process.env.PI_CODING_AGENT_DIR = join(blocker, "agent");
			process.env.TMPDIR = join(blocker, "tmp");
			try {
				const text = block("w", 400);
				const result = await processOne({ toolName: "grep", toolCallId: "werr", input: {} }, fakeCtx(cwd), text);
				expect(result.meta?.artifactPath).toBeUndefined();
				expect(result.meta?.artifactError?.split("; ")).toHaveLength(2);
				expect(result.meta?.artifactError).toContain("ENOTDIR");
				expect(result.text).toContain(`\n\n[output-policy:artifact-error=${JSON.stringify(result.meta!.artifactError)}]\n`);
				expect(Buffer.byteLength(result.text)).toBeLessThanOrEqual(24 * 1024);
			} finally {
				if (previousTmp === undefined) delete process.env.TMPDIR;
				else process.env.TMPDIR = previousTmp;
			}
		});
	});

	test("artifact writes run at most two at a time", async () => {
		const realOpen = fsp.open;
		let open = 0;
		let peak = 0;
		const spy = spyOn(fsp, "open").mockImplementation((async (...args: Parameters<typeof fsp.open>) => {
			const handle = await realOpen(...args);
			open += 1;
			peak = Math.max(peak, open);
			const close = handle.close.bind(handle);
			handle.close = async () => { open -= 1; await close(); };
			return handle;
		}) as typeof fsp.open);
		try {
			await withConfigAsync({}, async (cwd) => {
				const text = "q".repeat(3 * 1024 * 1024);
				const ctx = fakeCtx(cwd);
				const results = await Promise.all(Array.from({ length: 6 }, (_, i) => processContent({ toolName: "grep", toolCallId: `c${i}`, input: {} }, ctx, [{ type: "text", text }])));
				for (const result of results) expect(result.meta?.artifactPath).toBeString();
			});
		} finally {
			spy.mockRestore();
		}
		expect(peak).toBeGreaterThan(0);
		expect(peak).toBeLessThanOrEqual(2);
	});
});
