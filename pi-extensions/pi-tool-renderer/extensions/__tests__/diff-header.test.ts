import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("../../", import.meta.url));
const moduleRoot = join(packageRoot, "extensions/tool-renderer");

test("unterminated quoted Git header renders within the deadline; the old pattern fails", async () => {
	const node = Bun.which("node");
	if (!node) throw new Error("Node is required to test the renderer's runtime");
	const scratchRoot = resolve(packageRoot, "../../tmp");
	mkdirSync(scratchRoot, { recursive: true });
	const scratch = mkdtempSync(join(scratchRoot, "diff-header-"));
	try {
		cpSync(moduleRoot, join(scratch, "tool-renderer"), { recursive: true });
		symlinkSync(join(packageRoot, "node_modules"), join(scratch, "node_modules"), "dir");
		const modulePath = join(scratch, "tool-renderer/diff.ts");
		const source = readFileSync(modulePath, "utf8");
		const disjoint = String.raw`[^"\\]`;
		expect(source.split(disjoint).length - 1).toBe(1);
		const output = [
			'diff --git "a/' + "\\".repeat(64),
			"--- a/sample.txt",
			"+++ b/sample.txt",
			"@@ -1 +1 @@",
			"-old content",
			"+new content",
		].join("\n");
		const bundlePath = join(scratch, "diff.mjs");
		const bundle = async () => {
			const result = await Bun.build({ entrypoints: [modulePath], target: "node", packages: "external" });
			expect(result.success).toBe(true);
			expect(result.outputs.length).toBe(1);
			writeFileSync(bundlePath, await result.outputs[0]!.text());
		};
		const script = `
			import { renderBashDiffOutput } from ${JSON.stringify(bundlePath)};
			const theme = { bg: (_token, text) => text, fg: (_token, text) => text, bold: text => text };
			console.log("render-start");
			const rendered = renderBashDiffOutput(${JSON.stringify(output)}, theme, true, ${JSON.stringify(scratch)}, true);
			if (!rendered?.includes("new content")) throw new Error("Diff content was not rendered");
			console.log("render-done");
		`;
		// Node is Pi's runtime; a child deadline can kill a regex that blocks its event loop.
		const run = () => spawnSync(node, ["--input-type=module", "-e", script], {
			cwd: scratch,
			env: { HOME: scratch, PI_CODING_AGENT_DIR: join(scratch, "agent"), COLUMNS: "100" },
			encoding: "utf8",
			timeout: 2000,
			killSignal: "SIGKILL",
		});
		await bundle();
		const fixed = run();
		expect(fixed.error).toBeUndefined();
		expect(fixed.status).toBe(0);
		expect(fixed.stdout).toBe("render-start\nrender-done\n");

		const mutant = source.replace(disjoint, '[^"]');
		expect(mutant).not.toBe(source);
		writeFileSync(modulePath, mutant);
		await bundle();
		const old = run();
		expect(old.stdout).toBe("render-start\n");
		expect(old.error).toMatchObject({ code: "ETIMEDOUT" });
		expect(old.signal).toBe("SIGKILL");
	} finally {
		rmSync(scratch, { recursive: true, force: true });
	}
});