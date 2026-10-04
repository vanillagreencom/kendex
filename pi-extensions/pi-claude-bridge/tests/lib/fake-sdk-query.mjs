/** A child transport that can stay silent even after interrupt and close.
 *  Claude SDK teardown does not guarantee another iterator message. */
export function heldSdkQuery(messages = []) {
	const entered = Promise.withResolvers();
	const released = Promise.withResolvers();
	const record = { closed: false, interruptions: 0, entered: entered.promise };
	const query = {
		async *[Symbol.asyncIterator]() {
			for (const message of messages) yield message;
			entered.resolve();
			const lateMessages = await released.promise;
			for (const message of lateMessages) yield message;
		},
		close() { record.closed = true; },
		async interrupt() { record.interruptions++; },
	};
	return { query, record, release(lateMessages = []) { released.resolve(lateMessages); } };
}

export function fakeSdkQuery(messages, accountLabel, observed) {
	let closed = false;
	return {
		async *[Symbol.asyncIterator]() {
			for (const message of messages) {
				if (closed) break;
				if (message instanceof Error) throw message;
				yield message;
			}
		},
		close() { closed = true; },
		async interrupt() { closed = true; },
		async accountInfo() {
			return { email: `${accountLabel}@example.com`, subscriptionType: "max" };
		},
		async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() {
			observed.usageProbes.push(accountLabel);
			return { subscription_type: "max", rate_limits_available: true, rate_limits: null };
		},
	};
}

/** A child that answers `text` at once, streamed the way Claude Code streams a
 *  plain reply, then reports `sessionId` as its session. */
export function answerSdkQuery(text, sessionId, modelId = "claude-haiku-4-5") {
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: sessionId };
			yield { type: "stream_event", event: { type: "message_start", message: { model: modelId, usage: { input_tokens: 1 } } } };
			yield { type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } };
			yield { type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } };
			yield { type: "result", subtype: "success", result: text };
		},
		close() {},
		async interrupt() {},
	};
}
