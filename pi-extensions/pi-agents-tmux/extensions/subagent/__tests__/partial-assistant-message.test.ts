import { describe, expect, test } from "bun:test";
import {
	applyPartialAssistantMessage,
	createPartialAssistantMessageState,
	partialAssistantMessage,
	resetPartialAssistantMessage,
} from "../transcripts.js";

// Pi 0.84.0 made the JSON/RPC `message_update` wire event delta-only (`toJsonEvent()` strips
// the cumulative `message` and `assistantMessageEvent.partial`), so the failure-path flush
// has to rebuild the partial assistant message from deltas.
function deltaUpdate(type: string, contentIndex: number, fields: Record<string, unknown>): Record<string, unknown> {
	return { type: "message_update", assistantMessageEvent: { type, contentIndex, ...fields } };
}

describe("partial assistant message reconstruction", () => {
	test("accumulates text deltas into the message so far", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_start", 0, {}));
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "Found " }));
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "the bug" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "Found the bug" }] });
	});

	test("keeps thinking and text blocks separate and ordered by contentIndex", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 1, { delta: "answer" }));
		applyPartialAssistantMessage(state, deltaUpdate("thinking_delta", 0, { delta: "reasoning" }));

		expect(partialAssistantMessage(state)).toEqual({
			role: "assistant",
			content: [{ type: "thinking", text: "reasoning" }, { type: "text", text: "answer" }],
		});
	});

	test("a *_end event replaces accumulated deltas with its authoritative content", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "part" }));
		applyPartialAssistantMessage(state, deltaUpdate("text_end", 0, { content: "part and whole" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "part and whole" }] });
	});

	test("defaults a missing contentIndex to a single block rather than dropping the delta", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "no index" } });

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "no index" }] });
	});

	test("yields nothing when the event already carries its own cumulative snapshot", () => {
		const withMessage = createPartialAssistantMessageState();
		applyPartialAssistantMessage(withMessage, { type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "snapshot" }] } });
		expect(partialAssistantMessage(withMessage)).toBeUndefined();

		const withPartial = createPartialAssistantMessageState();
		applyPartialAssistantMessage(withPartial, { type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "x", partial: { role: "assistant", content: [] } } });
		expect(partialAssistantMessage(withPartial)).toBeUndefined();
	});

	test("ignores tool-call deltas, malformed payloads, and empty deltas", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("toolcall_delta", 0, { delta: "{\"path\":" }));
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "" }));
		applyPartialAssistantMessage(state, { type: "message_update" });
		applyPartialAssistantMessage(state, undefined);

		expect(partialAssistantMessage(state)).toBeUndefined();
	});

	test("reset clears both accumulated deltas and the snapshot flag", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "stale" }));
		resetPartialAssistantMessage(state);
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "fresh" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "fresh" }] });
	});
});
