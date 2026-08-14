import { AsyncLocalStorage } from "node:async_hooks";

/**
 * Selects the Pi agent session whose provider request is currently executing.
 *
 * Pi forwards a stable `SimpleStreamOptions.sessionId` on every model request,
 * including tool-result continuations.  The bridge may serve the parent agent
 * and several in-process subagents concurrently, so process-global query state
 * cannot identify the request that a callback belongs to.  AsyncLocalStorage
 * keeps that identity attached to every promise, SDK iterator, and timer born
 * during the provider call without threading the id through every helper.
 */
const REQUEST_LANE_SYMBOL = Symbol.for("vstack.pi.claude-bridge.request-lane.v1");

function requestLaneStorage(): AsyncLocalStorage<string> {
	const host = globalThis as Record<symbol, unknown>;
	let storage = host[REQUEST_LANE_SYMBOL] as AsyncLocalStorage<string> | undefined;
	if (!storage) {
		storage = new AsyncLocalStorage<string>();
		host[REQUEST_LANE_SYMBOL] = storage;
	}
	return storage;
}

export function runInRequestLane<T>(sessionId: string | undefined, callback: () => T): T {
	return sessionId !== undefined ? requestLaneStorage().run(sessionId, callback) : callback();
}

export function currentRequestLaneId(): string | undefined {
	return requestLaneStorage().getStore();
}
