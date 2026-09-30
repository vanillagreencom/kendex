/**
 * Tests for Claude executable preflight diagnostics.
 * The checks do not require Claude Code to be installed; they use temp files
 * and the current Node executable as a known platform binary.
 */
import { chmodSync, closeSync, ftruncateSync, mkdtempSync, openSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { preflightClaudeExecutable, spawnClaudeCodeWithDiagnostics } from "../src/index.ts";

function withTempDir(fn) {
	const dir = mkdtempSync(join(tmpdir(), "claude-bridge-preflight-"));
	let cleanupNow = true;
	const cleanup = () => rmSync(dir, { recursive: true, force: true });
	try {
		const result = fn(dir);
		if (result && typeof result.then === "function") {
			cleanupNow = false;
			return result.finally(cleanup);
		}
		return result;
	} finally {
		if (cleanupNow) cleanup();
	}
}

describe("preflightClaudeExecutable", () => {
	it("accepts an existing executable shebang script", () => withTempDir((dir) => {
		const script = join(dir, "claude-wrapper");
		writeFileSync(script, "#!/bin/sh\nexit 0\n");
		chmodSync(script, 0o755);

		const result = preflightClaudeExecutable(script, dir);
		assert.equal(result.path, script);
		assert.equal(result.cwd, dir);
		assert.equal(result.fileType, "shebang-script");
	}));

	it("accepts the current Node executable as an existing platform binary", () => withTempDir((dir) => {
		const result = preflightClaudeExecutable(process.execPath, dir);
		assert.equal(result.path, process.execPath);
		assert.match(result.fileType, /^(elf|mach-o|pe)$/);
	}));

	it("classifies an executable past the whole-file read limit from its header", () => withTempDir((dir) => {
		// A sparse file: 3 GiB of size, no data blocks. Reading it whole fails
		// with ERR_FS_FILE_TOO_LARGE, so only a header read classifies it.
		const script = join(dir, "claude-large");
		writeFileSync(script, "#!/bin/sh\nexit 0\n");
		chmodSync(script, 0o755);
		const fd = openSync(script, "r+");
		try { ftruncateSync(fd, 3 * 1024 ** 3); } finally { closeSync(fd); }

		assert.equal(preflightClaudeExecutable(script, dir).fileType, "shebang-script");
	}));

	it("reuses the file type while the mtime holds and reclassifies once it moves", () => withTempDir((dir) => {
		const script = join(dir, "claude-wrapper");
		writeFileSync(script, "#!/bin/sh\nexit 0\n");
		chmodSync(script, 0o755);
		// Whole seconds, so setting the same mtime again reproduces it exactly.
		const atime = new Date(1_700_000_000_000);
		const mtime = new Date(1_700_000_000_000);
		utimesSync(script, atime, mtime);
		assert.equal(preflightClaudeExecutable(script, dir).fileType, "shebang-script");

		// Same mtime, new bytes: the memo answers, so the header is not read again.
		writeFileSync(script, "not an executable header\n");
		utimesSync(script, atime, mtime);
		assert.equal(preflightClaudeExecutable(script, dir).fileType, "shebang-script");

		// A moved mtime reads the header again.
		utimesSync(script, atime, new Date(mtime.getTime() + 5000));
		assert.throws(() => preflightClaudeExecutable(script, dir), (error) => {
			assert.equal(error.code, "ENOEXEC");
			assert.equal(error.fileType, "unknown");
			return true;
		});
	}));

	it("reports errno details for a non-existent executable path", () => withTempDir((dir) => {
		const missing = join(dir, "missing-claude");
		assert.throws(
			() => preflightClaudeExecutable(missing, dir),
			(error) => {
				assert.equal(error.name, "ClaudeExecutablePreflightError");
				assert.equal(error.code, "ENOENT");
				assert.equal(error.path, missing);
				assert.equal(error.cwd, dir);
				assert.equal(error.syscall, "stat");
				assert.match(error.message, /code=ENOENT/);
				assert.equal(typeof error.errno, "number");
				assert.match(error.message, /syscall=stat/);
				return true;
			},
		);
	}));

	it("reports errno details for a deleted cwd before checking the executable", () => withTempDir((dir) => {
		rmSync(dir, { recursive: true, force: true });
		assert.throws(
			() => preflightClaudeExecutable(process.execPath, dir),
			(error) => {
				assert.equal(error.name, "ClaudeExecutablePreflightError");
				assert.equal(error.code, "ENOENT");
				assert.equal(error.path, dir);
				assert.equal(error.cwd, dir);
				assert.equal(error.syscall, "stat");
				assert.ok(error.message.includes(`cwd=${dir}`));
				return true;
			},
		);
	}));

	it("reports structured details when cwd is a file", () => withTempDir((dir) => {
		const fileCwd = join(dir, "not-a-directory");
		writeFileSync(fileCwd, "not a directory\n");
		assert.throws(
			() => preflightClaudeExecutable(process.execPath, fileCwd),
			(error) => {
				assert.equal(error.name, "ClaudeExecutablePreflightError");
				assert.equal(error.code, "ENOTDIR");
				assert.equal(error.path, fileCwd);
				assert.equal(error.cwd, fileCwd);
				assert.equal(error.syscall, "chdir");
				assert.ok(error.message.includes(`cwd=${fileCwd}`));
				return true;
			},
		);
	}));

	it("rewrites spawn ENOENT so SDK surfaces diagnostic context", async () => withTempDir(async (dir) => {
		const missing = join(dir, "missing-claude");
		const proc = spawnClaudeCodeWithDiagnostics({
			command: missing,
			args: [],
			cwd: dir,
			env: {},
			signal: new AbortController().signal,
		});
		const error = await new Promise((resolve) => proc.once("error", resolve));
		assert.equal(error.name, "ClaudeSpawnDiagnosticError");
		assert.equal(error.code, "CLAUDE_BRIDGE_SPAWN_FAILED");
		assert.equal(error.originalCode, "ENOENT");
		assert.match(error.originalMessage, /ENOENT/);
		assert.equal(error.path, missing);
		assert.equal(error.cwd, dir);
		assert.match(error.message, /code=ENOENT/);
		assert.match(error.syscall, /^spawn /);
		assert.notEqual(error.cause, error);
		assert.doesNotThrow(() => JSON.stringify(error));
		assert.doesNotMatch(error.stack ?? "", /wrapClaudeSpawnErrorForSdk/);
	}));
});
