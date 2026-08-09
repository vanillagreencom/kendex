import { describe, expect, test } from "bun:test";
import {
	applyPartialAssistantMessage,
	createPartialAssistantMessageState,
	partialAssistantMessage,
	partialAssistantMessageDiagnostic,
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

	// Pi's own assistant content blocks are `{ type: "text", text }` and
	// `{ type: "thinking", thinking }`; a rebuilt block has to match or readers see undefined.
	test("keeps thinking and text blocks separate, ordered by contentIndex, in Pi's block shapes", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 1, { delta: "answer" }));
		applyPartialAssistantMessage(state, deltaUpdate("thinking_delta", 0, { delta: "reasoning" }));

		expect(partialAssistantMessage(state)).toEqual({
			role: "assistant",
			content: [{ type: "thinking", thinking: "reasoning" }, { type: "text", text: "answer" }],
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

	// Positive control: accumulate real content FIRST, so the assertion can only pass because
	// the snapshot flag suppressed reconstruction — not because nothing accumulated at all.
	test("suppresses reconstruction when the event carries its own cumulative snapshot", () => {
		const withMessage = createPartialAssistantMessageState();
		applyPartialAssistantMessage(withMessage, deltaUpdate("text_delta", 0, { delta: "accumulated" }));
		expect(partialAssistantMessage(withMessage)).toEqual({ role: "assistant", content: [{ type: "text", text: "accumulated" }] });
		applyPartialAssistantMessage(withMessage, { type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "snapshot" }] } });
		expect(partialAssistantMessage(withMessage)).toBeUndefined();

		const withPartial = createPartialAssistantMessageState();
		applyPartialAssistantMessage(withPartial, deltaUpdate("text_delta", 0, { delta: "accumulated" }));
		applyPartialAssistantMessage(withPartial, { type: "message_update", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "x", partial: { role: "assistant", content: [] } } });
		expect(partialAssistantMessage(withPartial)).toBeUndefined();
	});

	test("a later delta-only event clears the snapshot flag set by an earlier event", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, { type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "snapshot" }] } });
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "after" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "after" }] });
	});

	test("ignores tool-call deltas, malformed payloads, and empty deltas without losing real content", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "real" }));
		applyPartialAssistantMessage(state, deltaUpdate("toolcall_delta", 0, { delta: "{\"path\":" }));
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "" }));
		applyPartialAssistantMessage(state, { type: "message_update" });
		applyPartialAssistantMessage(state, undefined);

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "real" }] });
		// Known-ignored shapes must not be reported as an unrecognized wire format.
		expect(partialAssistantMessageDiagnostic(state)).toBeUndefined();
	});

	test("reports a diagnostic when only unrecognized event types were seen", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("prose_delta", 0, { delta: "future Pi shape" }));
		applyPartialAssistantMessage(state, { type: "message_update", assistantMessageEvent: { type: "audio_delta", contentIndex: 1 } });

		expect(partialAssistantMessage(state)).toBeUndefined();
		const diagnostic = partialAssistantMessageDiagnostic(state);
		expect(diagnostic).toContain("audio_delta");
		expect(diagnostic).toContain("prose_delta");
		expect(diagnostic).toContain("2 message_update event(s)");
	});

	test("no diagnostic when nothing was applied or content rebuilt successfully", () => {
		expect(partialAssistantMessageDiagnostic(createPartialAssistantMessageState())).toBeUndefined();

		const rebuilt = createPartialAssistantMessageState();
		applyPartialAssistantMessage(rebuilt, deltaUpdate("text_delta", 0, { delta: "fine" }));
		expect(partialAssistantMessageDiagnostic(rebuilt)).toBeUndefined();
	});

	test("reset clears accumulated deltas, the snapshot flag, and diagnostic tracking", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "stale" }));
		applyPartialAssistantMessage(state, deltaUpdate("prose_delta", 1, { delta: "unknown" }));
		resetPartialAssistantMessage(state);
		expect(partialAssistantMessageDiagnostic(state)).toBeUndefined();

		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "fresh" }));
		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "fresh" }] });
	});
});
