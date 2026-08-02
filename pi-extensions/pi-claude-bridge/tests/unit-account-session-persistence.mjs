import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, beforeEach, describe, it } from "node:test";
import { createSession } from "cc-session-io";

import { CLAUDE_ACCOUNT_ROUTER_SYMBOL } from "../src/account-router.ts";
import {
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
	setExtensionApi,
} from "../src/bridge-state.ts";
import {
	cancelScheduledSessionPersistence,
	restoreSharedSessionFromPi,
	schedulePersistSharedSession,
} from "../src/session-persistence.ts";

const root = mkdtempSync(join(tmpdir(), "claude-account-persistence-"));
const cwd = join(root, "project");
const profileDir = join(root, "profile-a");

function fingerprint(messages) {
	return createHash("sha256").update(JSON.stringify(messages)).digest("hex");
}

beforeEach(() => {
	mkdirSync(cwd, { recursive: true });
	mkdirSync(profileDir, { recursive: true });
	cancelScheduledSessionPersistence();
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
	delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
});

afterEach(() => {
	cancelScheduledSessionPersistence();
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
	delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
});

after(() => rmSync(root, { recursive: true, force: true }));

describe("account-scoped session persistence", () => {
	it("persists only the opaque profile id and model, not the identifying config path", async () => {
		const entries = [];
		setExtensionApi({ appendEntry(type, data) { entries.push({ type, data }); } });
		__testSetBridgeIntegrityState({
			sharedSession: {
				sessionId: "child-session",
				cursor: 1,
				cwd,
				modelId: "claude-opus-5",
				accountProfileId: "profile-a",
				claudeConfigDir: profileDir,
			},
		});
		const messages = [{ role: "user", content: "hello", timestamp: 1 }];
		schedulePersistSharedSession({
			sessionManager: {
				buildSessionContext: () => ({ messages }),
				getSessionId: () => "pi-session",
			},
		});
		await new Promise((resolve) => setTimeout(resolve, 10));

		assert.equal(entries.length, 1);
		assert.equal(entries[0].type, "claude-bridge-session");
		assert.equal(entries[0].data.accountProfileId, "profile-a");
		assert.equal(entries[0].data.modelId, "claude-opus-5");
		assert.equal("claudeConfigDir" in entries[0].data, false);
	});

	it("re-resolves an opaque persisted profile through the account router", () => {
		const messages = [{ role: "user", content: "hello", timestamp: 1 }];
		const child = createSession({ projectPath: cwd, claudeDir: profileDir });
		child.addUserMessage("hello");
		child.save();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = {
			version: 1,
			current(modelId, sessionId) {
				assert.equal(modelId, "claude-opus-5");
				assert.equal(sessionId, "pi-session");
				return { profileId: "profile-a", label: "Account A", configDir: profileDir };
			},
		};
		const marker = {
			type: "custom",
			customType: "claude-bridge-session",
			data: {
				sessionId: child.sessionId,
				cursor: 1,
				cwd,
				modelId: "claude-opus-5",
				accountProfileId: "profile-a",
				fingerprint: fingerprint(messages),
				piSessionId: "pi-session",
				updatedAt: new Date().toISOString(),
			},
		};

		restoreSharedSessionFromPi({
			cwd,
			sessionManager: {
				getEntries: () => [marker],
				getSessionId: () => "pi-session",
				getCwd: () => cwd,
				buildSessionContext: () => ({ messages }),
			},
		});

		assert.deepEqual(__testGetBridgeIntegrityState().sharedSession, {
			sessionId: child.sessionId,
			cursor: 1,
			cwd,
			modelId: "claude-opus-5",
			accountProfileId: "profile-a",
			claudeConfigDir: profileDir,
		});
	});

	it("accepts one legacy path-bearing marker as a migration fallback", () => {
		const messages = [{ role: "user", content: "legacy", timestamp: 1 }];
		const child = createSession({ projectPath: cwd, claudeDir: profileDir });
		child.addUserMessage("legacy");
		child.save();
		const marker = {
			type: "custom",
			customType: "claude-bridge-session",
			data: {
				sessionId: child.sessionId,
				cursor: 1,
				cwd,
				accountProfileId: "profile-a",
				claudeConfigDir: profileDir,
				fingerprint: fingerprint(messages),
				piSessionId: "pi-session",
				updatedAt: new Date().toISOString(),
			},
		};

		restoreSharedSessionFromPi({
			cwd,
			sessionManager: {
				getEntries: () => [marker],
				getSessionId: () => "pi-session",
				getCwd: () => cwd,
				buildSessionContext: () => ({ messages }),
			},
		});

		assert.equal(__testGetBridgeIntegrityState().sharedSession?.claudeConfigDir, profileDir);
	});
});
