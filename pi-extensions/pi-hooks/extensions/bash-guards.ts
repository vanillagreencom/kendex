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

/** Shell control operators that end one simple command and start the next. */
const SEPARATORS = new Set([";", "&", "|", "(", ")", "{", "}", "\n", "\r"]);

/** git global options that take their value as the next word. */
const GIT_GLOBAL_VALUE = new Set([
	"-C",
	"-c",
	"--git-dir",
	"--work-tree",
	"--namespace",
	"--super-prefix",
	"--exec-path",
	"--config-env",
	"--attr-source",
]);

/** Words that stand in front of a command without being it. */
const TRANSPARENT = new Set([
	"if",
	"then",
	"else",
	"elif",
	"fi",
	"while",
	"until",
	"do",
	"done",
	"!",
	"time",
	"command",
	"exec",
	"nohup",
	"sudo",
	"env",
]);

/** What the scan found across every `git` argv in one bash command. */
export interface CommandScan {
	/** A `git … commit` invocation is in the command. */
	commit: boolean;
	/** The commit may land in another repository (`-C`, `cd`, `GIT_DIR`, …). */
	moves: boolean;
	/** The first word that bypasses an armed hook, or injects config that could. */
	bypass: string | null;
}

function setBypass(scan: CommandScan, token: string): void {
	if (scan.bypass !== null) return;
	const flat = token.replace(/[\n\r\t]+/g, " ");
	scan.bypass = flat.length > 60 ? flat.slice(0, 60) : flat;
}

/**
 * Consume a `$(...)` or `${...}` whole, so its operators never split a command
 * and its contents never read as words of their own.
 */
function substitution(command: string, start: number): { next: number; text: string } {
	const opener = command[start + 1];
	const closer = opener === "(" ? ")" : "}";
	let depth = 0;
	let text = "$";
	let i = start + 1;
	while (i < command.length) {
		const ch = command[i];
		text += ch;
		if (ch === opener) depth++;
		else if (ch === closer) {
			depth--;
			if (depth === 0) return { next: i + 1, text };
		}
		i++;
	}
	return { next: i, text };
}

/**
 * Judge one simple command: leading assignments, then transparent prefixes
 * (`if`, `sudo`, `env`, …), then the command word. Only a `git` invocation is
 * judged, and only by its own argv.
 */
function judge(tokens: string[], scan: CommandScan): void {
	let k = 0;
	while (k < tokens.length) {
		const t = tokens[k];
		if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
			// Configuration injected through the environment reaches git
			// wherever the assignment stands, so it is judged as a word of
			// its own.
			if (t.startsWith("GIT_CONFIG_")) setBypass(scan, t);
			if (t.startsWith("GIT_DIR=") || t.startsWith("GIT_WORK_TREE=")) scan.moves = true;
			k++;
			continue;
		}
		if (TRANSPARENT.has(t)) {
			k++;
			continue;
		}
		break;
	}
	if (k >= tokens.length) return;

	const base = tokens[k].replace(/^.*\//, "");
	if (base !== "git") {
		if (base === "cd") scan.moves = true;
		return;
	}

	// Global options run until the first word that is not one; a global option
	// taking a separate value carries that value with it.
	let j = k + 1;
	const globalsFrom = j;
	let subcommand = "";
	while (j < tokens.length) {
		const t = tokens[j];
		if (!t.startsWith("-")) {
			subcommand = t;
			break;
		}
		j += GIT_GLOBAL_VALUE.has(t) ? 2 : 1;
	}
	const globalsTo = Math.min(j - 1, tokens.length - 1);

	if (subcommand === "config") {
		// A core.hooksPath line disarms the hook before the commit reaches it.
		// A read on the same line is refused with the write: the key is
		// matched wherever it stands after `config`, in any case.
		for (let m = j + 1; m < tokens.length; m++) {
			if (tokens[m].toLowerCase().includes("hookspath")) setBypass(scan, tokens[m]);
		}
		return;
	}
	if (subcommand !== "commit") return;
	scan.commit = true;

	// -c and --config-env are configuration only as GLOBAL options. After the
	// subcommand, `git commit -c` is --reedit-message and injects nothing.
	for (let m = globalsFrom; m <= globalsTo; m++) {
		const t = tokens[m];
		if (t === "-c" || t.startsWith("--config-env")) setBypass(scan, t);
		if (t === "-C" || t.startsWith("--git-dir") || t.startsWith("--work-tree")) scan.moves = true;
	}
	// git allows any unique prefix of --no-verify, and -n alone or inside a
	// short-flag cluster is the same flag. It skips the commit-msg hook too,
	// whose gate is not knowable here, so nothing can stand in for it.
	for (let m = j + 1; m < tokens.length; m++) {
		const t = tokens[m];
		if (/^--no-veri/.test(t) || /^-[A-Za-z]*n[A-Za-z]*$/.test(t)) setBypass(scan, t);
	}
}

