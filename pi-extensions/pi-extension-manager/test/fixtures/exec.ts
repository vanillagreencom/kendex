import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

type Exec = ExtensionAPI["exec"];

export function testPi(exec: Exec = async () => ({ code: 0, killed: false, stdout: "", stderr: "" })): ExtensionAPI {
	return { exec } as ExtensionAPI;
}

export function sandboxExec(env: NodeJS.ProcessEnv): Exec {
	return (command, args, options) => new Promise((resolve, reject) => {
		const child = spawn(command, args, { cwd: options?.cwd, env, signal: options?.signal });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => { stdout += chunk; });
		child.stderr.on("data", (chunk) => { stderr += chunk; });
		child.on("error", reject);
		child.on("close", (code, signal) => resolve({ code: code ?? 1, killed: signal !== null, stdout, stderr }));
	});
}
