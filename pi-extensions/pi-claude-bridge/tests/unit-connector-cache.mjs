import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import {
	connectorCachePath, connectorCacheScopeKey, readCachedConnectors, writeCachedConnectors,
	connectorMcpServers,
} from "../bundle/index.js";

// The payload stores the FULL sha256 hex of the scope key (the filename keeps
// only the first 16 chars), never the raw CLAUDE_CONFIG_DIR path — a config-dir
// path is account-identifying and does not belong in a state file.
const scopeDigest = (scopeKey) => createHash("sha256").update(scopeKey).digest("hex");

// piUserDir() reads PI_CODING_AGENT_DIR, so each test gets its own state dir.
function withStateDir(fn) {
	const dir = mkdtempSync(join(tmpdir(), "conn-cache-"));
	const prev = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = dir;
	try { return fn(dir); } finally {
		if (prev === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = prev;
		rmSync(dir, { recursive: true, force: true });
	}
}

const SLACK = { name: "Slack", installedServerId: "id-slack", installState: "connected" };

test("round-trips across processes: what one run writes, a cold run reads", () => {
	withStateDir(() => {
		assert.equal(writeCachedConnectors([SLACK], "/scope/a"), true);
		const read = readCachedConnectors("/scope/a");
		assert.deepEqual(read, [SLACK]);
		// And it must survive the same derivation the live path uses.
		assert.deepEqual(
			Object.keys(connectorMcpServers({ ok: true, complete: true, connectors: read })),
			["claude.ai Slack"],
		);
	});
});

test("scopes are isolated — one account never reads another's connectors", () => {
	// The org UUID is ignored by the inventory API; only the credential selects
	// the account. A shared cache entry would hand over the wrong account's list.
	withStateDir(() => {
		writeCachedConnectors([SLACK], "/scope/a");
		assert.equal(readCachedConnectors("/scope/b"), undefined);
		assert.notEqual(connectorCachePath("/scope/a"), connectorCachePath("/scope/b"));
	});
});

test("the raw scope path is never persisted — the payload stores its digest", () => {
	withStateDir(() => {
		assert.equal(writeCachedConnectors([SLACK], "/scope/secret-account-dir"), true);
		const raw = readFileSync(connectorCachePath("/scope/secret-account-dir"), "utf8");
		assert.equal(raw.includes("/scope/secret-account-dir"), false, "config-dir path must not be written to disk");
		assert.equal(JSON.parse(raw).scope, scopeDigest("/scope/secret-account-dir"));
	});
});

test("cache validity rejects stale or malformed files and accepts a fresh file", () => {
	const base = { version: 2, scope: scopeDigest("/scope/a"), connectors: [SLACK], savedAt: Date.now() };
	const rows = [
		["scope mismatch", JSON.stringify({ ...base, scope: scopeDigest("/scope/OTHER") }), undefined],
		["old version", JSON.stringify({ ...base, version: 1, scope: "/scope/a" }), undefined],
		["expired", JSON.stringify({ ...base, savedAt: Date.now() - 8 * 24 * 3600 * 1000 }), undefined],
		["future", JSON.stringify({ ...base, savedAt: Date.now() + 60_000 }), undefined],
		["wrong version", JSON.stringify({ ...base, version: 999 }), undefined],
		["corrupt", "{not json", undefined],
		["missing", undefined, undefined],
		["fresh", JSON.stringify({ ...base, savedAt: Date.now() - 6 * 24 * 3600 * 1000 }), [SLACK]],
	];
	for (const [name, raw, expected] of rows) {
		withStateDir(() => {
			const path = connectorCachePath("/scope/a");
			mkdirSync(dirname(path), { recursive: true });
			if (raw !== undefined) writeFileSync(path, raw);
			assert.deepEqual(readCachedConnectors("/scope/a"), expected, name);
		});
	}
});

test("empty and malformed entry lists are not written or returned", () => {
	withStateDir(() => {
		assert.equal(writeCachedConnectors([], "/scope/a"), false);
		assert.equal(readCachedConnectors("/scope/a"), undefined);
		writeCachedConnectors([{ nope: true }, SLACK], "/scope/b");
		assert.deepEqual(readCachedConnectors("/scope/b"), [SLACK], "unnamed entries are dropped");
	});
});

test("scope key follows CLAUDE_CONFIG_DIR", () => {
	const prev = process.env.CLAUDE_CONFIG_DIR;
	try {
		for (const [value, expected] of [["/scope/acct-one", "/scope/acct-one"], [undefined, "<default>"]]) {
			if (value === undefined) delete process.env.CLAUDE_CONFIG_DIR;
			else process.env.CLAUDE_CONFIG_DIR = value;
			assert.equal(connectorCacheScopeKey(), expected, String(value));
		}
	} finally {
		if (prev === undefined) delete process.env.CLAUDE_CONFIG_DIR;
		else process.env.CLAUDE_CONFIG_DIR = prev;
	}
});
