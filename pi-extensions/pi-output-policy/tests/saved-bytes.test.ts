import { describe, expect, test, beforeEach } from "bun:test";
import outputPolicy, { __resetSessionCountersForTests, processText } from "../extensions/output-policy.ts";
import { withConfig, withConfigAsync, fakeCtx, createFakePi } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

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

test("counter lifecycle", async () => {
	for (const reset of ["turn_start", "session_start", "session_shutdown"]) {
		await withConfigAsync({}, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const ctx = fakeCtx(cwd);
			const oversized = Array.from({ length: 4000 }, (_, i) => `line ${i} ${"w".repeat(40)}`).join("\n");
			const event = { toolName: "grep", toolCallId: "first", input: {}, content: [{ type: "text", text: oversized }], details: {}, isError: false };
			const first = await fake.fire("tool_result", event, ctx);
			const meta1 = first!.details.kendexOutputPolicy[0];
			expect(meta1.turnSavedBytes).toBeGreaterThan(0);
			expect(meta1.sessionSavedBytes).toBe(meta1.turnSavedBytes);
			await fake.fire(reset, { type: reset, turnIndex: 1, timestamp: 0 }, ctx);
			const second = await fake.fire("tool_result", { ...event, toolCallId: "second" }, ctx);
			const meta2 = second!.details.kendexOutputPolicy[0];
			expect(meta2.turnSavedBytes).toBe(meta2.savedBytes);
			expect(meta2.turnSavedBytes).toBeLessThan(meta1.sessionSavedBytes + meta2.savedBytes);
			expect(meta2.sessionSavedBytes).toBe(meta2.savedBytes + (reset === "turn_start" ? meta1.sessionSavedBytes : 0));
		});
	}
});
