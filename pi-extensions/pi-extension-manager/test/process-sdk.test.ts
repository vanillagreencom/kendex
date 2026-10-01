import { expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { isolatedHost, installedPiRoot } from "./fixtures/isolated-host.ts";

test("real Pi SDK rejects npm heap crashes and preserves uninstall settings", async () => {
	const scratch = join(process.cwd(), "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "manager-sdk-")));
	try {
		const source = join(root, "extensions");
		cpSync(join(import.meta.dir, "../extensions"), source, { recursive: true });
		isolatedHost(source);
		const node = Bun.which("node");
		expect(node).not.toBeNull();
		const child = Bun.spawn([node!, join(import.meta.dir, "fixtures/process-sdk.mjs"), source, root, installedPiRoot()], {
			env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: join(root, "agent") },
			stdout: "pipe", stderr: "pipe", timeout: 10_000,
		});
		const [stdout, stderr, status] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
		expect({ status, stderr }).toEqual({ status: 0, stderr: "" });
		expect(JSON.parse(stdout)).toEqual({ npmSignal: expect.any(String), settingsPreserved: true });
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}, 15_000);
