import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { RetryEventBuffer } from "../src/account-router.ts";

function fakeStream() {
	const events = [];
	let ended = false;
	return {
		events,
		get ended() { return ended; },
		push(event) { events.push(event); },
		end() { ended = true; },
	};
}

describe("RetryEventBuffer", () => {
	it("discards protocol setup events when an account fails before output", () => {
		const target = fakeStream();
		const buffer = new RetryEventBuffer(target);
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "text_start", contentIndex: 0, partial: {} });
		buffer.discard();
		buffer.end();
		assert.deepEqual(target.events, []);
		assert.equal(target.ended, false);
	});

	it("flushes setup exactly once at the first visible delta", () => {
		const target = fakeStream();
		let commits = 0;
		const buffer = new RetryEventBuffer(target, () => { commits += 1; });
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "text_start", contentIndex: 0, partial: {} });
		buffer.push({ type: "text_delta", contentIndex: 0, delta: "hello", partial: {} });
		buffer.push({ type: "text_end", contentIndex: 0, content: "hello", partial: {} });
		buffer.end();
		assert.deepEqual(target.events.map((event) => event.type), [
			"start", "text_start", "text_delta", "text_end",
		]);
		assert.equal(commits, 1);
		assert.equal(target.ended, true);
	});

	it("treats a complete tool call as committed output", () => {
		const target = fakeStream();
		const buffer = new RetryEventBuffer(target);
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "toolcall_end", contentIndex: 0, toolCall: {}, partial: {} });
		assert.equal(buffer.hasCommittedOutput, true);
		assert.deepEqual(target.events.map((event) => event.type), ["start", "toolcall_end"]);
	});
});

