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

/** A Pi dialog that records the timeout it got and, as Pi's do, resolves undefined once its signal aborts. */
function recordingDialog(onOpen: (opts: { signal?: AbortSignal; timeout?: number } | undefined) => void) {
	return (_title: string, _detail: unknown, opts?: { signal?: AbortSignal; timeout?: number }) => {
		onOpen(opts);
		return new Promise<undefined>((resolve) => {
			opts?.signal?.addEventListener("abort", () => resolve(undefined), { once: true });
		});
	};
}

describe("queued question behind a held popup", () => {
	test("registers no promise reaction per poll, leaves no timer and opens no popup once settled", async () => {
		jest.useFakeTimers();
		const extension = installQuestionExtension(questions);
		const lock = installModalLock(1);
		const originalThen = Promise.prototype.then;
		let reactions = 0;
		let customOpened = 0;
		const ui = {
			custom() {
				customOpened += 1;
				return new Promise(() => {});
			},
			notify() {},
		};
		try {
			const answer = extension.service.ask({ cwd: extension.root, hasUI: true, ui }, PAYLOAD, "tool");
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
			await flushMicrotasks();
			expect({ customOpened, lockDepth: lock.depth(), timers: jest.getTimerCount() }).toEqual({ customOpened: 0, lockDepth: 1, timers: 0 });
		} finally {
			Promise.prototype.then = originalThen;
			lock.restore();
			extension.restore();
			jest.useRealTimers();
		}
	});
});

interface Observed {
	customOpened: number;
	closed: unknown[];
	/** Whether each dialog's abort signal fired; an RPC client's own dialog is out of reach here. */
	dialogs: Array<{ signalAborted: boolean }>;
}

describe("question tool abort", () => {
	test("an aborted tool signal cancels the request and rejects within 100 ms", async () => {
		for (const row of [
			{
				name: "queued behind a held popup",
				lockDepth: 1,
				ctx: (observed: Observed) => ({
					hasUI: true,
					ui: {
						custom() {
							observed.customOpened += 1;
							return new Promise(() => {});
						},
						notify() {},
					},
				}),
				expected: { closed: [], customOpened: 0, dialogs: [], lockDepth: 1 },
			},
			{
				name: "custom questionnaire open",
				lockDepth: 0,
				ctx: (observed: Observed) => ({
					hasUI: true,
					ui: {
						custom(factory: (tui: unknown, theme: unknown, keybindings: unknown, done: (result: unknown) => void) => unknown) {
							observed.customOpened += 1;
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
				expected: { closed: [{ cancelled: true, requestId: REQUEST_ID }], customOpened: 1, dialogs: [], lockDepth: 0 },
			},
			{
				name: "native dialog open",
				lockDepth: 0,
				ctx: (observed: Observed) => {
					const dialog = recordingDialog((opts) => {
						const record = { signalAborted: false };
						observed.dialogs.push(record);
						opts?.signal?.addEventListener("abort", () => { record.signalAborted = true; }, { once: true });
					});
					return { hasUI: false, mode: "rpc", ui: { input: dialog, notify() {}, select: dialog } };
				},
				expected: { closed: [], customOpened: 0, dialogs: [{ signalAborted: true }], lockDepth: 0 },
			},
		]) {
			const extension = installQuestionExtension(questions);
			const lock = installModalLock(row.lockDepth);
			try {
				const observed: Observed = { closed: [], customOpened: 0, dialogs: [] };
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

describe("native dialog timeout", () => {
	test("follows dialogTimeoutMinutes, capped at the longest delay a timer honours", async () => {
		for (const row of [
			{ name: "unset", config: {}, timeouts: [30 * 60_000] },
			{ name: "five minutes", config: { dialogTimeoutMinutes: 5 }, timeouts: [300_000] },
			{ name: "zero", config: { dialogTimeoutMinutes: 0 }, timeouts: [undefined] },
			{ name: "negative", config: { dialogTimeoutMinutes: -1 }, timeouts: [undefined] },
			{ name: "last minute under the bound", config: { dialogTimeoutMinutes: 35_791 }, timeouts: [2_147_460_000] },
			{ name: "past the bound", config: { dialogTimeoutMinutes: 35_792 }, timeouts: [2_147_483_647] },
		]) {
			const extension = installQuestionExtension(questions, row.config);
			try {
				const timeouts: Array<number | undefined> = [];
				const dialog = recordingDialog((opts) => timeouts.push(opts?.timeout));
				const answer = extension.service.ask({ cwd: extension.root, hasUI: false, mode: "rpc", ui: { input: dialog, notify() {}, select: dialog } }, PAYLOAD, "tool");
				await flushMicrotasks();
				extension.service.reject(REQUEST_ID, "api");
				await answer;
				expect({ name: row.name, timeouts }).toStrictEqual({ name: row.name, timeouts: row.timeouts });
			} finally {
				extension.restore();
			}
		}
	});
});
