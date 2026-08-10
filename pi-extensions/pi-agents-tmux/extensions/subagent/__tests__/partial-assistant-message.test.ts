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

	// A snapshot supersedes earlier deltas. Reseeding from it (rather than only flagging)
	// keeps a mixed stream from splicing stale pre-snapshot text onto post-snapshot deltas.
	test("a snapshot reseeds the accumulator, and later deltas append to it", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "stale pre-snapshot " }));
		applyPartialAssistantMessage(state, { type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "snapshot so far" }] } });
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: " and more" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "snapshot so far and more" }] });
	});

	test("a snapshot's thinking blocks reseed in Pi's block shape", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, { type: "message_update", message: { role: "assistant", content: [{ type: "thinking", thinking: "reasoned" }, { type: "text", text: "said" }] } });
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 1, { delta: " more" }));

		expect(partialAssistantMessage(state)).toEqual({
			role: "assistant",
			content: [{ type: "thinking", thinking: "reasoned" }, { type: "text", text: "said more" }],
		});
	});

	test("ignores known-empty shapes without losing real content or raising a false alarm", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "real" }));
		applyPartialAssistantMessage(state, deltaUpdate("toolcall_delta", 0, { delta: "{\"path\":" }));
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "" }));
		applyPartialAssistantMessage(state, undefined);

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "real" }] });
		// Known-ignored shapes must not be reported as an unrecognized wire format.
		expect(partialAssistantMessageDiagnostic(state)).toBeUndefined();
	});

	// A mixed stream is the dangerous case: some content rebuilds, so the record looks
	// plausible while the shapes we did not understand vanish without a trace.
	test("reports a diagnostic when content rebuilt but other shapes were dropped", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "understood part" }));
		applyPartialAssistantMessage(state, deltaUpdate("prose_delta", 1, { delta: "future Pi shape" }));

		expect(partialAssistantMessage(state)).toEqual({ role: "assistant", content: [{ type: "text", text: "understood part" }] });
		const diagnostic = partialAssistantMessageDiagnostic(state);
		expect(diagnostic).toContain("may be incomplete");
		expect(diagnostic).toContain("prose_delta");
	});

	test("a message_update carrying no assistantMessageEvent is reported, not silently dropped", () => {
		const state = createPartialAssistantMessageState();
		applyPartialAssistantMessage(state, deltaUpdate("text_delta", 0, { delta: "real" }));
		applyPartialAssistantMessage(state, { type: "message_update" });

		expect(partialAssistantMessageDiagnostic(state)).toContain("<no assistantMessageEvent>");
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
