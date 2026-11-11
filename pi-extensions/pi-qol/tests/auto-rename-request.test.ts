import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

// Inputs: extensions/qol/{session-rename,pi-ai-compat}.ts, the installed Pi
// SDKs, and auto-rename-request.probe.ts. The plain child runs the naming
// request through Pi's real model registry, Copilot login and provider SDKs.
const packageDir = resolve(import.meta.dir, "..");
const scratch = resolve(packageDir, "../../tmp");
// A Copilot token names its API host in `proxy-ep`; Pi's agent path sends there.
const enterpriseToken = "tid=fixture;exp=9999999999;proxy-ep=proxy.enterprise.githubcopilot.com;";
const enterpriseOrigin = "https://api.enterprise.githubcopilot.com";

const rows = [
	{
		name: "a model that cannot turn reasoning off gets its lowest effort",
		model: "github-copilot/gpt-5.3-codex",
		expected: { origin: enterpriseOrigin, reasoningEffort: "low", thinking: null },
	},
	{
		name: "a model that can turn reasoning off gets it off",
		model: "github-copilot/claude-haiku-4.5",
		expected: { origin: enterpriseOrigin, reasoningEffort: null, thinking: "disabled" },
	},
];

if (rows.length === 0) throw new Error("Auto-rename request table is empty");

type ProbeResult = Array<{ requests: Array<{ url: string; body: { reasoning?: { effort?: string }; thinking?: { type?: string } } }> }>;

async function probe(): Promise<ProbeResult> {
	mkdirSync(scratch, { recursive: true });
	const root = mkdtempSync(join(scratch, "qol-auto-rename-request-"));
	const scenarios = rows.map((row) => ({ model: row.model, token: enterpriseToken }));
	const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "auto-rename-request.probe.ts"), JSON.stringify(scenarios)], {
		cwd: packageDir, env: { HOME: root, PI_CODING_AGENT_DIR: root }, stdout: "pipe", stderr: "pipe",
	});
	const deadline = setTimeout(() => child.kill(), 30_000);
	try {
		const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
		if (exitCode !== 0) throw new Error(`auto-rename request probe exited ${exitCode}: ${stderr}`);
		return JSON.parse(stdout);
	} finally {
		clearTimeout(deadline);
		await child.exited;
		rmSync(root, { recursive: true });
	}
}

let results: Promise<ProbeResult> | undefined;

rows.forEach((row, index) => {
	test(`auto-rename request on a Copilot enterprise login: ${row.name}`, async () => {
		expect.hasAssertions();
		results ??= probe();
		const { requests } = (await results)[index]!;
		expect(requests.map((request) => ({
			origin: new URL(request.url).origin,
			reasoningEffort: request.body.reasoning?.effort ?? null,
			thinking: request.body.thinking?.type ?? null,
		}))).toEqual([row.expected]);
	}, 40_000);
});
