import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { renderStatusLine } from "../extensions/qol/statusline.ts";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalChildAgent = process.env.PI_SUBAGENT_CHILD_AGENT;
const theme = { fg: (_token: string, text: string) => text };
const git = { dirty: false, inLinkedWorktree: false, projectName: "kendex" };
const pi = { getThinkingLevel: () => "medium" } as ExtensionAPI;

function config(showProvider?: boolean) {
	writeFileSync(join(workdir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: {
		"@vanillagreen/pi-qol": showProvider === undefined ? {} : { "statusline.showProvider": showProvider },
	} } } }));
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

function context(provider?: string): ExtensionContext {
	return {
		cwd: workdir,
		getContextUsage: () => ({ contextWindow: 1_000_000, percent: 5 }),
		model: provider === undefined ? undefined : { provider, id: "gpt-6-astra", name: "GPT 6 Astra" },
	} as ExtensionContext;
}

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "qol-provider-"));
	mkdirSync(join(workdir, ".pi"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	clearPackageConfigCache();
	delete process.env.PI_SUBAGENT_CHILD_AGENT;
	config(true);
});

afterEach(() => {
	rmSync(workdir, { recursive: true, force: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalChildAgent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = originalChildAgent;
	clearPackageConfigCache();
});

const rows = [
	["github-copilot", "Copilot"], ["openai", "OpenAI"], ["openai-codex", "Codex"],
	["pi-claude", "Claude"], ["anthropic", "Anthropic"], ["google-vertex", "Vertex AI"],
	["amazon-bedrock", "Bedrock"], ["openrouter", "OpenRouter"], ["xai", "xAI"],
	["team_proxy-east", "Team Proxy East"], ["MyProxy", "MyProxy"], ["constructor", "Constructor"],
];
for (const [provider, label] of rows) {
	test(`provider label: ${provider}`, () => {
		expect(renderStatusLine(120, context(provider), git, pi, theme).startsWith(`kendex ${label} / GPT 6 Astra / medium 1M`)).toBe(true);
	});
}

for (const enabled of [undefined, false, true]) {
	test(`persisted provider toggle: ${enabled}`, () => {
		config(enabled);
		const expected = enabled !== false ? "Copilot / " : "";
		expect(renderStatusLine(120, context("github-copilot"), git, pi, theme).startsWith(`kendex ${expected}GPT 6 Astra`)).toBe(true);
	});
}

test("provider follows model selection and persisted settings without reload", () => {
	const ctx = context("github-copilot");
	expect(renderStatusLine(120, ctx, git, pi, theme)).toContain("Copilot / GPT 6 Astra");
	ctx.model = context("openai-codex").model;
	expect(renderStatusLine(120, ctx, git, pi, theme)).toContain("Codex / GPT 6 Astra");
	config(false);
	expect(renderStatusLine(120, ctx, git, pi, theme)).not.toContain("Codex / ");
});

test("no selected model has no dangling provider separator", () => {
	expect(renderStatusLine(120, context(), git, pi, theme).startsWith("kendex no model / medium")).toBe(true);
});

for (const width of [0, 1, 12, 40, 120]) {
	test(`spinner prefix and provider fit width ${width}`, () => {
		const line = renderStatusLine(width, context("github-copilot"), git, pi, theme, "●");
		expect(line.length).toBeLessThanOrEqual(width);
		if (width >= 12) expect(line.startsWith("● kendex ")).toBe(true);
		if (width === 120) expect(line.endsWith("95%")).toBe(true);
	});
}
