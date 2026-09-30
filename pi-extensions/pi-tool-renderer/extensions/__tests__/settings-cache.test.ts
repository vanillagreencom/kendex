import { afterEach, beforeEach, describe, expect, setSystemTime, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import {
	clearPackageConfigCache,
	installSettingsCacheRefresh,
	piSettingsPaths,
	piUserDir,
	readPackageConfig,
	readSettingsFiles,
	recordProjectTrust,
	SETTINGS_CHANGED_EVENT,
	SETTINGS_RECHECK_MS,
	settingsMemo,
} from "../tool-renderer/package-config.js";
import { CONFIG_ID } from "../tool-renderer/settings.js";

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
const previousHome = process.env.HOME;

/** The cache window reads `performance.now()`; each case moves this value instead of waiting. */
let monotonicNow = 0;
let monotonicClock: ReturnType<typeof spyOn> | undefined;

beforeEach(() => {
	monotonicNow = 0;
	monotonicClock = spyOn(performance, "now").mockImplementation(() => monotonicNow);
	clearPackageConfigCache();
});

afterEach(() => {
	monotonicClock?.mockRestore();
	setSystemTime();
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
	if (previousHome === undefined) delete process.env.HOME;
	else process.env.HOME = previousHome;
	clearPackageConfigCache();
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
	clearPackageConfigCache();
	return join(root, "project");
}

describe("readPackageConfig memoization", () => {
	test("two roots read their own configs and stay cached side by side", () => {
		const a = project({ commandPreviewChars: 100 });
		const b = project({ commandPreviewChars: 200 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
		// Disk now disagrees with both entries: alternating reads inside the window
		// return the primed values only if neither root evicts the other.
		writeConfig(join(a, ".pi", "settings.json"), { commandPreviewChars: 300 });
		writeConfig(join(b, ".pi", "settings.json"), { commandPreviewChars: 400 });
		monotonicNow = SETTINGS_RECHECK_MS - 1;
		for (let round = 0; round < 2; round++) {
			expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
			expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(200);
		}
		monotonicNow = SETTINGS_RECHECK_MS;
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(300);
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(400);
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

	test("a cwd that joins a window another cwd opened closes with it", () => {
		const root = mkdtempSync(join(tmpdir(), "kendex-settings-shared-"));
		const agentDir = join(root, "agent");
		const [a, b] = [join(root, "a"), join(root, "b")];
		for (const dir of [agentDir, a, b]) mkdirSync(dir, { recursive: true });
		process.env.PI_CODING_AGENT_DIR = agentDir;
		clearPackageConfigCache();
		// Neither cwd is a trusted project, so both read the user file alone.
		writeConfig(join(agentDir, "settings.json"), { commandPreviewChars: 100 });
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
		monotonicNow = SETTINGS_RECHECK_MS - 100;
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(100);
		writeConfig(join(agentDir, "settings.json"), { commandPreviewChars: 300 });
		monotonicNow = SETTINGS_RECHECK_MS;
		expect(readPackageConfig(CONFIG_ID, b).commandPreviewChars).toBe(300);
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

describe("readSettingsFiles fingerprint", () => {
	test("an unchanged file keeps its parse past the window; a changed one is parsed again", () => {
		const a = project({ commandPreviewChars: 100 });
		const first = readPackageConfig(CONFIG_ID, a);
		monotonicNow = SETTINGS_RECHECK_MS * 3;
		expect(readPackageConfig(CONFIG_ID, a)).toBe(first);
		writeConfig(join(a, ".pi", "settings.json"), { commandPreviewChars: 300 });
		monotonicNow = SETTINGS_RECHECK_MS * 5;
		const second = readPackageConfig(CONFIG_ID, a);
		expect(second).not.toBe(first);
		expect(second.commandPreviewChars).toBe(300);
	});

	test("a malformed file is reported and contributes nothing", () => {
		const a = project({ commandPreviewChars: 100 });
		writeFileSync(join(a, ".pi", "settings.json"), "{");
		const paths = [join(a, ".pi", "settings.json"), join(a, "absent.json")];
		expect(readSettingsFiles(paths).map((file) => [file.kind, file.path])).toEqual([["malformed", paths[0]]]);
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBeUndefined();
	});

	test("a memoized config is frozen, so a caller cannot change what the next caller reads", () => {
		const a = project({ commandPreviewChars: 100, nested: { depth: 1 } });
		const config = readPackageConfig(CONFIG_ID, a) as Record<string, any>;
		expect(() => { config.commandPreviewChars = 5; }).toThrow();
		expect(() => { config.nested.depth = 5; }).toThrow();
		expect(readPackageConfig(CONFIG_ID, a).commandPreviewChars).toBe(100);
	});
});

// piUserDir answers for the environment of each call. The settings reads
// memoize the user directory instead, so each row reads one cwd and moves the
// clock past the window before it reads. Bun's `homedir()` does not follow a `HOME` set at
// run time, so under this runner the two `HOME` rows only confirm the default
// root; under Node, Pi's runtime, they catch a root kept past a `HOME` change.
describe("user directory", () => {
	test("a change to any variable it reads is answered by piUserDir at once and by a one-cwd settings read after one window", () => {
		const cwd = mkdtempSync(join(tmpdir(), "kendex-user-dir-"));
		const rows: Array<{ name: string; agentDir: string | undefined; home: string; expected: () => string }> = [
			{ name: "override", agentDir: "/pi-root/a", home: "/home-one", expected: () => "/pi-root/a" },
			{ name: "another override", agentDir: "/pi-root/b", home: "/home-one", expected: () => "/pi-root/b" },
			{ name: "no override", agentDir: undefined, home: "/home-one", expected: () => join(homedir(), ".pi", "agent") },
			{ name: "another home", agentDir: undefined, home: "/home-two", expected: () => join(homedir(), ".pi", "agent") },
		];
		for (const row of rows) {
			if (row.agentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = row.agentDir;
			process.env.HOME = row.home;
			expect(piUserDir(), row.name).toBe(row.expected());
			monotonicNow += SETTINGS_RECHECK_MS;
			expect(piSettingsPaths(cwd)[0], row.name).toBe(join(row.expected(), "settings.json"));
		}
	});
});

describe("settingsMemo", () => {
	test("a stored undefined is an answer, served inside the window", () => {
		let computed = 0;
		const compute = () => { computed += 1; return undefined; };
		expect(settingsMemo("memo-undefined", compute)).toBeUndefined();
		expect(settingsMemo("memo-undefined", compute)).toBeUndefined();
		expect(computed).toBe(1);
		monotonicNow = SETTINGS_RECHECK_MS;
		settingsMemo("memo-undefined", compute);
		expect(computed).toBe(2);
	});
});

describe("installSettingsCacheRefresh", () => {
	/** A host with Pi's `on` and `events.on` shapes that records what it was given. */
	function host() {
		const handlers = new Map<string, Array<() => void>>();
		const listeners = new Map<string, Set<(data: unknown) => void>>();
		return {
			on(event: string, handler: () => void) { handlers.set(event, [...(handlers.get(event) ?? []), handler]); },
			events: {
				on(channel: string, handler: (data: unknown) => void) {
					const set = listeners.get(channel) ?? new Set();
					set.add(handler);
					listeners.set(channel, set);
					return () => set.delete(handler);
				},
			},
			fire(event: string) { for (const handler of handlers.get(event) ?? []) handler(); },
			emit(channel: string) { for (const handler of listeners.get(channel) ?? []) handler({}); },
			listening(channel: string) { return listeners.get(channel)?.size ?? 0; },
		};
	}

	/** Each row reads the config once, rewrites the file, then runs `act`; the
	 * next read inside the window sees the rewrite only if `act` dropped the memo. */
	const rows: Array<{ name: string; before: (pi: ReturnType<typeof host>) => void; act: (pi: ReturnType<typeof host>) => void; expected: number; listening: number }> = [
		{ name: "a session start drops the memo", before: () => {}, act: (pi) => pi.fire("session_start"), expected: 300, listening: 1 },
		{ name: "the settings-changed event drops the memo", before: (pi) => pi.fire("session_start"), act: (pi) => pi.emit(SETTINGS_CHANGED_EVENT), expected: 300, listening: 1 },
		{ name: "after shutdown the event is no longer heard", before: (pi) => { pi.fire("session_start"); pi.fire("session_shutdown"); }, act: (pi) => pi.emit(SETTINGS_CHANGED_EVENT), expected: 100, listening: 0 },
	];

	for (const row of rows) {
		test(row.name, () => {
			const cwd = project({ commandPreviewChars: 100 });
			const pi = host();
			installSettingsCacheRefresh(pi);
			row.before(pi);
			expect(readPackageConfig(CONFIG_ID, cwd).commandPreviewChars).toBe(100);
			writeConfig(join(cwd, ".pi", "settings.json"), { commandPreviewChars: 300 });
			row.act(pi);
			expect(readPackageConfig(CONFIG_ID, cwd).commandPreviewChars).toBe(row.expected);
			expect(pi.listening(SETTINGS_CHANGED_EVENT)).toBe(row.listening);
		});
	}
});
