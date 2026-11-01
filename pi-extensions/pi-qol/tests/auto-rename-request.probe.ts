// Plain Bun child: the package test preload does not replace Pi's real SDKs.
// Pi's own model registry resolves the stored GitHub Copilot login; the
// provider SDKs send through the global fetch, which records each request.
import { ModelRegistry, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/qol/package-config.ts";
import { generateAutoRenameName } from "../extensions/qol/session-rename.ts";

interface Scenario {
	model: string;
	token: string;
}

const rows: Scenario[] = JSON.parse(process.argv[2]!);
const root = process.env.PI_CODING_AGENT_DIR!;
let requests: Array<{ url: string; body: Record<string, unknown> }> = [];

globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
	const request = new Request(input, init);
	requests.push({ url: request.url, body: await request.json() as Record<string, unknown> });
	return Response.json({ error: { message: "fixture refusal", type: "invalid_request_error" } }, { status: 400 });
}) as typeof fetch;

const results = [];
for (const row of rows) {
	requests = [];
	const authPath = join(root, "auth.json");
	writeFileSync(authPath, JSON.stringify({ "github-copilot": { type: "oauth", access: row.token, refresh: "fixture-refresh", expires: Date.now() + 24 * 60 * 60 * 1000 } }));
	writeFileSync(join(root, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": {
		"sessionAutoRename.model": row.model,
		"sessionAutoRename.fallbackModel": "",
	} } } } }));
	clearPackageConfigCache();
	const runtime = await ModelRuntime.create({ authPath, modelsPath: null, refreshOnCreate: false });
	const ctx = { cwd: root, hasUI: false, model: undefined, modelRegistry: new ModelRegistry(runtime), ui: { notify() {} } };
	await generateAutoRenameName("Fix the flaky login test", ctx as any);
	results.push({ requests });
}
console.log(JSON.stringify(results));
