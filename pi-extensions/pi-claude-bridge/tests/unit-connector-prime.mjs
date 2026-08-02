// C6: a failed connector prime must NOT be cached for the process lifetime.
// A transient failure at provider registration used to pin `{}` for the scope,
// so every later turn stayed undeclared and the disk-cache fallback was
// unreachable until restart. Failures now leave the key unset and the next
// prime retries.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { primeConnectorServers } from "../src/index.ts";
import { readCachedConnectors } from "../src/connector-cache.ts";

const realFetch = globalThis.fetch;
let root;
let configDir;
let savedPiDir;

function writeCredentials(dir) {
	writeFileSync(join(dir, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "prime-test-token" } }));
	writeFileSync(join(dir, ".claude.json"), JSON.stringify({ oauthAccount: { organizationUuid: "org-prime" } }));
}

function okInventoryFetch() {
	return async () => ({
		ok: true,
		status: 200,
		text: async () => JSON.stringify({
			results: [{ name: "Gmail", installedServerId: "srv-1", installState: "connected" }],
		}),
	});
}

async function waitFor(predicate, timeoutMs = 1000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return true;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	return predicate();
}

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "bridge-prime-"));
	configDir = join(root, "claude-config");
	savedPiDir = process.env.PI_CODING_AGENT_DIR;
	// Isolate the on-disk connector cache from the real user dir.
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
	mkdirSync(configDir, { recursive: true });
});

afterEach(() => {
	globalThis.fetch = realFetch;
	if (savedPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedPiDir;
	rmSync(root, { recursive: true, force: true });
});

describe("primeConnectorServers failure caching (C6)", () => {
	it("retries after a transport failure instead of pinning an empty snapshot", async () => {
		writeCredentials(configDir);

		// First prime: the inventory call fails (network blip).
		let fetchCalls = 0;
		globalThis.fetch = async () => {
			fetchCalls += 1;
			throw new Error("network blip");
		};
		primeConnectorServers(configDir);
		await waitFor(() => fetchCalls >= 1);
		await new Promise((resolve) => setTimeout(resolve, 20));
		assert.equal(readCachedConnectors(configDir), undefined, "a failed prime writes no disk cache");

		// Second prime for the SAME scope: must actually retry (the failure was
		// not cached) and succeed end to end, including the disk cache write.
		globalThis.fetch = okInventoryFetch();
		primeConnectorServers(configDir);
		const cached = await waitFor(() => readCachedConnectors(configDir) !== undefined);
		assert.ok(cached, "the retry primes and persists the inventory");
		assert.deepEqual(readCachedConnectors(configDir)?.map((entry) => entry.name), ["Gmail"]);
	});

	it("retries after a missing-credentials prime once credentials appear", async () => {
		globalThis.fetch = okInventoryFetch();

		// No credential files yet: prime resolves nothing and caches nothing.
		primeConnectorServers(configDir);
		await new Promise((resolve) => setTimeout(resolve, 30));
		assert.equal(readCachedConnectors(configDir), undefined);

		// Credentials appear (e.g. `claude login` finished): the next prime works.
		writeCredentials(configDir);
		primeConnectorServers(configDir);
		const cached = await waitFor(() => readCachedConnectors(configDir) !== undefined);
		assert.ok(cached, "the post-login prime is not blocked by the earlier failure");
	});
});
