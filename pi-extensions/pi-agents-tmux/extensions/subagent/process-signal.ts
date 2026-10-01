import type { ChildProcess } from "node:child_process";
import { stringifyError } from "./format.js";

/** Result of delivering a signal to a child or its process group. */
export interface SignalOutcome {
	error?: string;
	ok: boolean;
	signal: NodeJS.Signals;
	target: "child" | "process-group";
}

/** Signal the group first, then the child if the group signal fails. */
export function signalProcessGroupOrChild(proc: Pick<ChildProcess, "pid" | "kill">, signal: NodeJS.Signals): SignalOutcome[] {
	const outcomes: SignalOutcome[] = [];
	const pid = typeof proc.pid === "number" && proc.pid > 0 ? proc.pid : undefined;
	if (pid && process.platform !== "win32") {
		try {
			process.kill(-pid, signal);
			return [{ ok: true, signal, target: "process-group" }];
		} catch (error) {
			outcomes.push({ error: stringifyError(error), ok: false, signal, target: "process-group" });
		}
	}
	try {
		const ok = proc.kill(signal);
		outcomes.push({
			error: ok ? undefined : "proc.kill returned false",
			ok,
			signal,
			target: "child",
		});
	} catch (error) {
		outcomes.push({ error: stringifyError(error), ok: false, signal, target: "child" });
	}
	return outcomes;
}

