import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const BRIDGE_BIN = resolve(dirname(fileURLToPath(import.meta.url)), "../../bin/pi-bridge.js");

export async function runCli(args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
	const child = spawn("node", [BRIDGE_BIN, ...args], { stdio: ["ignore", "pipe", "pipe"] });
	let stdout = "";
	let stderr = "";
	child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
	child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
	let expired = false;
	const deadline = setTimeout(() => { expired = true; child.kill("SIGKILL"); }, 5000);
	try {
		const code = await new Promise<number>((resolveProcess, rejectProcess) => {
			child.once("error", rejectProcess);
			child.once("close", (code) => resolveProcess(code ?? -1));
		});
		if (expired) throw new Error("CLI deadline exceeded");
		return { stdout, stderr, code };
	} finally {
		clearTimeout(deadline);
		if (child.exitCode === null && child.signalCode === null && child.pid !== undefined) {
			const closed = new Promise<void>((resolveClose) => child.once("close", () => resolveClose()));
			child.kill("SIGKILL");
			await closed;
		}
	}
}
