import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spyOn } from "bun:test";
import * as childProcess from "node:child_process";
import { rmSync } from "node:fs";
import { editAgentFrontmatterOverrides } from "../extensions/subagent/browser/frontmatter-editor.js";
import { assertAsyncManagedEdit, cleanupTempRuntimes, importRuntimeCopy, managedEditFixture } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("managed frontmatter save yields while refresh runs with its deadline", async () => {
	await assertAsyncManagedEdit({ editAgentFrontmatterOverrides });
});

test("managed refresh reports process failures and a missing rendered agent", async () => {
	// execFile produces an error for a failed start, nonzero exit, signal,
	// deadline or output overflow. No row invokes the real kendex executable.
	for (const [cause, stderr, missing] of [
		["ENOENT", "", false],
		["exit 7", "fixture refresh failure", false],
		["SIGTERM", "", false],
		["SIGKILL timeout", "", false],
		["ERR_CHILD_PROCESS_STDIO_MAXBUFFER", "", false],
		["", "", true],
	] as const) {
		const { config, ctx } = managedEditFixture();
		const spy = spyOn(childProcess, "execFile").mockImplementation(((...args: unknown[]) => {
			const callback = args[3] as (error: Error | null, stdout: string, stderr: string) => void;
			if (missing) rmSync(config.filePath);
			callback(cause ? new Error(cause) : null, "", stderr);
			return {} as childProcess.ChildProcess;
		}) as typeof childProcess.execFile);
		try {
			const result = await editAgentFrontmatterOverrides(ctx, config);
			assert.ok(result?.includes(missing ? config.filePath : stderr || cause));
		} finally { spy.mockRestore(); }
	}
});

test("main's synchronous refresh fails the asynchronous save assertion", async () => {
	const runtime = await importRuntimeCopy("browser/frontmatter-editor.ts", `const result = await new Promise<{ error: Error | null; stdout: string; stderr: string }>((resolve) => {
		execFile("kendex", ["refresh", "--scope", "project"], {
			cwd: projectRoot,
			encoding: "utf-8",
			timeout: 120_000,
			killSignal: "SIGKILL",
			maxBuffer: 1024 * 1024,
		}, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
	});`, `const result = spawnSync("kendex", ["refresh", "--scope", "project"], {
		cwd: projectRoot,
		encoding: "utf-8",
		timeout: 120_000,
	});`, [{ before: 'import { execFile } from "node:child_process";', after: 'import { spawnSync } from "node:child_process";' }]) as typeof import("../extensions/subagent/browser/frontmatter-editor.js");
	await assert.rejects(() => assertAsyncManagedEdit(runtime), { code: "ERR_ASSERTION" });
});
