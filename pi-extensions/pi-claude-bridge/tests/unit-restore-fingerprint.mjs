/**
 * The restore-integrity fingerprint: the persist path records a hash of Pi's
 * history up to the cursor, and restore reuses the Claude session only when a
 * fresh build of that history hashes the same. Each Pi message is serialized
 * once per process, not once per turn.
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, beforeEach, describe, it } from "node:test";
import { createSession } from "cc-session-io";

import { __testGetBridgeIntegrityState, __testSetBridgeIntegrityState, setExtensionApi } from "../src/bridge-state.ts";
import { __testCancelAllScheduledSessionPersistence, restoreSharedSessionFromPi, schedulePersistSharedSession } from "../src/session-persistence.ts";
import { waitFor } from "./lib/wait-for.mjs";

const root = mkdtempSync(join(tmpdir(), "claude-restore-fingerprint-"));
const previousClaudeDir = process.env.CLAUDE_CONFIG_DIR;
process.env.CLAUDE_CONFIG_DIR = root;

beforeEach(() => {
	__testCancelAllScheduledSessionPersistence();
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

afterEach(() => {
	__testCancelAllScheduledSessionPersistence();
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

after(() => {
	if (previousClaudeDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
	else process.env.CLAUDE_CONFIG_DIR = previousClaudeDir;
	rmSync(root, { recursive: true, force: true });
});

const history = () => [
	{ role: "user", content: "hello", timestamp: 1 },
	{ role: "assistant", provider: "pi-claude", model: "claude-haiku-4-5", content: [{ type: "text", text: "hi" }], timestamp: 2 },
];

async function persist(sessionId, messages) {
	const entries = [];
	setExtensionApi({ appendEntry(type, data) { entries.push({ type, data }); } });
	__testSetBridgeIntegrityState({ sharedSession: { sessionId, cursor: messages.length, cwd: root } });
	schedulePersistSharedSession({ sessionManager: { buildSessionContext: () => ({ messages }), getSessionId: () => "pi-session" } });
	assert.equal(await waitFor(() => entries.length === 1), true, "marker persisted");
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null });
	return { type: "custom", customType: entries[0].type, data: entries[0].data };
}

function restore(marker, messages) {
	restoreSharedSessionFromPi({
		cwd: root,
		sessionManager: {
			getEntries: () => [marker],
			getSessionId: () => "pi-session",
			getCwd: () => root,
			buildSessionContext: () => ({ messages }),
		},
	});
	return __testGetBridgeIntegrityState().sharedSession;
}

describe("restore fingerprint", () => {
	for (const { name, rebuilt, restores } of [
		{ name: "an equal history read back as new objects restores", rebuilt: history, restores: true },
		{
			name: "a changed message inside the cursor refuses",
			rebuilt: () => { const messages = history(); messages[1].content = [{ type: "text", text: "changed" }]; return messages; },
			restores: false,
		},
	]) it(name, async () => {
		const child = createSession({ projectPath: root, claudeDir: root });
		child.addUserMessage("hello");
		child.save();
		const marker = await persist(child.sessionId, history());
		const restored = restore(marker, rebuilt());
		assert.equal(restored?.sessionId, restores ? child.sessionId : undefined);
	});

	it("serializes each message once across persists as the history grows", async () => {
		let serialized = 0;
		const first = { role: "user", content: "hello", timestamp: 1, toJSON() { serialized++; return { role: "user", content: "hello", timestamp: 1 }; } };
		const messages = [first];
		for (let turn = 0; turn < 3; turn++) {
			await persist(`child-${turn}`, messages);
			messages.push({ role: "user", content: `turn ${turn}`, timestamp: turn + 2 });
		}
		assert.equal(serialized, 1);
	});
});
