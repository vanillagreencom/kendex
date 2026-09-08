import assert from "node:assert/strict";
import test from "node:test";
import { resolveWebProvider, resolveWebProviderCandidates } from "../src/provider-selection.js";
import { DEFAULT_SETTINGS, type WebToolsSettings } from "../src/settings.js";

const model = { provider: "openai-codex", id: "gpt-6-astra" };
for (const { name, overrides, prefix, expected } of [
	{ name: "Exa key", overrides: { apiKeys: { exa: "key" } }, prefix: 3, expected: ["exa", "exa-mcp", "duckduckgo"] },
	{ name: "Perplexity key", overrides: { apiKeys: { perplexity: "key" } }, prefix: 4, expected: ["perplexity", "exa-mcp", "duckduckgo", "openai-native"] },
	{ name: "no key", overrides: {}, expected: ["exa-mcp", "duckduckgo", "openai-native"] },
	{ name: "Gemini key and cookies", overrides: { apiKeys: { gemini: "key" }, browserCookieAccess: true }, expected: ["gemini", "exa-mcp", "duckduckgo", "openai-native"] },
	{ name: "cookies only", overrides: { browserCookieAccess: true }, expected: ["exa-mcp", "duckduckgo", "gemini", "openai-native"] },
] satisfies Array<{ name: string; overrides: Partial<WebToolsSettings>; prefix?: number; expected: string[] }>) {
	test(`provider candidates: ${name}`, () => {
		const settings: WebToolsSettings = { ...DEFAULT_SETTINGS, warnings: [], ...overrides, apiKeys: "apiKeys" in overrides ? overrides.apiKeys : {} };
		assert.deepEqual(resolveWebProviderCandidates("auto", settings, model).slice(0, prefix), expected);
	});
}
for (const { name, requested, overrides, expected } of [
	{ name: "explicit cookie provider", requested: "gemini", overrides: { browserCookieAccess: true }, expected: "gemini" },
	{ name: "automatic no-key provider", requested: "auto", overrides: {}, expected: "exa-mcp" },
	{ name: "native only", requested: "auto", overrides: { enabledProviders: ["openai-native"] }, expected: "openai-native" },
	{ name: "native disabled", requested: "auto", overrides: { enabledProviders: ["openai-native"], nativeOpenAiWebSearch: false }, expected: undefined },
] satisfies Array<{ name: string; requested: "auto" | "gemini"; overrides: Partial<WebToolsSettings>; expected: string | undefined }>) {
	test(`provider resolution: ${name}`, () => {
		assert.equal(resolveWebProvider(requested, { ...DEFAULT_SETTINGS, apiKeys: {}, warnings: [], ...overrides }, model).provider, expected);
	});
}
