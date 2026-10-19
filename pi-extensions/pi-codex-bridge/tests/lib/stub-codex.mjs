// A stand-in `codex` executable written into a test's scratch directory: it
// answers `--version` with the given version and, as `app-server`, records
// its pid, optionally answers the handshake and `model/list`, ignores SIGTERM,
// or starts a helper in its own process group that outlives stdin EOF, the
// way Codex starts a stdio MCP server.
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export function writeStubCodex(dir, { version = "0.163.0", answer = true, ignoreTerm = false, helper = false } = {}) {
	const path = join(dir, "codex");
	const source = `#!${process.execPath}
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
const dir = ${JSON.stringify(dir)};
if (process.argv.includes("--version")) {
	process.stdout.write(${JSON.stringify(`codex-cli ${version}\n`)});
	process.exit(0);
}
appendFileSync(dir + "/app-server.pid", process.pid + "\\n");
if (${ignoreTerm}) process.on("SIGTERM", () => undefined);
if (${helper}) {
	const child = spawn(process.execPath, ["-e", "process.on('SIGTERM', () => undefined); process.stdin.resume(); setInterval(() => undefined, 1000); setTimeout(() => process.exit(0), 120000);"], { detached: true, stdio: ["pipe", "ignore", "ignore"] });
	appendFileSync(dir + "/helper.pid", child.pid + "\\n");
}
setTimeout(() => process.exit(0), 120000);
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (!${answer} || message.id === undefined) return;
	const result = message.method === "model/list" ? { data: [], nextCursor: null } : {};
	process.stdout.write(JSON.stringify({ id: message.id, result }) + "\\n");
});
`;
	writeFileSync(path, source);
	chmodSync(path, 0o755);
	return path;
}

/** The pids a stub recorded in `name`, once it has recorded any. */
export async function recordedPids(dir, name, deadlineMs = 5000) {
	const file = join(dir, name);
	const until = Date.now() + deadlineMs;
	while (!existsSync(file) || readFileSync(file, "utf8").trim() === "") {
		if (Date.now() > until) throw new Error(`no pid recorded in ${file}`);
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
	return readFileSync(file, "utf8").trim().split("\n").map(Number);
}

/** Whether `pid` still runs. A zombie has exited: it waits only for a parent
 * that may never reap it, such as a container's init. */
export function alive(pid) {
	try {
		process.kill(pid, 0);
	} catch (error) {
		if (error.code === "ESRCH") return false;
		throw error;
	}
	if (process.platform !== "linux") return true;
	try {
		const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
		return stat.slice(stat.lastIndexOf(")") + 2, stat.lastIndexOf(")") + 3) !== "Z";
	} catch {
		return false;
	}
}

/** Wait until `pid` is gone, or report it alive at the deadline. */
export async function goneWithin(pid, deadlineMs = 5000) {
	const until = Date.now() + deadlineMs;
	while (alive(pid)) {
		if (Date.now() > until) return false;
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
	return true;
}
