import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import {
	connectorCachePath, connectorCacheScopeKey, readCachedConnectors, writeCachedConnectors,
	connectorMcpServers,
} from "../bundle/index.js";

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

test("a file whose recorded scope disagrees with the requested one is rejected", () => {
	// Guards a hash collision or a hand-copied cache file.
	withStateDir(() => {
		const path = connectorCachePath("/scope/a");
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, JSON.stringify({ version: 1, scope: "/scope/OTHER", savedAt: Date.now(), connectors: [SLACK] }));
		assert.equal(readCachedConnectors("/scope/a"), undefined);
	});
});

test("stale, future-dated, wrong-version, corrupt and missing all fail open", () => {
	withStateDir(() => {
		const path = connectorCachePath("/scope/a");
		mkdirSync(dirname(path), { recursive: true });
		const base = { version: 1, scope: "/scope/a", connectors: [SLACK] };

		writeFileSync(path, JSON.stringify({ ...base, savedAt: Date.now() - 8 * 24 * 3600 * 1000 }));
		assert.equal(readCachedConnectors("/scope/a"), undefined, "8 days old must expire");

		writeFileSync(path, JSON.stringify({ ...base, savedAt: Date.now() + 60_000 }));
		assert.equal(readCachedConnectors("/scope/a"), undefined, "future savedAt is not trusted");

		writeFileSync(path, JSON.stringify({ ...base, version: 999, savedAt: Date.now() }));
		assert.equal(readCachedConnectors("/scope/a"), undefined, "version mismatch must invalidate");

		writeFileSync(path, "{not json");
		assert.equal(readCachedConnectors("/scope/a"), undefined, "corrupt must not throw");

		rmSync(path);
		assert.equal(readCachedConnectors("/scope/a"), undefined, "missing must not throw");
	});
});

test("within the freshness window it is used", () => {
	withStateDir(() => {
		const path = connectorCachePath("/scope/a");
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, JSON.stringify({ version: 1, scope: "/scope/a", savedAt: Date.now() - 6 * 24 * 3600 * 1000, connectors: [SLACK] }));
		assert.deepEqual(readCachedConnectors("/scope/a"), [SLACK]);
	});
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
		process.env.CLAUDE_CONFIG_DIR = "/tmp/acct-one";
		assert.equal(connectorCacheScopeKey(), "/tmp/acct-one");
		delete process.env.CLAUDE_CONFIG_DIR;
		assert.equal(connectorCacheScopeKey(), "<default>");
	} finally {
		if (prev === undefined) delete process.env.CLAUDE_CONFIG_DIR;
		else process.env.CLAUDE_CONFIG_DIR = prev;
	}
});
