import { afterEach, beforeEach, spyOn } from "bun:test";
import * as dispatch from "../extensions/dispatch.ts";

/** Observe real dispatch completion without adding a runtime probe or waiting
 * for an assumed amount of scheduler time. The handler's delivery callback is
 * attached before settle() attaches its Promise.all continuation. */
export function useSettledSessions(): () => Promise<void> {
	const original = dispatch.runListener;
	let pending: Promise<dispatch.ListenerRun>[] = [];
	let spy: ReturnType<typeof spyOn>;
	beforeEach(() => {
		pending = [];
		spy = spyOn(dispatch, "runListener").mockImplementation((...args) => {
			const run = original(...args);
			pending.push(run);
			return run;
		});
	});
	afterEach(async () => {
		try { await Promise.all(pending); } finally { spy.mockRestore(); }
	});
	return async () => { await Promise.all(pending); };
}
