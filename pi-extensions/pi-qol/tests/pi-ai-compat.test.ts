import { expect, test } from "bun:test";
import { complete, retryAssistantCallCompat } from "../extensions/qol/pi-ai-compat.ts";

const completeRows = [
	{
		name: "complete falls back to the compatibility entrypoint",
		model: {}, context: {}, options: { signal: "sentinel" },
		deps: {
			root: {},
			loadCompat: async () => ({ complete: async (_model: unknown, _context: unknown, options: unknown) => ({ options }) }),
		},
		expected: { options: { signal: "sentinel" } },
	},
	{
		name: "complete prefers the root export",
		model: "model", context: "context", options: "options",
		deps: {
			root: { complete: async (...args: unknown[]) => args },
			loadCompat: async () => { throw new Error("compat should not load"); },
		},
		expected: ["model", "context", "options"],
	},
];

if (completeRows.length === 0) throw new Error("Complete dispatch table is empty");

for (const row of completeRows) {
	test(row.name, async () => {
		expect.hasAssertions();
		expect(await complete(row.model, row.context, row.options, row.deps)).toEqual(row.expected);
	});
}

function assistant(stopReason: "stop" | "error" | "aborted", errorMessage?: string) {
	return {
		api: "test", provider: "test", model: "test", role: "assistant", content: [],
		stopReason, errorMessage,
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		timestamp: 0,
	};
}

type Produce = () => Promise<ReturnType<typeof assistant>>;
type RetryCallbacks = NonNullable<Parameters<typeof retryAssistantCallCompat>[2]>;

const retryRows = [
	{
		name: "retry helper receives the standard policy",
		expected: { stopReason: "stop", calls: 1, policy: { enabled: true, maxRetries: 3, baseDelayMs: 2000 } },
		run: async () => {
			let policy: unknown;
			let calls = 0;
			const result = await retryAssistantCallCompat(
				async () => { calls += 1; return assistant("stop"); }, undefined, undefined,
				{ root: { retryAssistantCall: async (produce: Produce, nextPolicy: unknown) => { policy = nextPolicy; return produce(); } } },
			);
			return { stopReason: result.stopReason, calls, policy };
		},
	},
	{
		name: "absent retry helper calls the producer once",
		expected: { stopReason: "stop", calls: 1 },
		run: async () => {
			let calls = 0;
			const result = await retryAssistantCallCompat(
				async () => { calls += 1; return assistant("stop"); }, undefined, undefined, { root: {} },
			);
			return { stopReason: result.stopReason, calls };
		},
	},
	{
		name: "retry helper receives signal and callbacks",
		expected: { sameSignal: true, scheduled: ["temporary"] },
		run: async () => {
			const controller = new AbortController();
			const scheduled: string[] = [];
			let sameSignal = false;
			await retryAssistantCallCompat(
				async () => assistant("error", "temporary"), controller.signal,
				{ onRetryScheduled: (_attempt, _max, _delay, message) => { scheduled.push(message); } },
				{ root: { retryAssistantCall: async (_produce: Produce, _policy: unknown, signal: AbortSignal, callbacks: RetryCallbacks) => {
					sameSignal = signal === controller.signal;
					await callbacks?.onRetryScheduled?.(1, 3, 2000, "temporary");
					return assistant("error", "temporary");
				} } },
			);
			return { sameSignal, scheduled };
		},
	},
	{
		name: "retry helper success is returned",
		expected: { stopReason: "stop", calls: 2 },
		run: async () => {
			let calls = 0;
			const result = await retryAssistantCallCompat(
				async () => { calls += 1; return calls === 1 ? assistant("error", "temporary") : assistant("stop"); }, undefined, undefined,
				{ root: { retryAssistantCall: async (produce: Produce) => {
					const first = await produce();
					return first.stopReason === "error" ? produce() : first;
				} } },
			);
			return { stopReason: result.stopReason, calls };
		},
	},
	{
		name: "retry helper aborted result is preserved",
		expected: { stopReason: "aborted", errorMessage: undefined },
		run: async () => {
			const result = await retryAssistantCallCompat(
				async () => assistant("error", "temporary"), new AbortController().signal, undefined,
				{ root: { retryAssistantCall: async () => assistant("aborted") } },
			);
			return { stopReason: result.stopReason, errorMessage: result.errorMessage };
		},
	},
];

if (retryRows.length === 0) throw new Error("Retry dispatch table is empty");

for (const row of retryRows) {
	test(row.name, async () => {
		expect.hasAssertions();
		expect(await row.run()).toEqual(row.expected);
	});
}
