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
`], { encoding: "utf8", env });
	if (child.status !== 0) throw new Error(child.stderr);
	return child.stdout;
}

describe("background-task sidecar root", () => {
	test("a blank, relative or tilde override lands under the person's own home", () => {
		const home = mkdtempSync(join(tmpdir(), "pi-bg-home-"));
		const absolute = mkdtempSync(join(tmpdir(), "pi-bg-absolute-"));
		try {
			const fallback = join(home, ".pi", "agent");
			for (const override of [undefined, "", "   ", "relative/agent"]) {
				expect(sidecarRoot(home, override), `override ${JSON.stringify(override)}`).toBe(fallback);
			}
			expect(sidecarRoot(home, "~")).toBe(home);
			expect(sidecarRoot(home, "~/elsewhere")).toBe(join(home, "elsewhere"));
			// The control: an absolute override is taken as given, which is the
			// only shape the rest of this package's suites exercise.
			expect(sidecarRoot(home, absolute)).toBe(absolute);
		} finally {
			for (const dir of [home, absolute]) rmSync(dir, { recursive: true, force: true });
		}
	});
});