/**
 * Split a bash command into simple commands and judge each `git` argv.
 *
 * One left-to-right pass: quotes hold a word together, control operators end a
 * simple command. Text that is not in a git argv — a heredoc body, another
 * program's arguments, a quoted commit message — is not a flag here, which is
 * the whole reason for the split: `cat -n` in a heredoc, `python3 -c`, and
 * prose naming `--no-verify` were all refused as bypasses by the word-order
 * rule this replaces.
 *
 * The limits are the price of not running a shell. `sh -c '...'` and git
 * aliases hide a commit from this gate entirely, and a `$(...)` stays one word
 * rather than being looked into. The gate guards habit, not an adversary:
 * git's own hooks are the control, and they run in the right repository
 * whatever the command's quoting or directory hops. A miss here skips a
 * refusal, never a check.
 *
 * Linear in the command's length: every character is read once and no regex
 * runs over the command as a whole.
 *
 * Mirrors `hooks/pre-commit-check.sh`.
 */
export function scanCommand(command: string): CommandScan {
	const scan: CommandScan = { commit: false, moves: false, bypass: null };
	let tokens: string[] = [];
	let word = "";
	let haveWord = false;
	const flush = (): void => {
		if (haveWord) {
			tokens.push(word);
			word = "";
			haveWord = false;
		}
	};
	const endCommand = (): void => {
		flush();
		if (tokens.length > 0) judge(tokens, scan);
		tokens = [];
	};

	const n = command.length;
	let i = 0;
	while (i < n) {
		const ch = command[i];
		if (ch === "\\") {
			word += command[i + 1] ?? "";
			haveWord = true;
			i += 2;
			continue;
		}
		if (ch === "'") {
			i++;
			while (i < n && command[i] !== "'") word += command[i++];
			i++;
			haveWord = true;
			continue;
		}
		if (ch === '"') {
			i++;
			while (i < n) {
				const c = command[i];
				if (c === "\\") {
					word += command[i + 1] ?? "";
					i += 2;
					continue;
				}
				if (c === '"') {
					i++;
					break;
				}
				word += c;
				i++;
			}
			haveWord = true;
			continue;
		}
		if (ch === "`") {
			i++;
			while (i < n && command[i] !== "`") word += command[i++];
			i++;
			haveWord = true;
			continue;
		}
		if (ch === "$" && (command[i + 1] === "(" || command[i + 1] === "{")) {
			const consumed = substitution(command, i);
			word += consumed.text;
			haveWord = true;
			i = consumed.next;
			continue;
		}
		if (ch === " " || ch === "\t") {
			flush();
			i++;
			continue;
		}
		if (SEPARATORS.has(ch)) {
			endCommand();
			i++;
			continue;
		}
		// A redirection operator ends the word; its target reads as one more
		// argument, which no rule in `judge` matches.
		if (ch === "<" || ch === ">") {
			flush();
			i++;
			continue;
		}
		word += ch;
		haveWord = true;
		i++;
	}
	endCommand();
	return scan;
}

/** A `git … commit` invocation stands somewhere in the command. */
export function isGitCommit(command: string): boolean {
	return scanCommand(command).commit;
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
 * arms them). Where one is armed, a command whose git argv sidesteps it is
 * refused: git would skip the commit-msg hook too, and nothing here can check
 * the message. Otherwise the commit is refused naming that command: arming is
 * the local act that says a person wants this repository's committed scripts
 * run on their commits, and this gate never runs them on their behalf.
 *
 * Gates the working directory only. A commit aimed at another repository is
 * gated by that repository's own armed hook, and by nothing here; the gate
 * never follows `-C`, `cd`, `--git-dir`, or `--work-tree`, and says which
 * directory it judged where it could not defer.
 */
export async function preCommitGate(command: string, cwd: string): Promise<PreCommitVerdict> {
	const scan = scanCommand(command);
	if (!scan.commit) return { kind: "allow" };

	const elsewhere = scan.moves
		? `pi-hooks pre-commit: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this gate judged ${cwd} only. The target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there).`
		: undefined;

	const hooksDir = await runCommandAsync("git", ["rev-parse", "--git-path", "hooks"], cwd, GIT_BUDGET_MS);
	if (hooksDir.timedOut) {
		return { kind: "refuse", reason: `pi-hooks pre-commit: git rev-parse timed out after ${GIT_BUDGET_MS}ms in ${cwd}, so whether this repository's git hooks are armed could not be measured, and an unmeasured repository is not armed.` };
	}
	if (hooksDir.exitCode !== 0) return { kind: "allow", notice: elsewhere };

	if (await hooksArmed(resolve(cwd, hooksDir.stdout.trim()), cwd)) {
		if (!scan.bypass) return { kind: "allow" };
		return {
			kind: "refuse",
			reason: `pi-hooks pre-commit: '${scan.bypass}' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here. Commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself.`,
		};
	}

	const refusal = `pi-hooks pre-commit: this repository's git hooks are not armed by kendex in ${cwd}, so nothing checks this commit. Run 'kendex guard install' (this gate does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or disable preCommitCheck.`;
	return { kind: "refuse", reason: elsewhere ? `${elsewhere}\n${refusal}` : refusal };
}
