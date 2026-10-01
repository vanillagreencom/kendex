import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mock } from "bun:test";
import { spawn } from "node:child_process";
import { piUserDir } from "../../extensions/manager/package-config.ts";

// Unit tests own a neutral Pi host. Real-SDK tests use an isolated child instead.
mock.module("@earendil-works/pi-coding-agent", () => ({ getAgentDir: piUserDir, SettingsManager: class {}, getShellConfig: () => ({ shell: "sh", args: ["-c"] }) }));

type Exec = ExtensionAPI["exec"];

export function testPi(exec: Exec = async () => ({ code: 0, killed: false, stdout: "", stderr: "" })): ExtensionAPI {
	return { exec: async (_shell, argv, options) => {
		const [flag, script, proof, command, ...args] = argv;
		if (flag !== "-c" || script !== '"$@" && printf "\\n%s\\n" "$0"' || !proof?.startsWith("pi-manager-complete:") || !command) throw new Error("exec-fixture: unexpected completion protocol");
		const result = await exec(command, args, options);
		return result.code === 0 && !result.killed ? { ...result, stdout: `${result.stdout}\n${proof}\n` } : result;
	} } as ExtensionAPI;
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
