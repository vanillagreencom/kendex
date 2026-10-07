import { expect, test, beforeEach } from "bun:test";
import outputPolicy, { __resetSessionCountersForTests, minimizeShellOutput } from "../extensions/output-policy.ts";
import { withConfigAsync, fakeCtx, createFakePi } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

test("tool-result presentation changes preserve structured tool output", async () => {
	const noisy = Array.from({ length: 180 }, (_, i) => `   Compiling crate_${i} v0.1.0`).join("\n");
	for (const row of [
		{ name: "details only", text: "hello", details: { big: "x".repeat(20_000) }, changed: false },
		{ name: "truncated", text: "q".repeat(30_000), details: {}, changed: true },
		{ name: "minimized", text: noisy, details: {}, changed: true },
	]) {
		for (const structuredContent of [{ output: row.text, truncated: false, exit_code: 0 }, undefined]) {
			await withConfigAsync({}, async (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const content = [{ type: "text", text: row.text }];
				const event = { toolName: "bash", toolCallId: row.name, input: { command: "cargo test" }, content, details: row.details, isError: false, ...(structuredContent === undefined ? {} : { structuredContent }) };
				const result = await fake.fire("tool_result", event, fakeCtx(cwd));
				expect(result).toBeDefined();
				if (row.changed) {
					expect(result!.content).not.toEqual(content);
					expect(result!.structuredContent).toBe(structuredContent);
				} else {
					expect(result!.content).toBeUndefined();
					expect(result!.details.big.length).toBeLessThan(row.details.big!.length);
				}
				expect(event.content).toBe(content);
			});
		}
	}
});

test("tool-result detail sanitization", async () => {
	for (const row of [
		{ kind: "object", toolName: "grep", config: {}, changes: true },
		{ kind: "string", toolName: "grep", config: {}, changes: true },
		{ kind: "object", toolName: "tasks_write", config: {}, changes: false },
		{ kind: "object", toolName: "grep", config: { policyMode: "compat" }, changes: false },
	]) {
		await withConfigAsync(row.config, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const details = row.kind === "string" ? { big: "x".repeat(20_000) } : Object.fromEntries(Array.from({ length: 200 }, (_, i) => [`field_${i}`, i]));
			const result = await fake.fire("tool_result", { toolName: row.toolName, toolCallId: row.kind, input: {}, content: [{ type: "text", text: "hello" }], details, isError: false }, fakeCtx(cwd));
			if (!row.changes) {
				expect(result).toBeUndefined();
			} else {
				expect(result!.details.kendexOutputPolicySanitized.policyMode).toBe("balanced");
				if (row.kind === "object") {
					expect(Object.keys(result!.details).length).toBeLessThanOrEqual(82);
					expect((result!.details["[output-policy:truncated]"] as string).split("\n")[0]).toBe("[output-policy:detail-object-cap=80]");
				} else {
					expect(typeof result!.details.big).toBe("string");
					expect(result!.details.big.length).toBeLessThanOrEqual(8 * 1024 + 100);
					expect(result!.details.big).toContain("[output-policy:detail-chars=20000]");
				}
			}
		});
	}
});

test("truncated tool text carries metadata and its artifact path", async () => {
	await withConfigAsync({}, async (cwd) => {
		const fake = createFakePi();
		outputPolicy(fake.pi);
		const huge = Array.from({ length: 4000 }, (_, i) => `match ${i} ${"q".repeat(40)}`).join("\n");
		const result = await fake.fire("tool_result", { toolName: "grep", toolCallId: "text", input: {}, content: [{ type: "text", text: huge }], details: { ok: true }, isError: false }, fakeCtx(cwd));
		expect(result!.details.kendexOutputPolicy).toBeInstanceOf(Array);
		expect(result!.details.kendexOutputPolicy[0].truncated).toBe(true);
		expect(result!.details.kendexOutputPolicy[0].artifactPath).toBeString();
		expect(result!.content[0].text).toContain(`[output-policy:truncated-bytes=${Buffer.byteLength(huge)}]`);
	});
});

test("a result of several text parts carries one truncation entry for all of them", async () => {
	await withConfigAsync({}, async (cwd) => {
		const fake = createFakePi();
		outputPolicy(fake.pi);
		// Every other line is a warning the minimizer keeps, so both parts stay over the line cap.
		const part = (label: string) => Array.from({ length: 1_000 }, (_, i) => i % 2 ? `warning: ${label} ${i}` : `   Compiling ${label}_${i}`).join("\n");
		const parts = [part("a"), part("b")];
		const result = await fake.fire("tool_result", { toolName: "bash", toolCallId: "two", input: { command: "cargo test" }, content: parts.map((text) => ({ type: "text", text })), details: {}, isError: false }, fakeCtx(cwd));
		const entries = result!.details.kendexOutputPolicy;
		expect(entries).toHaveLength(1);
		expect(entries[0].minimizedDroppedLines).toBe(parts.reduce((sum, text) => sum + minimizeShellOutput(text, "cargo test", cwd).dropped, 0));
		expect(entries[0].minimizedDroppedLines).toBeGreaterThan(minimizeShellOutput(parts[0], "cargo test", cwd).dropped);
	});
});
