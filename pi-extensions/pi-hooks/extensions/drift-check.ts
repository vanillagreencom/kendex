import { accessSync, constants, statSync } from "node:fs";

import { runCommandAsync } from "./process.js";

/**
 * Pi port of `hooks/session-drift-check.sh`: run `vstack check --quiet` and
 * classify the exit code the same way the shell hook does.
 *
 *   0 → clean (say nothing)
 *   1 → drift (relay the report to the agent verbatim)
 *   2+ → the check itself failed (say so once, with its diagnostic)
 *   spawn failure → no vstack binary; one line saying so
 *   unusable cwd → one line naming the directory; never silence
 */
export type DriftCheckResult =
	| { kind: "clean" }
	| { kind: "drift"; report: string }
	| { kind: "failed"; exitCode: number; report: string }
	| { kind: "unavailable" }
	| { kind: "unusable-cwd"; cwd: string };

export interface DriftCheckOptions {
	/** Pass `--no-available` so the report omits not-yet-installed suggestions. */
	includeAvailable: boolean;
	timeoutMs: number;
	/** Binary to run; tests point this at a fake. */
	binary?: string;
}

export function driftCheckArgs(options: Pick<DriftCheckOptions, "includeAvailable">): string[] {
	const args = ["check", "--quiet"];
	if (!options.includeAvailable) args.push("--no-available");
	return args;
}

export async function runDriftCheck(cwd: string, options: DriftCheckOptions): Promise<DriftCheckResult> {
	const binary = options.binary ?? "vstack";
	// A spawn into a directory that does not exist — or one this process
	// cannot enter — fails with the same ENOENT a missing binary does, so
	// without this the report would blame PATH, or say nothing at all. The
	// bash hook names the directory; so does this.
	try {
		if (!statSync(cwd).isDirectory()) return { kind: "unusable-cwd", cwd };
		accessSync(cwd, constants.R_OK | constants.X_OK);
	} catch {
		return { kind: "unusable-cwd", cwd };
	}
	const result = await runCommandAsync(binary, driftCheckArgs(options), cwd, options.timeoutMs);
	// The human report is stderr; stdout is reserved for --json.
	const report = `${result.stderr}${result.stdout}`.trim();
	if (result.exitCode === 0) return { kind: "clean" };
	if (result.exitCode === 1) return { kind: "drift", report };
	// spawn() surfaces ENOENT through the error event as exit -1 with the
	// error text. The port only runs because vstack installed it, so a
	// missing binary is almost always a PATH gap worth one line.
	if (result.exitCode === -1 && /ENOENT/.test(result.stderr)) return { kind: "unavailable" };
	return { kind: "failed", exitCode: result.exitCode, report };
}

/** Text handed to the agent for a non-clean result; `undefined` means silence. */
export function driftMessage(result: DriftCheckResult): string | undefined {
	switch (result.kind) {
		case "clean":
			return undefined;
		case "unavailable":
			return "vstack drift check skipped: vstack is not on PATH";
		case "unusable-cwd":
			return `vstack check could not run: project directory ${result.cwd} is not accessible; drift status unknown`;
		case "drift":
			return result.report;
		case "failed":
			return `vstack check could not run (exit ${result.exitCode}); drift status unknown:\n${result.report}`;
	}
}

/** Text for a throw the classified result kinds never accounted for. */
export function driftErrorMessage(error: unknown): string {
	const reason = error instanceof Error ? error.message : String(error);
	return `vstack check could not run: ${reason || "unknown error"}; drift status unknown`;
}

/**
 * Hand a drift check's outcome to `send`. Every failure mode gets a line: an
 * unexpected throw is the one path that could otherwise be mistaken for a
 * clean install. Never rejects — the caller does not await it, so a rejection
 * would surface as an unhandled one during session startup.
 */
export async function deliverDrift(
	check: Promise<DriftCheckResult>,
	send: (message: string) => void,
): Promise<void> {
	let message: string | undefined;
	try {
		message = driftMessage(await check);
	} catch (error) {
		message = driftErrorMessage(error);
	}
	if (message === undefined) return;
	try {
		send(message);
	} catch {
		// The delivery channel itself is what failed; there is nowhere left to
		// report it to.
	}
}
