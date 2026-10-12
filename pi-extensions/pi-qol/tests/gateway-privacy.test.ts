import { afterEach, beforeEach, expect, test } from "bun:test";
import { AssertionError, deepStrictEqual } from "node:assert";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import qol from "../extensions/qol.ts";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { makeCtx, makeFakeApi } from "./fake-pi.ts";

// Inputs: QOL's registered request handler, package settings reader, and the
// kendex project's committed .pi/settings.json. No provider transport is faked.
const repo = resolve(import.meta.dir, "../../..");
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
let workdir = "";

beforeEach(() => {
	mkdirSync(join(repo, "tmp"), { recursive: true });
	workdir = mkdtempSync(join(repo, "tmp", "gateway-privacy-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	clearPackageConfigCache();
});

afterEach(() => {
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	clearPackageConfigCache();
	rmSync(workdir, { recursive: true });
});

function writeSetting(enabled: boolean | undefined): void {
	writeFileSync(join(workdir, "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": enabled === undefined ? {} : { "gatewayPrivacy.enabled": enabled } } } },
	}));
	clearPackageConfigCache();
}

const body = { model: "gateway/model", messages: [{ role: "user", content: "hello" }], max_tokens: 64 };
const openrouterFields = { provider: { zdr: true, data_collection: "deny" } };
const vercelFields = { providerOptions: { gateway: { zeroDataRetention: true, disallowPromptTraining: true } } };

interface Row {
	name: string;
	provider: string;
	api?: string;
	enabled?: boolean;
	caller?: Record<string, unknown>;
	expected?: Record<string, unknown>;
	projectTrusted?: boolean;
}

const rows: Row[] = [
	...(["openai-completions", "anthropic-messages"].flatMap((api): Row[] => [
		{ name: "OpenRouter adds controls", provider: "openrouter", api, enabled: true, expected: openrouterFields },
		{ name: "Vercel adds controls", provider: "vercel-ai-gateway", api, enabled: true, expected: vercelFields },
	])),
	{
		name: "OpenRouter strengthens weaker controls and keeps routing",
		provider: "openrouter", enabled: true,
		caller: { provider: { order: ["anthropic"], allow_fallbacks: false, zdr: false, data_collection: "allow" } },
		expected: { provider: { order: ["anthropic"], allow_fallbacks: false, zdr: true, data_collection: "deny" } },
	},
	{
		name: "Vercel strengthens weaker controls and keeps all option namespaces",
		provider: "vercel-ai-gateway", enabled: true,
		caller: { providerOptions: { anthropic: { thinking: { type: "enabled" } }, gateway: { order: ["bedrock"], zeroDataRetention: false, disallowPromptTraining: false } } },
		expected: { providerOptions: { anthropic: { thinking: { type: "enabled" } }, gateway: { order: ["bedrock"], zeroDataRetention: true, disallowPromptTraining: true } } },
	},
	...(["openrouter", "vercel-ai-gateway"].flatMap((provider): Row[] => [
		{ name: "setting off", provider, enabled: false, caller: { provider: { order: ["anthropic"] }, providerOptions: { gateway: { order: ["bedrock"] } } } },
		{ name: "portable default off", provider },
	])),
	...(["anthropic", "openai", "google"].map((provider): Row => ({ name: "direct provider unchanged", provider, enabled: true }))),
	{ name: "trusted kendex project enables controls", provider: "openrouter", enabled: false, projectTrusted: true, expected: openrouterFields },
	{ name: "untrusted kendex project cannot enable controls", provider: "vercel-ai-gateway", enabled: false, projectTrusted: false },
];

for (const row of rows) {
	test(`${row.name}: ${row.provider} ${row.api ?? ""}`, async () => {
		writeSetting(row.enabled);
		const fake = makeFakeApi();
		qol(fake.api);
		const ctx = makeCtx({
			cwd: row.projectTrusted === undefined ? workdir : repo,
			isProjectTrusted: () => row.projectTrusted === true,
			model: { provider: row.provider, api: row.api ?? "anthropic-messages", id: body.model },
		});
		const payload = structuredClone({ ...body, ...row.caller });
		const original = structuredClone(payload);
		const handler = fake.handlers.before_provider_request!;
		const result = await handler({ type: "before_provider_request", payload }, ctx);
		const expected = row.expected ? { ...body, ...row.expected } : original;
		deepStrictEqual(result ?? payload, expected);
		expect(payload).toEqual(original);
		if (!row.expected) expect(result).toBeUndefined();
		else if (row.projectTrusted === undefined) {
			// Disable the registered handler through its real setting. The same
			// gateway assertion must reject the resulting unchanged request.
			writeSetting(false);
			const off = await handler({ type: "before_provider_request", payload }, ctx);
			expect(off).toBeUndefined();
			expect(() => deepStrictEqual(off ?? payload, expected)).toThrow(AssertionError);
		}
	});
}
