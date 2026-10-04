import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { mutantExtensions, type SourceEdit } from "./fixtures/commands.ts";
import { isolatedHost } from "./fixtures/isolated-host.ts";

/** Run the lifecycle fixture in a fresh root against a copy of `extensions` with `edits` applied. */
async function runLifecycle(scratch: string, edits: SourceEdit[]): Promise<{ status: number; stdout: string; stderr: string }> {
	const root = realpathSync(mkdtempSync(join(scratch, "manager-lifecycle-")));
	try {
		const source = mutantExtensions(join(root, "extensions"), edits);
		isolatedHost(source);
		const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "fixtures/lifecycle.ts"), source, root], {
			env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: join(root, "agent") },
			stdout: "pipe", stderr: "pipe", timeout: 10_000,
		});
		const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
		return { status, stdout, stderr };
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}

// Each child has an explicit host and empty settings. No bootstrap dependency discovery.
test("registered lifecycle handlers keep headless startup empty and cancel shutdown resources; control: a shutdown handler that drops its promise", async () => {
	const scratch = join(process.cwd(), "tmp");
	mkdirSync(scratch, { recursive: true });
	expect(await runLifecycle(scratch, [])).toEqual({ status: 0, stdout: "", stderr: "" });
	const dropped = await runLifecycle(scratch, [{ file: "extension-manager.ts", before: 'pi.on("session_shutdown", () => closeInventorySession(pi));', after: 'pi.on("session_shutdown", () => { void closeInventorySession(pi); });' }]);
	expect({ failed: dropped.status !== 0, waitAssertion: dropped.stderr.includes("lifecycle-shutdown-wait:") }).toEqual({ failed: true, waitAssertion: true });
}, 15_000);
