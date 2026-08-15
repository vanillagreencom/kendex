import { runCommandAsync } from "./cargo.js";

/**
 * Pi port of `hooks/session-drift-check.sh`: run `vstack check --quiet` and
 * classify the exit code the same way the shell hook does.
 *
 *   0 → clean (say nothing)
 *   1 → drift (relay the report to the agent verbatim)
 *   2+ → the check itself failed (say so once, with its diagnostic)
 *   spawn failure → no vstack binary; stay silent
 */
export type DriftCheckResult =
	| { kind: "clean" }
	| { kind: "drift"; report: string }
	| { kind: "failed"; exitCode: number; report: string }
	| { kind: "unavailable" };

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
	const result = await runCommandAsync(binary, driftCheckArgs(options), cwd, options.timeoutMs);
	// The human report is stderr; stdout is reserved for --json.
	const report = `${result.stderr}${result.stdout}`.trim();
	if (result.exitCode === 0) return { kind: "clean" };
	if (result.exitCode === 1) return { kind: "drift", report };
	// spawn() surfaces ENOENT through the error event as exit -1 with the
	// error text; a missing binary is the one failure the user cannot act on
	// from inside a session, so it is silent rather than "failed".
	if (result.exitCode === -1 && /ENOENT/.test(result.stderr)) return { kind: "unavailable" };
	return { kind: "failed", exitCode: result.exitCode, report };
}

/** Text handed to the agent for a non-clean result; `undefined` means silence. */
export function driftMessage(result: DriftCheckResult): string | undefined {
	switch (result.kind) {
		case "clean":
		case "unavailable":
			return undefined;
		case "drift":
			return result.report;
		case "failed":
			return `vstack check could not run (exit ${result.exitCode}); drift status unknown:\n${result.report}`;
	}
}
