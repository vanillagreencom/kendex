import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Longest one provider request, from sending it to reading its last body byte, or one PDF helper run may take when its
 * caller names no deadline of its own. */
export const DEFAULT_DEADLINE_MS = 120_000;

/** The Pi API a helper runs through: `exec` kills the helper when the signal it is given aborts. */
export type PiExec = Pick<ExtensionAPI, "exec">;

/** Runs `run` under a signal that aborts when `parent` aborts, with the parent's reason, or once `timeoutMs` passes, with a
 * `TimeoutError` DOMException naming `what`. A fetch given that signal stops while it waits for headers and while its body is
 * read; a helper run through `runHelper` is killed. The timer and the parent listener are released when `run` settles. */
export async function withDeadline<T>(parent: AbortSignal | undefined, timeoutMs: number, what: string, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
	const controller = new AbortController();
	let timer: ReturnType<typeof setTimeout> | undefined;
	const onParentAbort = () => controller.abort(parent?.reason);
	if (parent?.aborted) {
		controller.abort(parent.reason);
	} else {
		parent?.addEventListener("abort", onParentAbort, { once: true });
		timer = setTimeout(() => controller.abort(new DOMException(`${what} exceeded its ${timeoutMs} ms deadline`, "TimeoutError")), timeoutMs);
		timer.unref?.();
	}
	try {
		return await run(controller.signal);
	} finally {
		if (timer !== undefined) clearTimeout(timer);
		parent?.removeEventListener("abort", onParentAbort);
	}
}

/** The sh script a POSIX helper runs under. Pi's exec reports a helper killed by a signal it did not send (a crash, an OOM
 * kill) as exit code 0; run as the script's child, that death becomes the script's exit code 128+N. The script passes Pi's
 * SIGTERM on to the helper and waits for it, so a deadline or a cancellation still kills the helper. */
const SIGNAL_EXIT_SCRIPT = `child=
stop=
trap 'stop=1; [ -n "$child" ] && kill -TERM "$child" 2>/dev/null' TERM
"$0" "$@" &
child=$!
[ -n "$stop" ] && kill -TERM "$child" 2>/dev/null
while :; do
	wait "$child"
	status=$?
	kill -0 "$child" 2>/dev/null || break
done
exit "$status"`;

/** The stdout of `command` run through Pi's exec under `signal`. A helper killed because the signal aborted rejects with the
 * signal's reason: the caller's cancellation, or the `withDeadline` TimeoutError. A nonzero exit rejects naming the helper,
 * its exit code and its stderr; on POSIX a helper that died by a signal exits 128+N, and one that is not installed exits 127.
 * Windows has no signal deaths, so the helper runs there without the script. */
export async function runHelper(pi: PiExec, command: string, args: string[], signal: AbortSignal): Promise<string> {
	signal.throwIfAborted();
	const result = process.platform === "win32"
		? await pi.exec(command, args, { signal })
		: await pi.exec("sh", ["-c", SIGNAL_EXIT_SCRIPT, command, ...args], { signal });
	if (result.killed) {
		signal.throwIfAborted();
		throw new Error(`helper-killed: ${command}\nPi killed the helper although its signal never aborted.`);
	}
	if (result.code !== 0) throw new Error(`${command} exited ${result.code}: ${result.stderr.trim() || "no stderr (failed before writing)"}`);
	return result.stdout;
}
