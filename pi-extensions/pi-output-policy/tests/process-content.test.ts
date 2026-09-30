import { describe, expect, test, beforeEach, spyOn } from "bun:test";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
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
	test("the minimized notice counts toward the line cap", async () => {
		// The minimizer drops 100 lines for a 2-line gap marker, so N input lines
		// minimize to N - 98; the notice after them adds a blank line and 2 more.
		for (const row of [
			{ input: 496, truncated: true },
			{ input: 495, truncated: false },
		]) {
			await withConfigAsync({}, async (cwd) => {
				const lines = Array.from({ length: row.input }, (_, i) => i >= 20 && i < 120 ? `   Compiling noise_${i}` : `warning: kept ${i}`);
				const result = await processOne({ toolName: "bash", toolCallId: "sm-lines", input: { command: "cargo build" } }, fakeCtx(cwd), lines.join("\n"));
				const returned = result.text.split("\n").length;
				if (row.truncated) {
					expect(result.meta?.reason).toBe("ui-safety");
					expect(returned).toBeLessThanOrEqual(400);
				} else {
					expect(result.meta).toBeUndefined();
					expect(returned).toBe(400);
				}
			});
		}
	});

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
		const blocks = (count: number, lines: number) => Array.from({ length: count }, (_, i) => block(`b${i}`, lines));
		const repeat = (count: number, line: string, lines: number) => Array.from({ length: count }, () => Array(lines).fill(line).join("\n"));
		const bash = { tool: "bash", input: { command: "printf" }, direction: "tail" };
		const grep = { tool: "grep", input: {}, direction: "head" };
		// `bytes` and `lines` are the caps the whole returned text, notice included,
		// must stay within; `width` is maxLineWidth. One-character lines under a
		// lifted line cap fill the byte budget to the byte.
		const tight = { maxLineCount: 100_000, inlineTailLines: 100_000 };
		for (const row of [
			{ ...grep, parts: blocks(20, 300), bytes: 24, lines: 400, config: {} },
			{ ...grep, parts: blocks(20, 50), bytes: 24, lines: 400, config: {} },
			{ ...bash, parts: blocks(3, 100), bytes: 16, lines: 400, config: {} },
			{ ...grep, parts: repeat(2, "x", 20_000), bytes: 24, lines: 100_000, config: tight },
			{ ...bash, parts: repeat(2, "x", 20_000), bytes: 16, lines: 100_000, config: tight },
			// The tail allowance is capped by the text block and line caps.
			{ ...bash, parts: blocks(3, 100), bytes: 8, lines: 400, config: { inlineTailKb: 100, maxTextBlockKb: 8 } },
			{ ...bash, parts: blocks(2, 200), bytes: 16, lines: 50, config: { inlineTailLines: 5_000, maxLineCount: 50 } },
			// The line cap alone trips and binds across two parts.
			{ ...grep, parts: repeat(2, "x", 300), bytes: 24, lines: 400, config: {}, reason: "ui-safety" },
			{ ...grep, parts: [["a", "w".repeat(5_000), "b"].join("\n")], bytes: 24, lines: 400, config: {}, reason: "ui-safety" },
			// The preview stops at the first line that does not fit, even when a
			// later part has lines that would.
			{ ...grep, parts: [block("b0", 300), Array(50).fill("x").join("\n")], bytes: 24, lines: 400, config: {} },
			{ ...grep, parts: [block("c", 300).replaceAll("\n", "\r\n")], bytes: 24, lines: 400, config: {} },
			{ ...bash, parts: [block("c", 300).replaceAll("\n", "\r\n")], bytes: 16, lines: 400, config: {} },
			// A line cap under the floor rises to it: the notice takes 3 of 7 lines.
			{ ...grep, parts: blocks(20, 50), bytes: 24, lines: 7, config: { maxLineCount: 1 }, shown: 4 },
			{ ...bash, parts: blocks(2, 200), bytes: 16, lines: 7, config: { inlineTailLines: 1 }, shown: 4 },
			// A first line larger than the whole budget is cut to it, whole characters only.
			{ ...grep, parts: ["😀".repeat(1_500)], bytes: 1, lines: 400, config: { maxTextBlockKb: 1, maxLineWidth: 100_000 }, cutFirst: true },
		]) {
			await withConfigAsync(row.config, async (cwd) => {
				const all = row.parts.join("\n");
				const width = (row.config as { maxLineWidth?: number }).maxLineWidth ?? 3_000;
				const result = await processContent({ toolName: row.tool, toolCallId: row.tool, input: row.input }, fakeCtx(cwd), [image, ...row.parts.map((text) => ({ type: "text", text }))]);
				expect(result.content[0]).toBe(image);
				const texts = textOf(result.content);
				const joined = texts.join("\n");
				expect(Buffer.byteLength(joined) - (texts.length - 1)).toBeLessThanOrEqual(row.bytes * 1024);
				expect(joined.split("\n").length).toBeLessThanOrEqual(row.lines);
				const header = `\n\n[output-policy:truncated-bytes=${Buffer.byteLength(all)}]\n`;
				expect(texts.at(-1)!.includes(header)).toBe(true);
				const preview = joined.slice(0, joined.lastIndexOf(header));
				const meta = result.meta!;
				expect(meta.direction).toBe(row.direction);
				if (row.reason) expect(meta.reason).toBe(row.reason);
				if (row.shown !== undefined) expect(meta.shownLines).toBe(row.shown);
				const lines = all.split(/\r?\n/);
				expect(meta.totalLines).toBe(lines.length);
				if (row.cutFirst) {
					expect(meta.shownLines).toBe(1);
					expect(lines[0].startsWith(preview)).toBe(true);
					expect(Buffer.from(preview).toString()).toBe(preview);
				} else {
					const shown = lines.map((line) => line.length > width ? `${line.slice(0, width - 1)}…` : line);
					const expected = row.direction === "head" ? shown.slice(0, meta.shownLines) : shown.slice(-meta.shownLines);
					expect(preview).toBe(expected.join("\n"));
				}
				expect(meta.shownRange).toBe(row.direction === "head" ? `lines 1-${meta.shownLines}` : `lines ${meta.totalLines - meta.shownLines + 1}-${meta.totalLines}`);
				expect(readFileSync(meta.artifactPath!, "utf8")).toBe(all);
			});
		}
	});

	test("a result within every limit passes through byte-identical", async () => {
		await withConfigAsync({}, async (cwd) => {
			const content = [{ type: "text", text: "alpha\r\nbeta\r\n" }];
			const result = await processContent({ toolName: "grep", toolCallId: "crlf", input: {} }, fakeCtx(cwd), content);
			expect(result.changed).toBe(false);
			expect(result.content).toBe(content);
		});
	});

	test("a failed artifact write names its error in its own notice", async () => {
		// At the line cap's floor, the truncation and write-error notices take 6
		// of 7 lines and the preview keeps one.
		for (const row of [
			{ config: {}, lines: 400 },
			{ config: { maxLineCount: 1 }, lines: 7, shown: 1 },
		]) {
			await withConfigAsync(row.config, async (cwd) => {
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
					expect(result.text.split("\n").length).toBeLessThanOrEqual(row.lines);
					if (row.shown !== undefined) {
						expect(result.meta?.shownLines).toBe(row.shown);
						expect(result.meta?.shownRange).toBe(`lines 1-${row.shown}`);
					}
				} finally {
					if (previousTmp === undefined) delete process.env.TMPDIR;
					else process.env.TMPDIR = previousTmp;
				}
			});
		}
	});

	test("a notice that fills the byte budget leaves a preview of no lines", async () => {
		for (const tool of ["grep", "bash"]) {
			await withConfigAsync({ maxTextBlockKb: 1 }, async (cwd) => {
				// An artifact path over 1 KB makes the notice alone exceed the budget.
				process.env.PI_CODING_AGENT_DIR = join(cwd, ...Array(5).fill("d".repeat(240)));
				const result = await processContent({ toolName: tool, toolCallId: tool, input: { command: "printf" } }, fakeCtx(cwd), [{ type: "text", text: block("n", 100) }]);
				expect(result.meta?.shownLines).toBe(0);
				expect(result.meta?.shownRange).toBe("none");
				expect(textOf(result.content)).toHaveLength(1);
				expect(textOf(result.content)[0].startsWith("[output-policy:truncated-bytes=")).toBe(true);
			});
		}
	});

	test("a write that fails part way leaves no artifact", async () => {
		const realOpen = fsp.open;
		const spy = spyOn(fsp, "open").mockImplementation((async (...args: Parameters<typeof fsp.open>) => {
			const handle = await realOpen(...args);
			const write = handle.write.bind(handle) as (...rest: unknown[]) => Promise<{ bytesWritten: number }>;
			let calls = 0;
			// The first chunk lands, so a partial file exists; the next makes no progress.
			handle.write = (async (...rest: unknown[]) => (calls++ === 0 ? write(...rest) : { bytesWritten: 0, buffer: rest[0] })) as typeof handle.write;
			return handle;
		}) as typeof fsp.open);
		try {
			await withConfigAsync({}, async (cwd) => {
				const previousTmp = process.env.TMPDIR;
				process.env.TMPDIR = join(cwd, "tmp");
				try {
					const result = await processOne({ toolName: "grep", toolCallId: "partial", input: {} }, fakeCtx(cwd), "p".repeat(256 * 1024));
					expect(result.meta?.artifactPath).toBeUndefined();
					expect(result.meta?.artifactError?.split("; ").map((error) => error.split(" ")[1])).toEqual(["artifact-write=no-progress", "artifact-write=no-progress"]);
					const files = readdirSync(cwd, { recursive: true }).map(String).filter((path) => path.endsWith(".txt"));
					expect(files).toEqual([]);
				} finally {
					if (previousTmp === undefined) delete process.env.TMPDIR;
					else process.env.TMPDIR = previousTmp;
				}
			});
		} finally {
			spy.mockRestore();
		}
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
				// A second wave shows each released slot went back exactly once.
				for (const wave of [0, 1]) {
					const results = await Promise.all(Array.from({ length: 6 }, (_, i) => processContent({ toolName: "grep", toolCallId: `c${wave}-${i}`, input: {} }, ctx, [{ type: "text", text }])));
					for (const result of results) expect(result.meta?.artifactPath).toBeString();
				}
			});
		} finally {
			spy.mockRestore();
		}
		expect(peak).toBeGreaterThan(0);
		expect(peak).toBeLessThanOrEqual(2);
	});
});
