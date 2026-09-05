import { expect, test } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const root = join(process.cwd(), "tmp", "manager-bootstrap-tests");
const fixture = join(import.meta.dir, "fixtures", "bootstrap.ts");

test("runtime bootstrap registers host commands and recovery updates the global layer", async () => {
	mkdirSync(root, { recursive: true });
	try {
		for (const kind of ["pi", "omp"]) {
			for (const mode of ["enabled", "disabled"]) {
				const home = join(root, `${kind}-${mode}`);
				const child = Bun.spawn([process.execPath, fixture, home, kind, mode], {
					stdout: "ignore", stderr: "pipe", timeout: 10_000,
					env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: join(home, "agent") },
				});
				const stderr = await new Response(child.stderr).text();
				const status = await child.exited;
				expect({ kind, mode, status, stderr }).toEqual({ kind, mode, status: 0, stderr: "" });
			}
		}
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}, 45_000);
