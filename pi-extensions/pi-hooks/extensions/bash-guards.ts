import { accessSync, constants, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { runCommandAsync } from "./process.js";

/**
 * Match a bash command that is exactly `cd` or `cd <target>` with no shell
 * operators that would scope the directory change (no `&&`, `||`, `|`, `;`,
 * parens, backticks, `$(...)`, or newlines). Such commands change Pi's CWD
 * across tool calls; a bare `cd` goes to $HOME, the same permanent move.
 *
 * Mirrors `hooks/block-bare-cd.sh`.
 */
const BARE_CD = /^cd(\s+[^&|;()`$\n]+)?$/;

export function isBareCd(command: string): boolean {
	return BARE_CD.test(command.trim());
}

/**
 * The one thing this gate reads out of a hook file: the marker the
 * growth-guards installer ends every line it writes with.
 */
const MARKER = "# kendex-guards-hook";

/** How long a git probe may run before the gate calls the repository unmeasured. */
const GIT_BUDGET_MS = 5000;

/**
 * The command as a word list: every run of characters outside
 * `[a-zA-Z0-9_=-]` becomes one space, and the list is padded with a space at
 * each end so every word can be matched as ` word `. No shell parsing: the
 * authoritative check is the repository's own git pre-commit hook, which git
 * runs in the right repository whatever the command's quoting, substitutions,
 * or directory hops.
 */
function commandWords(command: string): string {
	return ` ${command.replace(/[^a-zA-Z0-9_=-]+/g, " ")} `;
}

/**
 * A `git` word followed, adjacent or later, by a `commit` word. Linear scans:
 * ` git commit ` shares its middle space, so the search for ` commit ` starts
 * at the space that ends ` git `. A regex over the same words backtracks once
 * per `git` word and stalls Pi's event loop on a long command.
 */
function wordsNameGitCommit(words: string): boolean {
	const git = words.indexOf(" git ");
	return git >= 0 && words.indexOf(" commit ", git + 4) >= 0;
}

/**
 * Word-order detection of a git commit. This gate only decides whether the
 * commit is deferred or refused, so a miss here skips a refusal, never a
 * check. Over-matching runs the other way: `git log --grep commit` is a
 * commit to this gate, which is free where a hook is armed and costs a
 * refusal to reword where nothing is.
 *
 * Mirrors `hooks/pre-commit-check.sh`.
 */
export function isGitCommit(command: string): boolean {
	return wordsNameGitCommit(commandWords(command));
}

const MOVES_REPOSITORIES = / (cd|-C|--git-dir[^ ]*|--work-tree[^ ]*|GIT_DIR[^ ]*|GIT_WORK_TREE[^ ]*) /;

/**
 * A word that tells git to skip its hooks or injects configuration that
 * could: git's no-verify flag spelled out or cut to any unique prefix, `-n`
 * alone or inside a short-flag cluster, a `-c` word, a `--config-env` word, a
 * `GIT_CONFIG_*` assignment, or a `git config` line naming `core.hooksPath`
 * in any case (a read on the same line is refused with the write; the key
 * is matched wherever it stands after `config`).
 */
function bypassWord(words: string): string | null {
	const flag = / (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|-c|--config-env[^ ]*|GIT_CONFIG_[^ ]*) /.exec(words);
	if (flag) return flag[1];
	const lower = words.toLowerCase();
	const config = lower.indexOf(" config ");
	if (config < 0) return null;
	const key = lower.indexOf(" hookspath ", config + 8);
	return key < 0 ? null : words.slice(config, key + " hookspath ".length).trim();
}

export type PreCommitVerdict =
	/** Not a commit, or nothing here gates it; a notice is for the UI, never the agent. */
	| { kind: "allow"; notice?: string }
	/** The tool call is blocked with this reason. */
	| { kind: "refuse"; reason: string };

function executableFile(path: string): boolean {
	try {
		if (!statSync(path).isFile()) return false;
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

function carriesMarker(path: string): boolean {
	try {
		return readFileSync(path, "utf8").includes(MARKER);
	} catch {
		return false;
	}
}

/**
 * Armed is the marker in both hook files, in the directory git reads with
 * nothing redirecting it, in files git will actually run. `core.hooksPath` set
 * to anything at all is not armed: deciding otherwise is the taxonomy that
 * kept answering "armed" about repositories that were not. Exit 1 from `git
 * config --get` is git for "not set", and it is the only answer that means
 * unredirected; a git that failed for any other reason is a repository nobody
 * measured, which is not armed either.
 */
async function hooksArmed(hooksDir: string, cwd: string): Promise<boolean> {
	const hooksPath = await runCommandAsync("git", ["config", "--get", "core.hooksPath"], cwd, GIT_BUDGET_MS);
	if (hooksPath.timedOut || hooksPath.exitCode !== 1) return false;
	for (const lane of ["pre-commit", "commit-msg"]) {
		const file = resolve(hooksDir, lane);
		if (!executableFile(file) || !carriesMarker(file)) return false;
	}
	return true;
}

/**
 * Pre-commit gate: the Pi port of `hooks/pre-commit-check.sh`, same contract.
 *
 * On a git commit, defer to the working directory's armed git hooks: both
 * pre-commit and commit-msg, marked and executable (`kendex guard install`
 * arms them). Where one is armed, a command that sidesteps it is refused: git
 * would skip the commit-msg hook too, and nothing here can check the message.
 * Otherwise the commit is refused naming that command: arming is the local
 * act that says a person wants this repository's committed scripts run on
 * their commits, and this gate never runs them on their behalf.
 *
 * Gates the working directory only. A commit aimed at another repository is
 * gated by that repository's own armed hook, and by nothing here; the gate
 * never follows `-C`, `cd`, `--git-dir`, or `--work-tree`, and says which
 * directory it judged where it could not defer.
 */
export async function preCommitGate(command: string, cwd: string): Promise<PreCommitVerdict> {
	const words = commandWords(command);
	if (!wordsNameGitCommit(words)) return { kind: "allow" };

	const moves = MOVES_REPOSITORIES.test(words);
	const elsewhere = moves
		? `pi-hooks pre-commit: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this gate judged ${cwd} only. The target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there).`
		: undefined;

	const hooksDir = await runCommandAsync("git", ["rev-parse", "--git-path", "hooks"], cwd, GIT_BUDGET_MS);
	if (hooksDir.timedOut) {
		return { kind: "refuse", reason: `pi-hooks pre-commit: git rev-parse timed out after ${GIT_BUDGET_MS}ms in ${cwd}, so whether this repository's git hooks are armed could not be measured, and an unmeasured repository is not armed.` };
	}
	if (hooksDir.exitCode !== 0) return { kind: "allow", notice: elsewhere };

	if (await hooksArmed(resolve(cwd, hooksDir.stdout.trim()), cwd)) {
		const bypass = bypassWord(words);
		if (!bypass) return { kind: "allow" };
		return {
			kind: "refuse",
			reason: `pi-hooks pre-commit: '${bypass}' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here. Commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself.`,
		};
	}

	const refusal = `pi-hooks pre-commit: this repository's git hooks are not armed by kendex in ${cwd}, so nothing checks this commit. Run 'kendex guard install' (this gate does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or disable preCommitCheck.`;
	return { kind: "refuse", reason: elsewhere ? `${elsewhere}\n${refusal}` : refusal };
}
