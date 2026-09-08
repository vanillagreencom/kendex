import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

// Both shells use builtins until exec. The child never creates descendants.
const script = `
printf 'bash-ready\\n'
IFS= read -r release || exit 64
case "$release" in
  exec) exec /bin/sh -c 'printf "exec-ready\\n"; IFS= read -r release; test "$release" = exit' ;;
  exit) exit 0 ;;
  *) exit 64 ;;
esac
`;

async function beforeDeadline<T>(operation: Promise<T>, label: string): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([
			operation,
			new Promise<never>((_, reject) => {
				timer = setTimeout(() => reject(new Error(`identity child did not report ${label}`)), 3_000);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
}

/** Owns a shell that waits for an explicit exec or exit release. */
export function identityChild() {
	const child = spawn("/bin/bash", ["--noprofile", "--norc", "-c", script], {
		stdio: ["pipe", "pipe", "pipe"],
		env: { PATH: "/usr/bin:/bin", LC_ALL: "C" },
	});
	let spawnError: Error | undefined;
	child.on("error", (error) => { spawnError = error; });
	child.stdin.on("error", (error) => { spawnError = error; });
	const completed = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
		child.once("close", (code, signal) => resolve({ code, signal }));
	});
	const reader = createInterface({ input: child.stdout });
	const lines = reader[Symbol.asyncIterator]();
	return {
		child,
		async ready(expected: string) {
			const line = await beforeDeadline(Promise.race([
				lines.next(),
				completed.then(({ code, signal }) => {
					throw spawnError ?? new Error(`identity child closed before ${expected}: ${code ?? signal}`);
				}),
			]), expected);
			if (line.done || line.value !== expected) {
				throw spawnError ?? new Error(`identity child expected ${expected}, received ${line.value ?? "EOF"}`);
			}
		},
		async exited() {
			const { code, signal } = await beforeDeadline(completed, "exit");
			if (spawnError) throw spawnError;
			if (code !== 0 || signal !== null) throw new Error(`identity child exit failed: ${code ?? signal}`);
		},
		async dispose() {
			if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
			await completed;
			reader.close();
			child.stdin.destroy();
			child.stdout.destroy();
			child.stderr.destroy();
			if (spawnError) throw spawnError;
		},
	};
}
