import { describe, expect, test, beforeEach, spyOn } from "bun:test";
import outputPolicy, { __resetSessionCountersForTests } from "../extensions/output-policy.ts";
import { withConfigAsync, fakeCtx, createFakePi, writeConfig } from "./fixtures.ts";

beforeEach(() => { __resetSessionCountersForTests(); });

describe("model output guard handler", () => {
	function guardCtx(cwd: string, notify: (message: string) => void = () => {}) {
		let aborts = 0;
		return {
			ctx: {
				...fakeCtx(cwd),
				abort: () => { aborts += 1; },
				ui: { notify },
			},
			aborts: () => aborts,
		};
	}

	test("aborts once and warns when streamed assistant text degenerates", async () => {
		await withConfigAsync({
			"modelOutputGuard.maxConsecutiveRepeats": 3,
			"modelOutputGuard.minRepeatedChars": 90,
		}, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const notices: string[] = [];
			const guard = guardCtx(cwd, (message) => notices.push(message));
			const delta = Array.from({ length: 8 }, () => `${"repeat me ".repeat(5)}\n`).join("");
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
			expect(notices).toHaveLength(1);
			expect(notices[0].split("\n")[0]).toBe("[output-policy:repetition=3]");
		});
	});

	test("counts thinking and tool-call argument deltas toward the hard cap", async () => {
		for (const type of ["thinking_delta", "toolcall_delta"]) {
			await withConfigAsync({ "modelOutputGuard.maxChars": 100 }, async (cwd) => {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const guard = guardCtx(cwd);
				await fake.fire("message_update", { assistantMessageEvent: { type, delta: "x".repeat(100) } }, guard.ctx);
				expect(guard.aborts()).toBe(1);
			});
		}
	});

	test("notification failures cannot prevent abort", async () => {
		await withConfigAsync({ "modelOutputGuard.maxChars": 100 }, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const error = new Error("fixture\nnotification");
			const warning = spyOn(console, "warn").mockImplementation(() => {});
			try {
				const guard = guardCtx(cwd, () => { throw error; });
				await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(101) } }, guard.ctx);
				expect(guard.aborts()).toBe(1);
				expect(warning).toHaveBeenCalledTimes(1);
				expect(warning.mock.calls[0][0].split("\n")[0]).toBe(`[output-policy:warning-error=${JSON.stringify(`${error.name}: ${error.message}`)}]`);
			} finally { warning.mockRestore(); }
		});
	});

	test("all lifecycle resets clear partial streaks and re-arm after abort", async () => {
		await withConfigAsync({
			"modelOutputGuard.maxConsecutiveRepeats": 3,
			"modelOutputGuard.minRepeatedChars": 90,
		}, async (cwd) => {
			const cases = [
				["message_start", { message: { role: "assistant" } }],
				["turn_start", { turnIndex: 1 }],
				["session_start", { reason: "new" }],
				["session_shutdown", { reason: "quit" }],
			] as const;
			for (const [resetEvent, payload] of cases) {
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const guard = guardCtx(cwd);
				const block = `${"repeat me ".repeat(5)}\n`;
				await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block.repeat(2) } }, guard.ctx);
				await fake.fire(resetEvent, payload, guard.ctx);
				await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block.repeat(2) } }, guard.ctx);
				expect(guard.aborts()).toBe(0);
			}

			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			const spam = `${"repeat me ".repeat(5)}\n`.repeat(3);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: spam } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
			await fake.fire("message_start", { message: { role: "assistant" } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: spam } }, guard.ctx);
			expect(guard.aborts()).toBe(2);
		});
	});

	test("snapshots settings once per assistant message and refreshes on the next message", async () => {
		await withConfigAsync({ "modelOutputGuard.maxChars": 100 }, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			await fake.fire("message_start", { message: { role: "assistant" } }, guard.ctx);
			writeConfig(cwd, { "modelOutputGuard.maxChars": 200 });
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(60) } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(40) } }, guard.ctx);
			expect(guard.aborts()).toBe(1);

			await fake.fire("message_start", { message: { role: "assistant" } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(100) } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(100) } }, guard.ctx);
			expect(guard.aborts()).toBe(2);
		});
	});

	test("message_start prevents the hard cap from carrying across assistant messages", async () => {
		await withConfigAsync({ "modelOutputGuard.maxChars": 100 }, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			await fake.fire("message_start", { message: { role: "assistant" } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(60) } }, guard.ctx);
			expect(guard.aborts()).toBe(0);
			await fake.fire("message_start", { message: { role: "assistant" } }, guard.ctx);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(60) } }, guard.ctx);
			expect(guard.aborts()).toBe(0);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(40) } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
		});
	});

	test("lazy snapshot supports isolated direct event injection without boundary inference", async () => {
		await withConfigAsync({ "modelOutputGuard.maxChars": 100 }, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(60) } }, guard.ctx);
			writeConfig(cwd, { "modelOutputGuard.maxChars": 200 });
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(40) } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
		});
	});

	test("separate session runtime closures isolate stream state and lifecycle resets", async () => {
		await withConfigAsync({
			"modelOutputGuard.maxConsecutiveRepeats": 3,
			"modelOutputGuard.minRepeatedChars": 90,
		}, async (cwd) => {
			const firstPi = createFakePi();
			const secondPi = createFakePi();
			outputPolicy(firstPi.pi);
			outputPolicy(secondPi.pi);
			const first = guardCtx(cwd);
			const second = guardCtx(cwd);
			const block = `${"repeat me ".repeat(5)}\n`;
			await firstPi.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block.repeat(2) } }, first.ctx);
			await secondPi.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block } }, second.ctx);
			await secondPi.fire("session_start", { reason: "resume" }, second.ctx);
			expect(first.aborts()).toBe(0);
			expect(second.aborts()).toBe(0);
			await firstPi.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block } }, first.ctx);
			expect(first.aborts()).toBe(1);
			expect(second.aborts()).toBe(0);
		});
	});

	test("repetition can be disabled while the hard cap remains active", async () => {
		await withConfigAsync({
			"modelOutputGuard.maxChars": 500,
			"modelOutputGuard.repetition.enabled": false,
		}, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			const block = `${"repeat me ".repeat(5)}\n`;
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: block.repeat(8) } }, guard.ctx);
			expect(guard.aborts()).toBe(0);
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta: "x".repeat(500) } }, guard.ctx);
			expect(guard.aborts()).toBe(1);
		});
	});

	test("can be disabled independently from tool output policy", async () => {
		await withConfigAsync({ "modelOutputGuard.enabled": false }, async (cwd) => {
			const fake = createFakePi();
			outputPolicy(fake.pi);
			const guard = guardCtx(cwd);
			const delta = Array.from({ length: 100 }, () => `${"repeat me ".repeat(5)}\n`).join("");
			await fake.fire("message_update", { assistantMessageEvent: { type: "text_delta", delta } }, guard.ctx);
			expect(guard.aborts()).toBe(0);
		});
	});
});

