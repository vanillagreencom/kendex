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
type Scenario = typeof providers[number] & { purpose: typeof purposes[number]; enabled: boolean; refuse?: boolean };
type ProbeResult = { outcome: string; requests: Array<{ path: string; body: Record<string, unknown> }> };

async function probe(row: Scenario): Promise<ProbeResult> {
	mkdirSync(scratch, { recursive: true });
	const root = mkdtempSync(join(scratch, "qol-gateway-"));
	const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "qol-gateway-privacy.probe.ts"), JSON.stringify(row)], {
		cwd: packageDir, env: { HOME: root, PI_CODING_AGENT_DIR: root }, stdout: "pipe", stderr: "pipe",
	});
	const deadline = setTimeout(() => child.kill(), 30_000);
	try {
		const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
		expect({ exitCode, stderr }).toEqual({ exitCode: 0, stderr: "" });
		return JSON.parse(stdout);
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
