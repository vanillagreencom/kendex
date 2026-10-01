import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const PACKAGE_COMMAND_TIMEOUT_MS = 60_000;
export const NPM_ROOT_TIMEOUT_MS = 4_000;

export type CommandResult =
	| { ok: true; stdout: string; stderr: string }
	| { ok: false; cause: "timeout" | "cancelled" | "launch" | "exit"; detail: string };

/** Execute through the host SDK. Bound delivery even if a child ignores its kill signal. */
export async function runCommand(pi: Pick<ExtensionAPI, "exec">, command: string, args: string[], options: { cwd?: string; signal: AbortSignal; timeout: number }): Promise<CommandResult> {
	const controller = new AbortController();
	let timer: ReturnType<typeof setTimeout> | undefined;
	let cancel = () => {};
	const interrupted = new Promise<CommandResult>((resolve) => {
		cancel = () => {
			controller.abort();
			resolve({ ok: false, cause: "cancelled", detail: "Command cancelled." });
		};
		options.signal.addEventListener("abort", cancel, { once: true });
		if (options.signal.aborted) cancel();
		timer = setTimeout(() => {
			controller.abort();
			resolve({ ok: false, cause: "timeout", detail: `Command exceeded ${options.timeout} ms.` });
		}, options.timeout);
	});
	try {
		if (options.signal.aborted) return await interrupted;
		const execution = (async (): Promise<CommandResult> => {
			try {
				const result = await pi.exec(command, args, { ...options, signal: controller.signal });
				if (result.killed) return { ok: false, cause: options.signal.aborted ? "cancelled" : "timeout", detail: "Command was stopped." };
				if (result.code !== 0) return { ok: false, cause: "exit", detail: result.stderr.trim() || result.stdout.trim() || `exit ${result.code}` };
				return { ok: true, stdout: result.stdout, stderr: result.stderr };
			} catch (error) {
				return { ok: false, cause: "launch", detail: String(error) };
			}
		})();
		return await Promise.race([interrupted, execution]);
	} finally {
		clearTimeout(timer);
		options.signal.removeEventListener("abort", cancel);
	}
}
