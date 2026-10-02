import { describe, expect, jest, test } from "bun:test";

import { flushMicrotasks, installModalLock, installQuestionExtension, mockQuestionRuntime } from "./helpers/runtime.js";

// The custom questionnaire constructs an Input at open; it is never rendered here.
mockQuestionRuntime({ Input: class { setValue() {} } });

const { default: questions } = await import("../questions.js");

const REQUEST_ID = "que_service";
const PAYLOAD = {
	id: REQUEST_ID,
	questions: [{ header: "Path", options: [{ label: "A" }, { label: "B" }], question: "Which path?" }],
};
const DEFAULT_DIALOG_TIMEOUT_MS = 30 * 60_000;

describe("queued question behind a held popup", () => {
	test("registers no promise reaction per poll and leaves no timer once settled", async () => {
		jest.useFakeTimers();
		const extension = installQuestionExtension(questions);
		const lock = installModalLock(1);
		const originalThen = Promise.prototype.then;
		let reactions = 0;
		try {
			const answer = extension.service.ask({ cwd: extension.root, hasUI: true, ui: { notify() {} } }, PAYLOAD, "tool");
			await flushMicrotasks();
			Promise.prototype.then = function (this: Promise<unknown>, ...args: Parameters<Promise<unknown>["then"]>) {
				reactions += 1;
				return originalThen.apply(this, args);
			} as typeof originalThen;
			// Ten seconds of fake time in poll-sized steps, so a waiter that
			// re-arms per poll runs each step.
			for (let step = 0; step < 100; step += 1) {
				jest.advanceTimersByTime(100);
				await flushMicrotasks();
			}
			Promise.prototype.then = originalThen;

			expect(reactions).toBe(0);
			extension.service.reject(REQUEST_ID, "api");
			expect(await answer).toEqual({ cancelled: true, requestId: REQUEST_ID });
			expect(jest.getTimerCount()).toBe(0);
		} finally {
			Promise.prototype.then = originalThen;
			lock.restore();
			extension.restore();
			jest.useRealTimers();
		}
	});
});

interface Observed {
	closed: unknown[];
	dialogs: Array<{ dismissed: boolean; timeout: number | undefined }>;
}

describe("question tool abort", () => {
	test("an aborted tool signal cancels the request and rejects within 100 ms", async () => {
		for (const row of [
			{
				name: "queued behind a held popup",
				lockDepth: 1,
				ctx: (_observed: Observed) => ({ hasUI: true, ui: { notify() {} } }),
				expected: { closed: [], dialogs: [], lockDepth: 1 },
			},
			{
				name: "custom questionnaire open",
				lockDepth: 0,
				ctx: (observed: Observed) => ({
					hasUI: true,
					ui: {
						custom(factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (result: unknown) => void) => unknown) {
							return new Promise((resolve) => {
								const tui = { getShowHardwareCursor: () => false, requestRender() {}, setShowHardwareCursor() {} };
								factory(tui, {}, {}, (result) => {
									observed.closed.push(result);
									resolve(result);
								});
							});
						},
						notify() {},
					},
				}),
				expected: { closed: [{ cancelled: true, requestId: REQUEST_ID }], dialogs: [], lockDepth: 0 },
			},
			{
				name: "native dialog open",
				lockDepth: 0,
				// Pi's RPC dialogs resolve undefined when their signal aborts.
				ctx: (observed: Observed) => {
					const dialog = (_title: string, _detail: unknown, opts?: { signal?: AbortSignal; timeout?: number }) => {
						const record = { dismissed: false, timeout: opts?.timeout };
						observed.dialogs.push(record);
						return new Promise<undefined>((resolve) => {
							opts?.signal?.addEventListener("abort", () => {
								record.dismissed = true;
								resolve(undefined);
							}, { once: true });
						});
					};
					return { hasUI: false, mode: "rpc", ui: { input: dialog, notify() {}, select: dialog } };
				},
				expected: { closed: [], dialogs: [{ dismissed: true, timeout: DEFAULT_DIALOG_TIMEOUT_MS }], lockDepth: 0 },
			},
		]) {
			const extension = installQuestionExtension(questions);
			const lock = installModalLock(row.lockDepth);
			try {
				const observed: Observed = { closed: [], dialogs: [] };
				const events: Array<{ action: string; source?: string }> = [];
				extension.service.subscribe(({ action, source }) => events.push({ action, source }));
				const controller = new AbortController();
				const run = extension.tool.execute("call_abort", PAYLOAD, controller.signal, undefined, { cwd: extension.root, ...row.ctx(observed) });
				await flushMicrotasks();
				controller.abort();
				// The acceptance bound is wall-clock: the call settles within 100 ms of the abort.
				const outcome = await Promise.race([
					run.then(() => "resolved", (error: unknown) => (error instanceof Error ? error.message : String(error))),
					new Promise((resolve) => setTimeout(() => resolve("still pending after 100 ms"), 100)),
				]);
				await flushMicrotasks();

				expect({ name: row.name, outcome }).toEqual({ name: row.name, outcome: "Operation aborted" });
				expect({ name: row.name, ...observed, lockDepth: lock.depth() }).toEqual({ name: row.name, ...row.expected });
				expect({ name: row.name, events, pending: extension.service.listPending() }).toEqual({
					events: [{ action: "opened", source: "tool" }, { action: "rejected", source: "tool" }],
					name: row.name,
					pending: [],
				});
			} finally {
				lock.restore();
				extension.restore();
			}
		}
	});
});
