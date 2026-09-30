/**
 * kendex check --quiet --report-only output protocol: exit 1 report bytes are
 * relayed outside lanes. Lanes withhold reports with any fix: kendex advice
 * or a direct refresh or remove suggestion.
 * At exit 2, leading Error: or error: denotes a precheck failure; all other
 * nonempty reports are incomplete checks. tests/drift-check.test.ts pins the
 * complete result and report for each producer form.
 */
import { accessSync, constants, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { runCommandAsync } from "./process.js";

/**
 * Pi port of `hooks/session-drift-check.sh`: run `kendex check --quiet
 * --report-only` and classify the exit code the same way the shell hook does.
 * `--report-only` keeps a session start from writing the project's committed
 * install record on any branch; a kendex too old to know the flag refuses it
 * with a usage error, which reads as could-not-run, never as a reason to run
 * the check without it.
 *
 *   0 → clean (say nothing outside a lane)
 *   1 → drift, or packages not yet evaluated (relay a safe report in lanes)
 *   2 → kendex could not check, in part or at all: a report carrying a
 *       "could not check" section is relayed under an "incomplete" line;
 *       output opening with kendex's own Error: line or clap's usage
 *       error:, or no output at all, comes from before the check read
 *       anything, so it reads as could-not-run
 *   3+ → the check itself failed (could not run, with its output)
 *   ENOENT spawn failure → no kendex binary; one "skipped" line
 *   unusable cwd, other spawn error, unexpected throw → could not run
 */
type CheckResult =
	| { kind: "clean" }
	| { kind: "drift"; report: string }
	| { kind: "incomplete"; report: string }
	| { kind: "failed"; exitCode: number; report: string }
	| { kind: "unavailable" }
	| { kind: "unusable-cwd"; cwd: string };

/** A lane wraps the check so even a clean install carries the worktree rule. */
export type DriftCheckResult = CheckResult
	| { kind: "lane"; check: CheckResult }
	| { kind: "lane-unknown"; report: string };

export interface DriftCheckOptions {
	timeoutMs: number;
	/** Binary to run; tests point this at a fake. */
	binary?: string;
}

/** Output kendex prints before the check reads anything: its own `Error:` line or clap's usage `error:`. */
const PRECHECK_FAILURE = /^(Error|error):/;

export async function runDriftCheck(cwd: string, options: DriftCheckOptions): Promise<DriftCheckResult> {
	const binary = options.binary ?? "kendex";
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
	const git = await runCommandAsync("git", ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir"], cwd, options.timeoutMs);
	let lane = false;
	if (git.stoppedBy !== null) return { kind: "lane-unknown", report: `git probe stopped by ${git.stoppedBy}.` };
	if (git.exitCode !== 0) {
		if (!git.stderr.includes("not a git repository")) return { kind: "lane-unknown", report: git.stderr };
	} else {
		const [root, gitDir, common, ...extra] = git.stdout.trimEnd().split("\n");
		if (!root || !gitDir || !common || extra.length) return { kind: "lane-unknown", report: "git returned incomplete directory metadata." };
		lane = gitDir !== common;
		if (!lane) {
			// lane-marker binds a root under the common git directory. Scanning
			// roots also covers subagents that inherit no LANE_MAIL_ITEM.
			const directory = join(common, "lane-mail");
			try {
				for (const marker of readdirSync(directory, { withFileTypes: true })) {
					if (!marker.isFile()) throw new Error(`The lane marker is not a plain file: ${join(directory, marker.name)}`);
					if (readFileSync(join(directory, marker.name), "utf8").replace(/\n$/, "") === root) { lane = true; break; }
				}
			} catch (error) {
				// Only an absent marker directory means no launched lane. A
				// vanished or unreadable marker leaves the status unknown.
				if (!(error instanceof Error && "code" in error && error.code === "ENOENT" && "path" in error && error.path === directory)) {
					return { kind: "lane-unknown", report: String(error) };
				}
			}
		}
	}
	const result = await runCommandAsync(binary, ["check", "--quiet", "--report-only"], cwd, options.timeoutMs);
	// The report is on stdout; stderr carries only Error: lines and the
	// non-quiet all-clear, so both are concatenated, stderr first.
	const report = `${result.stderr}${result.stdout}`.trim();
	let check: CheckResult;
	if (result.exitCode === 0) check = { kind: "clean" };
	else if (result.exitCode === 1) check = { kind: "drift", report };
	else if (result.exitCode === 2 && report !== "" && !PRECHECK_FAILURE.test(report)) check = { kind: "incomplete", report };
	// spawn() surfaces ENOENT through the error event as exit -1 with the
	// error text. The port only runs because kendex installed it, so a
	// missing binary is almost always a PATH gap worth one line.
	else if (result.exitCode === -1 && /ENOENT/.test(result.stderr)) check = { kind: "unavailable" };
	else check = { kind: "failed", exitCode: result.exitCode, report };
	return lane ? { kind: "lane", check } : check;
}

/** Text handed to the agent; `undefined` means a clean install outside a lane. */
export function driftMessage(result: DriftCheckResult): string | undefined {
	switch (result.kind) {
		case "lane-unknown":
			return `session-drift-check: lane=unknown\nThe lane status could not be read. Drift details are withheld.\n${result.report}`;
		case "lane": {
			const rule = "session-drift-check: lane=1\nThis worktree changes nothing about the install. The overseer refreshes the base checkout after merge. kendex refresh and kendex apply are never run here.";
			let check = result.check;
			if ("report" in check && /fix:\s+kendex([\s\p{P}]|$)|kendex\s+(refresh|remove)([\s\p{P}]|$)/u.test(check.report)) {
				// render_plain emits two-space items and a section overflow
				// count. Whole-report truncation yields only a lower bound.
				let count = 0;
				for (const line of check.report.split("\n")) {
					const overflow = /^  … (\d+) more/.exec(line);
					if (overflow) count += Number(overflow[1]);
					else if (line.startsWith("  ")) count++;
				}
				const lowerBound = /^… report truncated/m.test(check.report) ? "\nsession-drift-check: count=lower-bound" : "";
				check = { ...check, report: `session-drift-check: drift-items=${count}${lowerBound}` };
			}
			const message = driftMessage(check);
			return message === undefined ? rule : `${rule}\n${message}`;
		}
		case "clean":
			return undefined;
		case "unavailable":
			return "kendex-drift-unavailable: command=kendex\nkendex is not on PATH.";
		case "unusable-cwd":
			return `drift-cwd=${result.cwd}\nThe project directory is not accessible. Drift status is unknown.`;
		case "drift":
			return result.report;
		case "incomplete":
			return `kendex-drift-incomplete: exit=2\nSome drift status is unknown.\n${result.report}`;
		case "failed":
			return `kendex-drift-failed: exit=${result.exitCode}\nThe check could not run. Drift status is unknown.\n${result.report}`;
	}
}

/** Text for a throw the classified result kinds never accounted for. */
export function driftErrorMessage(error: unknown): string {
	const reason = error instanceof Error ? error.message : String(error);
	return `drift-error=${JSON.stringify(reason || "unknown error")}\nThe check could not run. Drift status is unknown.`;
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
