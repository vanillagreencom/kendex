import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { generateAutoRenameName } from "../extensions/qol/session-rename.ts";

// The naming request's output-token cap is the value pi-qol hands pi-ai's
// `complete`; this suite captures it there and restores the preload stub.
const requests: unknown[] = [];

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-auto-rename-max-tokens-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
	clearPackageConfigCache();
	requests.length = 0;
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async (_model: unknown, _context: unknown, options: { maxTokens?: number }) => {
			requests.push(options?.maxTokens);
			return { content: [{ text: "Named Session", type: "text" }], stopReason: "stop" };
		},
	}));
});

afterEach(() => {
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	clearPackageConfigCache();
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => ({ content: [{ text: "stubbed summary text", type: "text" }], stopReason: "end_turn" }),
	}));
});

function ctx() {
	return {
		cwd: workdir,
		hasUI: false,
		model: undefined,
		modelRegistry: {
			find: (provider: string, id: string) => ({ id, provider }),
			getApiKeyAndHeaders: async () => ({ apiKey: "k", ok: true }),
		},
		ui: { notify() {} },
	};
}

const rows = [
	{ name: "unset reads the shipped default", settings: {}, expected: 128 },
	{ name: "a configured value is sent as set", settings: { "sessionAutoRename.maxTokens": 64 }, expected: 64 },
];

if (rows.length === 0) throw new Error("Auto-rename max-token table is empty");

for (const row of rows) {
	test(`auto-rename output-token cap: ${row.name}`, async () => {
		expect.hasAssertions();
		writeFileSync(join(workdir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": row.settings } } } }), "utf8");
		const result = await generateAutoRenameName("Fix the flaky login test", ctx() as any);
		expect({ name: result.name, requests }).toEqual({ name: "Named Session", requests: [row.expected] });
	});
}
