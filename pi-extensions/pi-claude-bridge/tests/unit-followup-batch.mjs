import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { planIncrementalPromptBatch } from "../src/index.ts";

const msg = (role) => ({ role, content: role === "assistant" ? [] : role });
const roles = (...values) => values.map(msg);

describe("planIncrementalPromptBatch", () => {
	it("batches followUpMode=all users after Claude's trailing assistant", () => {
		const plan = planIncrementalPromptBatch(
			roles("user", "assistant", "user", "user"),
			1,
		);

		assert.deepEqual(plan, {
			promptStart: 2,
			userMessageCount: 2,
		});
	});

	it("keeps the normal single-user reuse path unchanged", () => {
		const plan = planIncrementalPromptBatch(
			roles("user", "assistant", "user"),
			1,
		);

		assert.deepEqual(plan, {
			promptStart: 2,
			userMessageCount: 1,
		});
	});

	it("supports a cursor already advanced past the assistant", () => {
		const plan = planIncrementalPromptBatch(
			roles("user", "assistant", "user", "user"),
			2,
		);

		assert.deepEqual(plan, {
			promptStart: 2,
			userMessageCount: 2,
		});
	});

	it("rejects genuine history divergence containing an intervening assistant", () => {
		const plan = planIncrementalPromptBatch(
			roles("user", "assistant", "user", "assistant", "user"),
			1,
		);

		assert.equal(plan, undefined);
	});

	it("rejects a non-user final prompt", () => {
		assert.equal(
			planIncrementalPromptBatch(roles("user", "assistant", "toolResult"), 1),
			undefined,
		);
	});

	it("rejects a toolResult inside the pending tail", () => {
		assert.equal(
			planIncrementalPromptBatch(roles("user", "assistant", "toolResult", "user"), 1),
			undefined,
		);
	});
});
