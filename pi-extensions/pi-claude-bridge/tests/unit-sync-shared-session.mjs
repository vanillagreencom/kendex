/**
 * Tests for syncSharedSession's REUSE path (and the disk-free clean start).
 *
 * The planner unit tests alone cannot protect the caller contract: a mutation
 * that returns the last message instead of the whole pending batch passes them
 * while still dropping every queued follow-up but one (vstack#963). These tests
 * pin syncSharedSession itself: same sessionId kept (no rebuild), promptStart
 * covering the WHOLE trailing user run by content, and the stored cursor.
 *
 * REUSE and clean start touch no disk or API, so no fixtures are needed; the
 * destructive REBUILD path is covered by the int-session-* integration tests.
 */
import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { syncSharedSession } from "../src/session-persistence.js";
import { __testGetBridgeIntegrityState, setSharedSession } from "../src/bridge-state.js";

const user = (text) => ({ role: "user", content: text });
const assistant = () => ({ role: "assistant", content: [] });
const CWD = "/repo";

const promptContents = (messages, promptStart) =>
	messages.slice(promptStart).map((message) => message.content);

afterEach(() => setSharedSession(null));

describe("syncSharedSession REUSE path", () => {
	it("keeps the session and prompts BOTH queued follow-ups, by content", () => {
		setSharedSession({ sessionId: "sess-reuse", cursor: 1, cwd: CWD });
		const messages = [user("u1"), assistant(), user("u2"), user("u3")];

		const result = syncSharedSession(messages, CWD);

		assert.equal(result.sessionId, "sess-reuse");
		assert.equal(result.promptStart, 2);
		// Content assertion, not length: promptStart = messages.length - 1 (the
		// old slice(-1) behavior) would still yield ONE user message here.
		assert.deepEqual(promptContents(messages, result.promptStart), ["u2", "u3"]);
		assert.deepEqual(__testGetBridgeIntegrityState().sharedSession, {
			sessionId: "sess-reuse",
			cursor: 2,
			cwd: CWD,
		});
	});

	it("keeps the single-user reuse case: one new user after the trailing assistant", () => {
		setSharedSession({ sessionId: "sess-single", cursor: 1, cwd: CWD });
		const messages = [user("u1"), assistant(), user("u2")];

		const result = syncSharedSession(messages, CWD);

		assert.equal(result.sessionId, "sess-single");
		assert.equal(result.promptStart, 2);
		assert.deepEqual(promptContents(messages, result.promptStart), ["u2"]);
		assert.equal(__testGetBridgeIntegrityState().sharedSession.cursor, 2);
	});

	it("keeps the trailing-assistant reuse case: cursor already past the assistant", () => {
		setSharedSession({ sessionId: "sess-past", cursor: 2, cwd: CWD });
		const messages = [user("u1"), assistant(), user("u2"), user("u3")];

		const result = syncSharedSession(messages, CWD);

		assert.equal(result.sessionId, "sess-past");
		assert.equal(result.promptStart, 2);
		assert.deepEqual(promptContents(messages, result.promptStart), ["u2", "u3"]);
		assert.equal(__testGetBridgeIntegrityState().sharedSession.cursor, 2);
	});
});

describe("syncSharedSession clean start", () => {
	it("returns no resume id and prompts the sole user message", () => {
		const messages = [user("hello")];

		const result = syncSharedSession(messages, CWD);

		assert.equal(result.sessionId, null);
		assert.equal(result.promptStart, 0);
		assert.deepEqual(promptContents(messages, result.promptStart), ["hello"]);
	});
});
