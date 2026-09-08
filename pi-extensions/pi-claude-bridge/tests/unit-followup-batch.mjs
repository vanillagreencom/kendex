import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { planIncrementalPromptBatch } from "../src/index.ts";

const msg = (role) => ({ role, content: role === "assistant" ? [] : role });

describe("planIncrementalPromptBatch", () => {
	it("plans only unclaimed user tails after the cursor", () => {
		// Pi emits follow-up tails and may re-enter with a different context.
		for (const { name, roles, cursor, expected } of [
			{ name: "all follow-ups", roles: ["user", "assistant", "user", "user"], cursor: 1, expected: { promptStart: 2, userMessageCount: 2 } },
			{ name: "single follow-up", roles: ["user", "assistant", "user"], cursor: 1, expected: { promptStart: 2, userMessageCount: 1 } },
			{ name: "cursor past assistant", roles: ["user", "assistant", "user", "user"], cursor: 2, expected: { promptStart: 2, userMessageCount: 2 } },
			{ name: "intervening assistant", roles: ["user", "assistant", "user", "assistant", "user"], cursor: 1, expected: undefined },
			{ name: "non-user final prompt", roles: ["user", "assistant", "toolResult"], cursor: 1, expected: undefined },
			{ name: "tool result in tail", roles: ["user", "assistant", "toolResult", "user"], cursor: 1, expected: undefined },
			{ name: "foreign context cursor", roles: ["user"], cursor: 40, expected: undefined },
			{ name: "already claimed last user", roles: ["user", "assistant", "user"], cursor: 3, expected: undefined },
			{ name: "last-index cursor", roles: ["user", "assistant", "user"], cursor: 2, expected: { promptStart: 2, userMessageCount: 1 } },
		]) {
			assert.deepEqual(planIncrementalPromptBatch(roles.map(msg), cursor), expected, name);
		}
	});
});
