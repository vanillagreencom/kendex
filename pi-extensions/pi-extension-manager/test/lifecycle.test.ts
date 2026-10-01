import { expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { isolatedHost } from "./fixtures/isolated-host.ts";

// Each child has an explicit host and empty settings. No bootstrap dependency discovery.
test("registered lifecycle handlers keep headless startup empty and cancel shutdown resources", async () => {
	const scratch = join(process.cwd(), "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "manager-lifecycle-")));
	try {
		const source = join(root, "extensions");
		cpSync(join(import.meta.dir, "../extensions"), source, { recursive: true });
		isolatedHost(source);
		const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "fixtures/lifecycle.ts"), source, root], {
			env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: join(root, "agent") },
			stdout: "pipe", stderr: "pipe", timeout: 10_000,
		});
		const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
		expect({ status, stdout, stderr }).toEqual({ status: 0, stdout: "", stderr: "" });
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}, 15_000);
