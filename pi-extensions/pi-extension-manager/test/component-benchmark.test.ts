import { expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { isolatedHost } from "./fixtures/isolated-host.ts";

const packageRoot = resolve(import.meta.dir, "..");
const repo = resolve(packageRoot, "..", "..");
const extensionPath = "pi-extensions/pi-extension-manager/extensions";
const fixture = join(import.meta.dir, "fixtures", "component-benchmark.ts");

// COMPONENT_BENCHMARK_BASE selects an immutable main revision for timing and a
// must-fail control. Normal CI needs no git history and checks current sources.
test("component benchmark bounds hot work with 18 packages and 20 completion/filter steps", async () => {
	const scratch = join(repo, "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "manager-component-benchmark-")));
	async function git(args: string[]): Promise<string> {
		const child = Bun.spawn(["git", "-C", repo, ...args], {
			env: { PATH: process.env.PATH, HOME: root }, stdout: "pipe", stderr: "pipe", timeout: 10_000,
		});
		const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
		expect({ status, stderr }).toEqual({ status: 0, stderr: "" });
		return stdout;
	}
	async function run(label: string, source: string, expectedStatus: "pass" | "control"): Promise<void> {
		isolatedHost(source);
		const home = join(root, label, "home");
		mkdirSync(home, { recursive: true });
		const child = Bun.spawn([process.execPath, "--no-install", fixture, source, home, "cached"], {
			env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: join(home, "agent") },
			stdout: "pipe", stderr: "pipe", timeout: 10_000,
		});
		const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
		if (expectedStatus === "pass") expect({ status, stderr }).toEqual({ status: 0, stderr: "" });
		else {
			expect(status).not.toBe(0);
			expect(stderr).toContain("benchmark-cache: inventory");
		}
		const result: Record<string, unknown> = JSON.parse(stdout.trim());
		expect(result.packages).toBe(18);
		expect(result.steps).toBe(20);
		for (const key of ["inventoryMs", "hotMs"]) {
			expect(typeof result[key]).toBe("number");
			expect(Number.isFinite(result[key])).toBe(true);
		}
		console.log(`component-benchmark: ${label} ${JSON.stringify(result)}`);
	}
	try {
		const branch = join(root, "branch", "extensions");
		cpSync(join(packageRoot, "extensions"), branch, { recursive: true });
		const base = process.env.COMPONENT_BENCHMARK_BASE;
		if (base !== undefined) {
			expect(base.length).toBeGreaterThan(0);
			const files = (await git(["ls-tree", "-r", "--name-only", base, "--", extensionPath])).trim().split("\n");
			expect(files.length).toBeGreaterThan(0);
			const main = join(root, "main", "extensions");
			for (const file of files) {
				expect(file.startsWith(`${extensionPath}/`)).toBe(true);
				const path = join(main, file.slice(extensionPath.length + 1));
				mkdirSync(dirname(path), { recursive: true });
				writeFileSync(path, await git(["show", `${base}:${file}`]));
			}
			await run("main", main, "control");
		}
		await run("branch", branch, "pass");
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}, 45_000);
