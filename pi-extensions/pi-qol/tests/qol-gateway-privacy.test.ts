import { expect, test } from "bun:test";
import { AssertionError, deepStrictEqual } from "node:assert";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

// Inputs: extensions/qol/{compaction,handoff,session-rename,gateway-privacy}.ts,
// the installed Pi SDKs, and qol-gateway-privacy.probe.ts. The plain child runs
// real QOL calls through Pi's real provider conversion and a local HTTP server.
const packageDir = resolve(import.meta.dir, "..");
const scratch = resolve(packageDir, "../../tmp");
const providers = [
	{ provider: "openrouter", api: "openai-completions" as const },
	{ provider: "vercel-ai-gateway", api: "anthropic-messages" as const },
];
const purposes = ["compaction", "branch-summary", "session-search", "handoff", "auto-name"] as const;
type Scenario = typeof providers[number] & { purpose: typeof purposes[number] | "compact-handler" | "tree-handler"; enabled: boolean; refuse?: boolean; qolSummaries?: boolean; hasUI?: boolean; notify?: boolean; budgetGuard?: boolean; artifactEnabled?: boolean };
type Diagnostic = { source: string; level: string; message: string };
type ProbeResult = {
	outcome: string;
	result?: { cancel?: boolean; compaction?: { summary: string; details: { handoffArtifact?: string; handoffArtifactLatest?: string } }; summary?: { summary: string } };
	notices: Array<{ level: string; message: string }>;
	diagnostics: Diagnostic[];
	artifacts: string[];
	requests: Array<{ path: string; body: Record<string, unknown> }>;
};

async function probe(row: Scenario): Promise<ProbeResult> {
	mkdirSync(scratch, { recursive: true });
	const root = mkdtempSync(join(scratch, "qol-gateway-"));
	const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "qol-gateway-privacy.probe.ts"), JSON.stringify(row)], {
		cwd: packageDir, env: { HOME: root, PI_CODING_AGENT_DIR: root }, stdout: "pipe", stderr: "pipe",
	});
	const deadline = setTimeout(() => child.kill(), 30_000);
	try {
		const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
		expect(exitCode).toBe(0);
		// Headless Pi callers consume the JSON diagnostic on stderr. Provider
		// error codes come from the HTTP response, not QOL's human copy.
		const diagnostics: Diagnostic[] = stderr.trim() ? stderr.trim().split("\n").map((line) => JSON.parse(line)) : [];
		return { ...JSON.parse(stdout), diagnostics };
	} finally {
		clearTimeout(deadline);
		await child.exited;
		rmSync(root, { recursive: true });
	}
}

function assertPrivacy(row: Scenario, response: ProbeResult): void {
	expect(response.requests.length).toBeGreaterThan(0);
	for (const request of response.requests) {
		expect(request.path).toBe(row.api === "openai-completions" ? "/v1/chat/completions" : "/v1/messages");
		expect(JSON.stringify(request.body.messages)).toContain("private fixture conversation");
		if (row.provider === "openrouter") deepStrictEqual(request.body.provider, { order: ["fixture-provider"], zdr: true, data_collection: "deny" });
		else deepStrictEqual(request.body.providerOptions, { gateway: { zeroDataRetention: true, disallowPromptTraining: true } });
	}
}

const rows: Scenario[] = providers.flatMap((provider) => purposes.map((purpose) => ({ ...provider, purpose, enabled: true })));
rows.push({ ...providers[0], purpose: "compaction", enabled: true, refuse: true });

for (const row of rows) {
	test(`real QOL gateway request: ${row.provider} ${row.purpose} refusal=${row.refuse ?? false}`, async () => {
		const result = await probe(row);
		expect(result.outcome).toBe(row.refuse ? "error" : "completed");
		assertPrivacy(row, result);
		if (!row.refuse) {
			const off = await probe({ ...row, enabled: false });
			expect(off.outcome).toBe("completed");
			expect(() => assertPrivacy(row, off)).toThrow(AssertionError);
		}
	}, 90_000);
}

