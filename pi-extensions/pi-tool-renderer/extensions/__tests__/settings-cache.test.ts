import { afterEach, describe, expect, setSystemTime, test } from "bun:test";
import { mkdirSync, mkdtempSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CONFIG_ID, readPackageConfig, recordProjectTrust, SETTINGS_RECHECK_MS } from "../tool-renderer/settings.js";

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

afterEach(() => {
	setSystemTime();
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

/** One user dir + one trusted project whose settings.json carries `config` at a pinned mtime. Returns the project cwd. */
function project(config: Record<string, unknown>, mtime = new Date(1000)): string {
	const root = mkdtempSync(join(tmpdir(), "kendex-settings-cache-"));
	const agentDir = join(root, "agent");
	const dotPi = join(root, "project", ".pi");
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(dotPi, { recursive: true });
	const settingsPath = join(dotPi, "settings.json");
	writeFileSync(settingsPath, JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: config } } } }));
	utimesSync(settingsPath, mtime, mtime);
	recordProjectTrust({ cwd: join(root, "project"), isProjectTrusted: () => true });
	process.env.PI_CODING_AGENT_DIR = agentDir;
	return join(root, "project");
}

describe("readPackageConfig memoization", () => {
	test("two roots with identical stat metadata read their own configs", () => {
		// Same byte length and pinned mtime: only the path tells the two
		// projects apart, or the second root inherits the first's config.
		const a = project({ commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		const b = project({ commandPreviewChars: 200 });
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
	});

	test("a real edit re-merges; a rewrite under the old mtime serves the cache", () => {
		const a = project({ commandPreviewChars: 100 });
		const settingsPath = join(a, ".pi", "settings.json");
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);

		// Content rewrite with the old mtime pinned back: fingerprint unchanged, memoized merge served.
		writeFileSync(settingsPath, JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { commandPreviewChars: 300 } } } } }));
		utimesSync(settingsPath, new Date(1000), new Date(1000));
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);

		// A real edit moves the fingerprint; lookups inside the recheck window
		// still serve the cache, the first one after it re-merges.
		const now = Date.now();
		setSystemTime(now);
		readPackageConfig(CONFIG_ID, a);
		utimesSync(settingsPath, new Date(2000), new Date(2000));
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		setSystemTime(now + SETTINGS_RECHECK_MS);
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(300);
	});
});
