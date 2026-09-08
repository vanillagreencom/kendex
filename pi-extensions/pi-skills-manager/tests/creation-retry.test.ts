import assert from "node:assert/strict";
import { test } from "bun:test";
import { retrySkillGenerationCompat } from "../extensions/skills-manager/pi-ai-compat.ts";

for (const row of [
	{ name: "Pi retry defaults", native: true, notify: false },
	{ name: "older Pi direct generation", native: false, notify: false },
	{ name: "retry callback forwarding", native: true, notify: true },
]) {
	test(row.name, async () => {
		const response = { stopReason: "stop", content: [] };
		const signal = row.notify ? new AbortController().signal : undefined;
		const notices: unknown[] = [];
		let calls = 0;
		let receivedPolicy: unknown;
		let receivedSignal: AbortSignal | undefined;
		const retryAssistantCall = async (
			produce: () => Promise<unknown>, policy: unknown, forwardedSignal: AbortSignal | undefined,
			callbacks: { onRetryScheduled?: (...args: [number, number, number, string]) => void | Promise<void> },
		) => {
			receivedPolicy = policy;
			receivedSignal = forwardedSignal;
			if (row.notify) await callbacks.onRetryScheduled?.(1, 3, 2000, "temporary");
			return produce();
		};
		const result = await retrySkillGenerationCompat(
			async () => { calls += 1; return response; }, signal,
			(...args) => { notices.push(args); }, { root: row.native ? { retryAssistantCall } : {} },
		);
		assert.equal(result, response);
		assert.equal(calls, 1);
		assert.deepEqual(receivedPolicy, row.native ? { enabled: true, maxRetries: 3, baseDelayMs: 2000 } : undefined);
		assert.equal(receivedSignal, row.native ? signal : undefined);
		assert.deepEqual(notices, row.notify ? [[1, 3, 2000, "temporary"]] : []);
	});
}
