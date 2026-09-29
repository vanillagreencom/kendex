import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PROJECT_LOCK_FILE } from "../extensions/config.ts";

/** `projectRoot` under a given HOME, in a child because homedir() reads the
 * process's own environment. */
function projectRootUnder(home: string, cwd: string): string | null {
	const child = spawnSync(process.execPath, ["-e", `
import { projectRoot } from ${JSON.stringify(join(import.meta.dir, "..", "extensions", "config.ts"))};
process.stdout.write(JSON.stringify(projectRoot(process.argv[1]) ?? null));
`, cwd], { encoding: "utf8", env: { PATH: process.env.PATH ?? "", HOME: home } });
	if (child.status !== 0) throw new Error(child.stderr);
	return JSON.parse(child.stdout) as string | null;
}

// The directory above home carries markers, the way a real home does when
// TMPDIR sits inside it. The walk stops at home, so neither those markers nor
// a lock beside them answers; a lock at home does, as the renderer's own walk
// has it.
test("the walk stops at home, and a home lock answers", () => {
	const outer = realpathSync(mkdtempSync(join(tmpdir(), "nested-agents-md-home-")));
	try {
		const home = join(outer, "home");
		mkdirSync(join(outer, ".claude"));
		mkdirSync(join(outer, ".agents"));
		mkdirSync(join(home, ".pi"), { recursive: true });
		mkdirSync(join(home, "notes"));
		expect(projectRootUnder(home, join(home, "notes"))).toBeNull();
		expect(projectRootUnder(home, home)).toBeNull();

		writeFileSync(join(outer, PROJECT_LOCK_FILE), "{}\n");
		expect(projectRootUnder(home, join(home, "notes"))).toBeNull();

		writeFileSync(join(home, PROJECT_LOCK_FILE), "{}\n");
		expect(projectRootUnder(home, join(home, "notes"))).toBe(home);
	} finally {
		rmSync(outer, { recursive: true, force: true });
	}
});