test("a QOL direct-provider summary ignores the main agent's gateway", async () => {
	const result = await probe({ provider: "openai", api: "openai-completions", purpose: "compaction", enabled: true });
	expect(result.outcome).toBe("completed");
	expect(result.requests.length).toBeGreaterThan(0);
	for (const request of result.requests) expect({ provider: request.body.provider, providerOptions: request.body.providerOptions }).toEqual({ provider: undefined, providerOptions: undefined });
}, 30_000);

// The session handlers run where Pi would otherwise send its own summary to the
// session model with no payload callback (the probe's context model).
const handlerRows: Array<Scenario & { expected: "summary" | "cancel" | "fallback" | "native" }> = [
	...providers.flatMap((provider) => (["compact-handler", "tree-handler"] as const).map((purpose) => ({ ...provider, purpose, enabled: true, expected: "summary" as const }))),
	{ ...providers[0], purpose: "compact-handler", enabled: true, refuse: true, expected: "cancel" },
	{ ...providers[1], purpose: "tree-handler", enabled: true, refuse: true, expected: "cancel" },
	{ ...providers[0], purpose: "compact-handler", enabled: false, refuse: true, qolSummaries: true, expected: "fallback" },
	{ ...providers[1], purpose: "tree-handler", enabled: false, refuse: true, qolSummaries: true, expected: "fallback" },
	{ ...providers[0], purpose: "compact-handler", enabled: false, expected: "native" },
	{ ...providers[1], purpose: "tree-handler", enabled: false, expected: "native" },
	...providers.flatMap((provider) => (["compact-handler", "tree-handler"] as const).flatMap((purpose) => [
		{ ...provider, purpose, enabled: true, refuse: true, hasUI: false, notify: true, expected: "cancel" as const },
		{ ...provider, purpose, enabled: true, refuse: true, hasUI: false, notify: false, expected: "cancel" as const },
		{ ...provider, purpose, enabled: true, refuse: true, hasUI: true, notify: false, expected: "cancel" as const },
	])),
	...[
		{ qolSummaries: true },
		{ budgetGuard: true },
		{ qolSummaries: true, artifactEnabled: false },
		{ budgetGuard: true, artifactEnabled: false },
	].map((options) => ({ ...providers[0], purpose: "compact-handler" as const, enabled: true, expected: "summary" as const, ...options })),
];

for (const row of handlerRows) {
	test(`QOL session handler: ${JSON.stringify(row)}`, async () => {
		const response = await probe(row);
		expect(response.outcome).toBe("completed");
		if (row.expected === "native") {
			expect({ result: response.result, requests: response.requests }).toEqual({ result: undefined, requests: [] });
			return;
		}
		const errors = [...response.notices, ...response.diagnostics].filter((notice) => notice.level === "error");
		expect(errors.length).toBe(row.expected === "summary" ? 0 : 1);
		if (row.expected === "cancel") {
			expect(errors[0].message).toContain("no_providers_available");
			if (row.hasUI === false) {
				expect(response.notices).toEqual([]);
				expect(response.diagnostics[0]).toMatchObject({ source: "pi-qol", level: "error" });
			} else expect(response.diagnostics).toEqual([]);
		}
		if (row.expected === "fallback") {
			expect(response.result).toBeUndefined();
			expect(() => assertPrivacy(row, response)).toThrow(AssertionError);
			return;
		}
		assertPrivacy(row, response);
		if (row.expected === "cancel") expect(response.result).toEqual({ cancel: true });
		else {
			expect(row.purpose === "compact-handler" ? response.result?.compaction?.summary : response.result?.summary?.summary).toBe("Private session summary");
			const writesArtifact = row.purpose === "compact-handler" && (row.qolSummaries || row.budgetGuard) && row.artifactEnabled !== false;
			if (writesArtifact) {
				expect(response.artifacts).toContain("pi-qol/handoff/latest.json");
				expect(response.artifacts.some((path) => path !== "pi-qol/handoff/latest.json")).toBe(true);
				expect(response.result?.compaction?.details.handoffArtifact).toBeString();
				expect(response.result?.compaction?.details.handoffArtifactLatest).toBeString();
			} else {
				expect(response.artifacts).toEqual([]);
				expect(response.result?.compaction?.details.handoffArtifact).toBeUndefined();
				expect(response.result?.compaction?.details.handoffArtifactLatest).toBeUndefined();
			}
		}
	}, 30_000);
}
