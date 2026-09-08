import { expect, test, beforeEach } from "bun:test";
import outputPolicy, { __resetSessionCountersForTests } from "../extensions/output-policy.ts";
import { withConfigAsync, fakeCtx, createFakePi } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

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
