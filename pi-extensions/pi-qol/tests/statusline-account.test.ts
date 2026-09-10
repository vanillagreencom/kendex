import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { readClaudeBillingIdentityBridge } from "../extensions/qol/bridges.ts";
import { CLAUDE_BILLING_IDENTITY_SYMBOL } from "../extensions/qol/constants.ts";
import { type GitState, renderStatusLine } from "../extensions/qol/statusline.ts";

const EMAIL = "lane@example.test";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const host = globalThis as unknown as Record<PropertyKey, unknown>;

function writeQolConfig(values: Record<string, unknown>): void {
	writeFileSync(
		join(workdir, "settings.json"),
		`${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": values } } } }, null, 2)}\n`,
		"utf8",
	);
}

function publishBridge(value: unknown): void {
	host[CLAUDE_BILLING_IDENTITY_SYMBOL] = value;
}

function makeCtx(): any {
	return {
		cwd: workdir,
		getContextUsage: () => ({ contextWindow: 200_000, percent: 20, tokens: 40_000 }),
		model: { contextWindow: 200_000, id: "test-model", name: "Test Model", provider: "pi-claude" },
	};
}

const git: GitState = { dirty: false, inLinkedWorktree: false, projectName: "repo" };
const pi: any = { getThinkingLevel: () => "off" };
const theme = { fg: (_token: string, text: string) => text };

function render(): string {
	return renderStatusLine(200, makeCtx(), git, pi, theme);
}

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-statusline-account-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	writeQolConfig({});
	delete host[CLAUDE_BILLING_IDENTITY_SYMBOL];
});

afterEach(() => {
	delete host[CLAUDE_BILLING_IDENTITY_SYMBOL];
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
});

const segmentRows = [
	{ name: "a confirmed login is shown", settings: {}, bridge: { currentLoginEmail: () => EMAIL, version: 1 }, expected: true },
	{ name: "showAccount off hides a confirmed login", settings: { "statusline.showAccount": false }, bridge: { currentLoginEmail: () => EMAIL, version: 1 }, expected: false },
	{ name: "an unconfirmed login shows nothing", settings: {}, bridge: { currentLoginEmail: () => undefined, version: 1 }, expected: false },
	{ name: "no bridge shows nothing", settings: {}, bridge: undefined, expected: false },
];

if (segmentRows.length === 0) throw new Error("Statusline account table is empty");

for (const row of segmentRows) {
	test(row.name, () => {
		expect.hasAssertions();
		writeQolConfig(row.settings);
		publishBridge(row.bridge);
		expect(render().includes(EMAIL)).toBe(row.expected);
	});
}

// A published value this reader accepts is one it will call. Each row is a
// shape a foreign or stale publisher can leave on the symbol.
const bridgeShapeRows = [
	{ name: "a v1 store with the reader is accepted", value: { currentLoginEmail: () => EMAIL, version: 1 }, expected: true },
	{ name: "a later version is refused", value: { currentLoginEmail: () => EMAIL, version: 2 }, expected: false },
	{ name: "a store with no version is refused", value: { currentLoginEmail: () => EMAIL }, expected: false },
	{ name: "a store with no reader is refused", value: { version: 1 }, expected: false },
	{ name: "a non-callable reader is refused", value: { currentLoginEmail: EMAIL, version: 1 }, expected: false },
	{ name: "a non-object is refused", value: "published", expected: false },
	{ name: "an absent publisher is refused", value: undefined, expected: false },
];

if (bridgeShapeRows.length === 0) throw new Error("Bridge shape table is empty");

for (const row of bridgeShapeRows) {
	test(row.name, () => {
		expect.hasAssertions();
		publishBridge(row.value);
		expect(readClaudeBillingIdentityBridge() !== undefined).toBe(row.expected);
	});
}
