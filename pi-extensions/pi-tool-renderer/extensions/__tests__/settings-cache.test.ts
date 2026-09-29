import { afterEach, beforeEach, describe, expect, setSystemTime, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CONFIG_ID, readPackageConfig, recordProjectTrust, SETTINGS_RECHECK_MS } from "../tool-renderer/settings.js";

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

/** The cache window reads `performance.now()`; each case moves this value instead of waiting. */
let monotonicNow = 0;
let monotonicClock: ReturnType<typeof spyOn> | undefined;

beforeEach(() => {
	monotonicNow = 0;
	monotonicClock = spyOn(performance, "now").mockImplementation(() => monotonicNow);
});

afterEach(() => {
	monotonicClock?.mockRestore();
	setSystemTime();
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

function writeConfig(settingsPath: string, config: Record<string, unknown>): void {
	writeFileSync(settingsPath, JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: config } } } }));
}

/** One user dir + one trusted project whose settings.json carries `config`. Returns the project cwd. */
function project(config: Record<string, unknown>): string {
	const root = mkdtempSync(join(tmpdir(), "kendex-settings-cache-"));
	const agentDir = join(root, "agent");
	const dotPi = join(root, "project", ".pi");
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(dotPi, { recursive: true });
	writeConfig(join(dotPi, "settings.json"), config);
	recordProjectTrust({ cwd: join(root, "project"), isProjectTrusted: () => true });
	process.env.PI_CODING_AGENT_DIR = agentDir;
	return join(root, "project");
}

describe("readPackageConfig memoization", () => {
	test("two roots read their own configs", () => {
		const a = project({ commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		const b = project({ commandPreviewChars: 200 });
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
	});

	test("an edit is served from the cache inside the window and read from disk after it", () => {
		const a = project({ commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		writeConfig(join(a, ".pi", "settings.json"), { commandPreviewChars: 300 });
		monotonicNow = SETTINGS_RECHECK_MS - 1;
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		monotonicNow = SETTINGS_RECHECK_MS;
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(300);
	});

	test("a backward wall-clock step does not extend the window", () => {
		const wallClock = Date.now();
		setSystemTime(wallClock);
		const a = project({ commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		writeConfig(join(a, ".pi", "settings.json"), { commandPreviewChars: 300 });
		setSystemTime(wallClock - 60 * 60 * 1000);
		monotonicNow = SETTINGS_RECHECK_MS;
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(300);
	});

	test("a project trust change is applied inside the window", () => {
		const a = project({ commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		recordProjectTrust({ cwd: a, isProjectTrusted: () => false });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBeUndefined();
	});
});
