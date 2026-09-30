import { afterEach, beforeEach, spyOn } from "bun:test";
import * as dispatch from "../extensions/dispatch.ts";

/** Observe real dispatch completion without adding a runtime probe or waiting
 * for an assumed amount of scheduler time. A `session_start` report runs in
 * two awaited steps: the hooks, then the bound on what they said to the agent.
 * The handler attaches its continuation to each step before settle() attaches
 * its own, so settle() resolves once the handler has delivered. */
export function useSettledSessions(): () => Promise<void> {
	const originalRun = dispatch.runListener;
	const originalBound = dispatch.boundForAgent;
	let runs: Promise<dispatch.ListenerRun>[] = [];
	let bounds: Promise<string>[] = [];
	let spies: ReturnType<typeof spyOn>[] = [];
	beforeEach(() => {
		runs = [];
		bounds = [];
		spies = [
			spyOn(dispatch, "runListener").mockImplementation((...args) => {
				const run = originalRun(...args);
				runs.push(run);
				return run;
			}),
			spyOn(dispatch, "boundForAgent").mockImplementation((...args) => {
				const bound = originalBound(...args);
				bounds.push(bound);
				return bound;
			}),
		];
	});
	const settle = async () => {
		await Promise.allSettled(runs);
		await Promise.allSettled(bounds);
	};
	afterEach(async () => {
		try { await settle(); } finally { for (const spy of spies) spy.mockRestore(); }
	});
	return settle;
}
