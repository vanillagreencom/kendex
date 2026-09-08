import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/* The sidecar root under a given HOME and PI_CODING_AGENT_DIR. Both are the
 * process's own environment, so each case runs in a child. Every other suite in
 * this package sets an absolute override, which returns before the default root
 * or a tilde is ever reached — the path this covers, and the one that shipped a
 * ReferenceError for a missing `homedir` import. `persistSnapshots` catches
 * that and reports `sidecar: false`, so the state simply stops persisting. */
function sidecarRoot(home: string, override: string | undefined): string {
	const module = JSON.stringify(join(import.meta.dir, "..", "extensions", "persistence.ts"));
	const env: Record<string, string> = { ...process.env as Record<string, string>, HOME: home };
	if (override === undefined) delete env.PI_CODING_AGENT_DIR;
	else env.PI_CODING_AGENT_DIR = override;
	const child = spawnSync(process.execPath, ["-e", `
import { piUserDir } from ${module};
process.stdout.write(piUserDir());
`], { encoding: "utf8", env, timeout: 5_000, killSignal: "SIGKILL" });
	if (child.error) throw child.error;
	if (child.status !== 0) throw new Error(`sidecar-root child exited ${child.status ?? child.signal}: ${child.stderr}`);
	return child.stdout;
}

describe("background-task sidecar root", () => {
	test("resolves each override spelling to its exact sidecar root", () => {
		const home = mkdtempSync(join(tmpdir(), "pi-bg-home-"));
		const absolute = mkdtempSync(join(tmpdir(), "pi-bg-absolute-"));
		try {
			const fallback = join(home, ".pi", "agent");
			const rows: Array<{ name: string; override: string | undefined; expected: string }> = [
				{ name: "missing override", override: undefined, expected: fallback },
				{ name: "empty override", override: "", expected: fallback },
				{ name: "whitespace override", override: "   ", expected: fallback },
				{ name: "relative override", override: "relative/agent", expected: fallback },
				{ name: "home shorthand", override: "~", expected: home },
				{ name: "home-relative override", override: "~/elsewhere", expected: join(home, "elsewhere") },
				{ name: "absolute override", override: absolute, expected: absolute },
			];
			expect.assertions(rows.length + 1);
			expect(rows.length, "sidecar root table must contain cases").toBeGreaterThan(0);
			for (const { name, override, expected } of rows) {
				expect(sidecarRoot(home, override), name).toBe(expected);
			}
		} finally {
			for (const dir of [home, absolute]) rmSync(dir, { recursive: true, force: true });
		}
	});
});
