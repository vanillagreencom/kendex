import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, beforeEach, describe, it } from "node:test";
import { openSession } from "cc-session-io";

import {
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
} from "../src/bridge-state.ts";
import { syncSharedSession } from "../src/session-persistence.ts";

const root = mkdtempSync(join(tmpdir(), "claude-account-session-"));
const cwd = join(root, "project");
const accountA = join(root, "account-a");
const accountB = join(root, "account-b");

beforeEach(() => {
	rmSync(cwd, { recursive: true, force: true });
	rmSync(accountA, { recursive: true, force: true });
	rmSync(accountB, { recursive: true, force: true });
	mkdirSync(cwd, { recursive: true });
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});
after(() => rmSync(root, { recursive: true, force: true }));

describe("account-scoped Claude sessions", () => {
	it("never resumes or deletes account A's session while switching to account B", () => {
		const messages = [
			{ role: "user", content: "prior context", timestamp: Date.now() },
			{ role: "user", content: "current prompt", timestamp: Date.now() },
		];
		const first = syncSharedSession(
			messages,
			cwd,
			undefined,
			"claude-opus-5",
			{ accountProfileId: "a", claudeConfigDir: accountA },
		);
		assert.ok(first.sessionId);
		const firstPath = openSession({
			sessionId: first.sessionId,
			projectPath: cwd,
			claudeDir: accountA,
		}).jsonlPath;
		assert.equal(existsSync(firstPath), true);

		const second = syncSharedSession(
			messages,
			cwd,
			undefined,
			"claude-opus-5",
			{ accountProfileId: "b", claudeConfigDir: accountB },
		);
		assert.ok(second.sessionId);
		assert.notEqual(second.sessionId, first.sessionId);
		assert.equal(existsSync(firstPath), true, "switching accounts must not delete A's transcript");
		const state = __testGetBridgeIntegrityState().sharedSession;
		assert.equal(state?.accountProfileId, "b");
		assert.equal(state?.claudeConfigDir, accountB);
		assert.equal(state?.modelId, "claude-opus-5");

		const reused = syncSharedSession(
			messages,
			cwd,
			undefined,
			"claude-opus-5",
			{ accountProfileId: "b", claudeConfigDir: accountB },
		);
		assert.equal(reused.sessionId, second.sessionId);
	});

	it("keeps the account-scoped session warm for a batched trailing user run", () => {
		const initial = [
			{ role: "user", content: "prior", timestamp: Date.now() },
			{ role: "user", content: "first prompt", timestamp: Date.now() },
		];
		const first = syncSharedSession(
			initial,
			cwd,
			undefined,
			"claude-opus-5",
			{ accountProfileId: "a", claudeConfigDir: accountA },
		);
		assert.ok(first.sessionId);

		const batched = [
			initial[0],
			{ role: "assistant", content: [{ type: "text", text: "done" }] },
			{ role: "user", content: "follow-up one", timestamp: Date.now() },
			{ role: "user", content: "follow-up two", timestamp: Date.now() },
		];
		const reused = syncSharedSession(
			batched,
			cwd,
			undefined,
			"claude-opus-5",
			{ accountProfileId: "a", claudeConfigDir: accountA },
		);
		assert.equal(reused.sessionId, first.sessionId);
		assert.equal(reused.promptStart, 2);
	});
});
