import assert from "node:assert/strict";
import test from "node:test";
import { providerDisplayName, providerLabel } from "../src/utils/render.js";

for (const { label, provider, mode, expected } of [
	{ label: "Web Research", provider: "exa", mode: undefined, expected: "Web Research (Exa)" },
	{ label: "Web Research", provider: "exa", mode: "deep-lite", expected: "Web Research (Exa-Lite)" },
	{ label: "Web Research", provider: "exa", mode: "deep-reasoning", expected: "Web Research (Exa-Deep)" },
	{ label: "Web Search", provider: "openai-native", mode: undefined, expected: "Web Search (OpenAI Native)" },
	{ label: "Web Search", provider: "exa-mcp", mode: undefined, expected: "Web Search (Exa MCP)" },
	{ label: "Web Search", provider: "duckduckgo", mode: undefined, expected: "Web Search (DuckDuckGo)" },
]) {
	test(`provider label: ${provider}/${mode}`, () => assert.equal(providerLabel(label, provider, mode), expected));
}
for (const { provider, expected } of [
	{ provider: "http/auto", expected: "HTTP/Auto" },
	{ provider: "github", expected: "GitHub" },
	{ provider: "session", expected: "Session" },
	{ provider: "resolving…", expected: "Resolving…" },
	{ provider: "openai-codex", expected: "Codex" },
	{ provider: "gemini", expected: "Gemini" },
]) {
	test(`provider display: ${provider}`, () => assert.equal(providerDisplayName(provider), expected));
}
