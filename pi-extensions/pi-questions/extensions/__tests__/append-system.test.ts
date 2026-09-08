import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const helper = new URL("../../scripts/append-system.mjs", import.meta.url);
const manifest = { name: "@test/questions", pi: { appendSystem: "instructions.md" } };

describe("append-system lifecycle", () => {
	test("reports each lifecycle refusal with its key, value and exit status", () => {
		for (const row of [
			{ name: "missing action", args: [], key: "action", value: null, status: 1 },
			{ name: "unknown action", args: ["other"], key: "action", value: "other", status: 1 },
			{ name: "missing manifest", args: ["install"], key: "package-read", value: "package", status: 0 },
			{ name: "missing declaration", args: ["install"], manifest: {}, key: "package-fields", value: "package", status: 0 },
			{ name: "unmanaged scope", args: ["install"], manifest, unmanaged: true, key: "scope", value: "package", status: 0 },
			{ name: "missing instructions", args: ["install"], manifest, key: "source-missing", value: "source", status: 0 },
			{ name: "empty instructions", args: ["install"], manifest, content: "  \n", key: "source-empty", value: "source", status: 0 },
		]) {
			const root = mkdtempSync(join(tmpdir(), "append-system-"));
			try {
				const pkg = row.unmanaged ? join(root, "unmanaged") : join(root, ".pi", "packages", "questions");
				mkdirSync(join(pkg, "scripts"), { recursive: true });
				const script = join(pkg, "scripts", "append-system.mjs");
				copyFileSync(helper, script);
				if (row.manifest !== undefined) writeFileSync(join(pkg, "package.json"), JSON.stringify(row.manifest));
				if (row.content !== undefined) writeFileSync(join(pkg, "instructions.md"), row.content);
				const result = spawnSync("node", [script, ...row.args], {
					encoding: "utf8",
					env: { ...process.env, PI_CODING_AGENT_DIR: join(root, "absent-pi") },
				});
				const value = row.value === "package" ? pkg : row.value === "source" ? join(pkg, "instructions.md") : row.value;
				expect({ status: result.status, record: result.stderr.split("\n")[0] }).toEqual({
					status: row.status,
					record: `append-system: ${row.key}=${JSON.stringify(value)}`,
				});
			} finally {
				rmSync(root, { recursive: true, force: true });
			}
		}
	});

	test("installs and removes the complete append-system block", () => {
		const root = mkdtempSync(join(tmpdir(), "append-system-"));
		try {
			const scope = join(root, ".pi");
			const pkg = join(scope, "packages", "questions");
			mkdirSync(join(pkg, "scripts"), { recursive: true });
			const script = join(pkg, "scripts", "append-system.mjs");
			copyFileSync(helper, script);
			writeFileSync(join(pkg, "package.json"), JSON.stringify(manifest));
			writeFileSync(join(pkg, "instructions.md"), "Fixture instructions.\n");
			const installed = spawnSync("node", [script, "install"], { encoding: "utf8" });
			expect({ status: installed.status, stderr: installed.stderr, content: readFileSync(join(scope, "APPEND_SYSTEM.md"), "utf8") }).toEqual({
				status: 0,
				stderr: "",
				content: "<!-- kendex:append-system @test/questions begin -->\nFixture instructions.\n<!-- kendex:append-system @test/questions end -->\n",
			});
			const removed = spawnSync("node", [script, "remove"], { encoding: "utf8" });
			expect({ status: removed.status, stderr: removed.stderr, exists: existsSync(join(scope, "APPEND_SYSTEM.md")) }).toEqual({
				status: 0, stderr: "", exists: false,
			});
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});
});
