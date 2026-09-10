import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import { claudeAccountEmail, claudeConfigDir, resetAccountCache } from "../extensions/qol/account.ts";
import { type GitState, renderStatusLine } from "../extensions/qol/statusline.ts";

const EMAIL = "lane@example.test";
const OTHER_EMAIL = "other@example.test";
const BRIDGE_PROVIDER = "pi-claude";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalConfigDir = process.env.CLAUDE_CONFIG_DIR;

function writeQolConfig(values: Record<string, unknown>): void {
	writeFileSync(
		join(workdir, "settings.json"),
		`${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": values } } } }, null, 2)}\n`,
		"utf8",
	);
}

function writeAccountFile(body: string): void {
	writeFileSync(join(workdir, ".claude.json"), body, "utf8");
}

function accountJson(email: unknown): string {
	return JSON.stringify({ oauthAccount: email === undefined ? {} : { emailAddress: email } });
}

function makeCtx(provider: string | undefined): any {
	return {
		cwd: workdir,
		getContextUsage: () => ({ contextWindow: 200_000, percent: 20, tokens: 40_000 }),
		model: provider === undefined ? undefined : { contextWindow: 200_000, id: "test-model", name: "Test Model", provider },
	};
}

const git: GitState = { dirty: false, inLinkedWorktree: false, projectName: "repo" };
const pi: any = { getThinkingLevel: () => "off" };
const theme = { fg: (_token: string, text: string) => text };

function render(provider: string | undefined): string {
	return renderStatusLine(200, makeCtx(provider), git, pi, theme);
}

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-statusline-account-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.CLAUDE_CONFIG_DIR = workdir;
	resetAccountCache();
});

afterEach(() => {
	resetAccountCache();
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
	else process.env.CLAUDE_CONFIG_DIR = originalConfigDir;
});

// Render-level rows cover the two gates. What counts as an email at all is
// asserted on claudeAccountEmail below, where a rejected value is visible as
// undefined rather than as the absence of one particular string.
const segmentRows = [
	{ name: "a bridge model shows the signed-in email", settings: {}, provider: BRIDGE_PROVIDER, expected: true },
	{ name: "showAccount off hides the email", settings: { "statusline.showAccount": false }, provider: BRIDGE_PROVIDER, expected: false },
	{ name: "a non-bridge provider hides the email", settings: {}, provider: "ollama", expected: false },
	{ name: "no model hides the email", settings: {}, provider: undefined, expected: false },
];

if (segmentRows.length === 0) throw new Error("Statusline account table is empty");

for (const row of segmentRows) {
	test(row.name, () => {
		expect.hasAssertions();
		writeQolConfig(row.settings);
		writeAccountFile(accountJson(EMAIL));
		expect(render(row.provider).includes(EMAIL)).toBe(row.expected);
	});
}

const emailRows = [
	{ name: "a signed-in account reads as its email", account: accountJson(EMAIL), expected: EMAIL },
	{ name: "a padded email is trimmed", account: accountJson(`  ${EMAIL}  `), expected: EMAIL },
	{ name: "a malformed account file reads as unknown", account: "{ not json", expected: undefined },
	{ name: "an account file with no email reads as unknown", account: accountJson(undefined), expected: undefined },
	{ name: "a blank email reads as unknown", account: accountJson("   "), expected: undefined },
	{ name: "a non-string email reads as unknown", account: accountJson(42), expected: undefined },
	{ name: "a missing account file reads as unknown", account: undefined, expected: undefined },
];

if (emailRows.length === 0) throw new Error("Account email table is empty");

for (const row of emailRows) {
	test(row.name, () => {
		expect.hasAssertions();
		if (row.account !== undefined) writeAccountFile(row.account);
		expect(claudeAccountEmail()).toBe(row.expected);
	});
}

test("a re-signed-in account replaces the cached email", () => {
	expect.hasAssertions();
	writeAccountFile(accountJson(EMAIL));
	const first = claudeAccountEmail();
	writeAccountFile(accountJson(OTHER_EMAIL));
	expect([first, claudeAccountEmail()]).toEqual([EMAIL, OTHER_EMAIL]);
});

const configDirRows = [
	{ name: "an explicit CLAUDE_CONFIG_DIR is used as given", env: "/lane/.sclaude", expected: "/lane/.sclaude" },
	{ name: "a padded CLAUDE_CONFIG_DIR is trimmed", env: "  /lane/.sclaude  ", expected: "/lane/.sclaude" },
	{ name: "a blank CLAUDE_CONFIG_DIR falls back to the home directory", env: "   ", expected: join(homedir(), ".claude") },
	{ name: "an unset CLAUDE_CONFIG_DIR falls back to the home directory", env: undefined, expected: join(homedir(), ".claude") },
];

if (configDirRows.length === 0) throw new Error("Claude config dir table is empty");

for (const row of configDirRows) {
	test(row.name, () => {
		expect.hasAssertions();
		expect(claudeConfigDir(row.env === undefined ? {} : { CLAUDE_CONFIG_DIR: row.env })).toBe(row.expected);
	});
}
