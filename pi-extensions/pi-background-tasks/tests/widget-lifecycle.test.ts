import { expect, test } from "bun:test";
import { execFile, spawnSync, type ExecFileException } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";

// Peer mocks do not need downloads, which can consume the child's deadline.
const childArgs = (scenario: string, seconds: number) => ["--no-install", resolve(import.meta.dir, "fixtures/widget-lifecycle.ts"), scenario, String(seconds)];

const lifecycleCases = [
	["expiry-above", 15],
	["expiry-below", 15],
	["sibling", 15],
	["hide", 15],
	["shutdown", 15],
	["switch", 15],
	["boundary-before", 2_147_483.646],
	["boundary-at", 2_147_483.647],
	["thirty-days", 2_592_000],
	["overflow", 1e308],
] as const;

// Separate processes isolate peer mocks, the stack registry, settings and the clock
// from other suites that run real background tasks.
test("widget lifecycle scenarios", () => {
	expect.assertions(lifecycleCases.length + 1);
	expect(lifecycleCases.length).toBeGreaterThan(0);
	for (const [scenario, seconds] of lifecycleCases) {
		const root = resolve(import.meta.dir, "../../../tmp");
		mkdirSync(root, { recursive: true });
		const dir = mkdtempSync(resolve(root, "widget-lifecycle-"));
		try {
			const startedAt = Date.now();
			const result = spawnSync(process.execPath, childArgs(scenario, seconds), {
				cwd: dir,
				env: { ...process.env, PI_CODING_AGENT_DIR: dir, PI_BG_TASK_DIR: dir },
				encoding: "utf8",
				timeout: 10_000,
			});
			expect({ scenario, error: result.error?.message, status: result.status, stderr: result.stderr, stdout: result.stdout }).toEqual({
				scenario, error: undefined, status: 0, stderr: "", stdout: `widget lifecycle completed: ${scenario}\n`,
			});
			if (scenario === "expiry-above") console.log("widget timing:", JSON.stringify({ startedAt, finishedAt: Date.now(), phases: JSON.parse(readFileSync(resolve(dir, "widget-timing.json"), "utf8")) }));
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	}
}, lifecycleCases.length * 10_000);

test("widget startup completes with a stalled peer registry; removing the fix reaches the deadline", async () => {
	const root = resolve(import.meta.dir, "../../../tmp");
	mkdirSync(root, { recursive: true });
	const dir = mkdtempSync(resolve(root, "widget-registry-"));
	const requests: string[] = [];
	// Accept the download request but never answer it. No external network is used.
	const registry = createServer((request) => { requests.push(request.url!); });
	try {
		await new Promise<void>((ready) => registry.listen(0, "127.0.0.1", ready));
		const address = registry.address();
		if (!address || typeof address === "string") throw new Error("registry did not bind a TCP port");
		const args = childArgs("expiry-above", 15);
		for (const [kind, launchArgs] of [["fixed", args], ["control", args.slice(1)]] as const) {
			const home = resolve(dir, kind);
			mkdirSync(home);
			requests.length = 0;
			const startedAt = Date.now();
			const result = await new Promise<{ error: ExecFileException | null; stdout: string; stderr: string }>((done) => {
				execFile(process.execPath, launchArgs, {
					cwd: home, timeout: 10_000, encoding: "utf8",
					env: { ...process.env, HOME: home, BUN_INSTALL_CACHE_DIR: resolve(home, "cache"),
						BUN_CONFIG_REGISTRY: `http://127.0.0.1:${address.port}`, PI_CODING_AGENT_DIR: home, PI_BG_TASK_DIR: home },
				}, (error, stdout, stderr) => done({ error, stdout, stderr }));
			});
			const phases = JSON.parse(readFileSync(resolve(home, "widget-timing.json"), "utf8"));
			console.log("widget registry timing:", JSON.stringify({ kind, elapsedMs: Date.now() - startedAt, requests, phases }));
			if (kind === "fixed") {
				expect(result).toEqual({ error: null, stdout: "widget lifecycle completed: expiry-above\n", stderr: "" });
				expect(requests).toEqual([]);
			} else {
				expect(result.error?.killed).toBe(true);
				expect(result.error?.signal).toBe("SIGTERM");
				expect(requests).toContain("/@earendil-works%2fpi-coding-agent");
				expect(phases.map((phase: { phase: string }) => phase.phase)).toEqual(["entry"]);
			}
		}
	} finally {
		registry.closeAllConnections();
		await new Promise<void>((closed) => registry.close(() => closed()));
		rmSync(dir, { recursive: true, force: true });
	}
}, 30_000);
