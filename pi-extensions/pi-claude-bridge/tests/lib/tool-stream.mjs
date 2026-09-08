import { ctx } from "../../src/query-state.ts";

export const model = {
	api: "claude-bridge",
	provider: "pi-claude",
	id: "claude-haiku-4-5",
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};

export function installFakeStream() {
	const events = [];
	ctx().currentPiStream = {
		push(event) { events.push(event); },
		end(result) { events.push({ type: "stream_end", result }); },
	};
	return events;
}

export const streamEvent = (event) => ({ type: "stream_event", event });
