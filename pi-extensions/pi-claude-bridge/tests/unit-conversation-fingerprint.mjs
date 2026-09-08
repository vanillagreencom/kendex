import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { conversationFingerprint } from "../src/session-persistence.js";

const user = (text) => ({ role: "user", content: text });
const assistant = () => ({ role: "assistant", content: [] });
const assistantText = (text) => ({ role: "assistant", content: [{ type: "text", text }] });

describe("conversationFingerprint", () => {
	it("hashes the FIRST user message's text, string or block form alike", () => {
		const fromString = conversationFingerprint([user("hello")]);
		assert.match(fromString, /^u:[0-9a-f]{12}$/);
		assert.equal(conversationFingerprint([{ role: "user", content: [{ type: "text", text: "hello" }] }]), fromString);
		// An assistant message with no text (tool-only / empty content) adds no
		// second component — same anchor as the bare opener.
		assert.equal(conversationFingerprint([user("hello"), assistant(), user("later turn")]), fromString);
		assert.notEqual(conversationFingerprint([user("other opener")]), fromString);
	});

	it("adds the FIRST assistant message's text as a second component once one exists", () => {
		const grown = conversationFingerprint([user("hello"), assistantText("first answer"), user("later turn")]);
		assert.match(grown, /^u:[0-9a-f]{12}\|a:[0-9a-f]{12}$/);
		// The user component is shared with the turn-1 form; the assistant text
		// is what discriminates two same-opener conversations.
		assert.equal(grown.startsWith(conversationFingerprint([user("hello")])), true);
		assert.equal(conversationFingerprint([user("hello"), assistantText("first answer")]), grown);
		assert.notEqual(conversationFingerprint([user("hello"), assistantText("other answer")]), grown);
	});

	it("returns undefined when conversation identity is unknown", () => {
		const rows = [
			["empty history", []],
			["assistant only", [assistant()]],
			["image opener", [{ role: "user", content: [{ type: "image", data: "zzz", mimeType: "image/png" }] }]],
			["blank opener", [{ role: "user", content: "   " }]],
		];
		for (const [name, messages] of rows) assert.equal(conversationFingerprint(messages), undefined, name);
	});
});

