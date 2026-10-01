import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spyOn } from "bun:test";
import * as childProcess from "node:child_process";
import { rmSync } from "node:fs";
import { editAgentFrontmatterOverrides, showAgentEditConfirmation } from "../extensions/subagent/browser/frontmatter-editor.js";
import { assertAsyncManagedEdit, cleanupTempRuntimes, importRuntimeCopy, managedEditFixture } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("managed frontmatter save yields while refresh runs with its deadline", async () => {
	await assertAsyncManagedEdit({ editAgentFrontmatterOverrides });
});

test("managed refresh reports process failures and a missing rendered agent", async () => {
	const outputFirst = await importRuntimeCopy("browser/frontmatter-editor.ts",
		'return { ok: false, message: outputTail ? `${cause} Output: ${outputTail}` : cause };',
		'return { ok: false, message: (result.stderr || result.stdout || result.error.message).trim().split(/\\r?\\n/).slice(-4).join(" ") };') as typeof import("../extensions/subagent/browser/frontmatter-editor.js");
	// execFile produces an error for a failed start, nonzero exit, signal,
	// deadline or output overflow. No row invokes the real kendex executable.
	for (const [runtime, control] of [[{ editAgentFrontmatterOverrides, showAgentEditConfirmation }, false], [outputFirst, true]] as const) {
		await (control ? assert.rejects : assert.doesNotReject)(async () => {
			for (const [error, stdout, stderr, missing, expected] of [
				[Object.assign(new Error("fixture deadline"), { code: null, signal: "SIGKILL" as const, killed: true }),
					"fixture stdout", "warning 1\nwarning 2\nwarning 3\nwarning 4\nfixture refresh timeout output", false,
					["fixture deadline", "code=null", "signal=SIGKILL", "killed=true", "warning 2 warning 3 warning 4 fixture refresh timeout output"]],
				[new Error("ENOENT"), "", "", false, ["ENOENT"]],
				[Object.assign(new Error("exit 7"), { code: 7, signal: null, killed: false }), "", "fixture refresh failure", false,
					["exit 7", "code=7", "signal=null", "killed=false", "fixture refresh failure"]],
				[new Error("SIGTERM"), "", "", false, ["SIGTERM"]],
				[new Error("ERR_CHILD_PROCESS_STDIO_MAXBUFFER"), "", "", false, ["ERR_CHILD_PROCESS_STDIO_MAXBUFFER"]],
				[null, "", "", true, []],
			] as const) {
				const { config, ctx } = managedEditFixture();
				let confirmation = "";
				ctx.ui.notify = (message) => { confirmation = message; };
				const spy = spyOn(childProcess, "execFile").mockImplementation(((...args: unknown[]) => {
					const callback = args[3] as (error: childProcess.ExecFileException | null, stdout: string, stderr: string) => void;
					if (missing) rmSync(config.filePath);
					callback(error, stdout, stderr);
					return {} as childProcess.ChildProcess;
				}) as typeof childProcess.execFile);
				try {
					const result = await runtime.editAgentFrontmatterOverrides(ctx, config);
					if (result !== undefined) await runtime.showAgentEditConfirmation(ctx, result);
					assert.ok((missing ? [config.filePath] : expected).every((detail) => confirmation.includes(detail)), confirmation);
				} finally { spy.mockRestore(); }
			}
		}, { code: "ERR_ASSERTION" });
	}
});

test("main's synchronous refresh fails the asynchronous save assertion", async () => {
	const runtime = await importRuntimeCopy("browser/frontmatter-editor.ts", `const result = await new Promise<{ error: ExecFileException | null; stdout: string; stderr: string }>((resolve) => {
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
	});`, [{ before: 'import { execFile, type ExecFileException } from "node:child_process";', after: 'import { spawnSync } from "node:child_process";' }]) as typeof import("../extensions/subagent/browser/frontmatter-editor.js");
	await assert.rejects(() => assertAsyncManagedEdit(runtime), { code: "ERR_ASSERTION" });
});
