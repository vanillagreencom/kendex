import { accessSync, constants, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { runCommandAsync } from "./process.js";

/**
 * A command that is exactly `cd` or `cd <target>` with no operator scoping the
 * change (no `&&`, `||`, `|`, `;`, parens, backticks, `$(...)`, newlines): it
 * moves Pi's CWD for every later tool call, and a bare `cd` goes to $HOME.
 * Mirrors `hooks/block-bare-cd.sh`.
 */
const BARE_CD = /^cd(\s+[^&|;()`$\n]+)?$/;
export function isBareCd(command: string): boolean {
	return BARE_CD.test(command.trim());
}

/** The marker the growth-guards installer ends every hook line it writes with. */
const MARKER = "# kendex-guards-hook";
/** How long a git probe may run before the gate calls the repository unmeasured. */
const GIT_BUDGET_MS = 5000;
/** Shell control operators that end one simple command and start the next. */
const SEPARATORS = new Set([";", "&", "|", "(", ")", "\n", "\r"]);
/** git global options that take their value as the next word. */
const GIT_GLOBAL_VALUE = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--exec-path", "--config-env", "--attr-source"]);
/** Words that stand in front of a command without being it. */
const TRANSPARENT = new Set("if then else elif fi while until do done ! time command exec eval nohup sudo doas env nice ionice timeout stdbuf setsid xargs export declare typeset local readonly".split(" "));
/** `git commit` long options whose value is the next word. */
const COMMIT_VALUE = new Set("--author --date --message --file --template --cleanup --reuse-message --reedit-message --fixup --squash --pathspec-from-file --trailer".split(" "));
/** `git commit` short options whose value is the next word. */
const SHORT_VALUE = "mFcCt";

/**
 * What the scan found across every `git` argv in one bash command: whether one
 * is a commit, whether that commit may land in another repository (`-C`, `cd`,
 * `GIT_DIR`), and the first word bypassing an armed hook or injecting config.
 */
export interface CommandScan {
	commit: boolean;
	moves: boolean;
	bypass: string | null;
}
const basename = (token: string): string => token.replace(/^.*\//, "");
function setBypass(scan: CommandScan, token: string): void {
	if (scan.bypass !== null) return;
	const flat = token.replace(/[\n\r\t]+/g, " ");
	scan.bypass = flat.length > 60 ? flat.slice(0, 60) : flat;
}

/**
 * Judge one simple command: leading assignments, then transparent prefixes
 * (`if`, `sudo`, `env`, `timeout`, …), then the command word.
 */
function judge(tokens: string[], scan: CommandScan): void {
	let k = 0;
	let prefixed = false;
	while (k < tokens.length) {
		const t = tokens[k];
		// Environment-injected configuration reaches git wherever it stands.
		if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
			if (t.startsWith("GIT_CONFIG_")) setBypass(scan, t);
			if (t.startsWith("GIT_DIR=") || t.startsWith("GIT_WORK_TREE=")) scan.moves = true;
			k++;
		} else if (TRANSPARENT.has(basename(t))) {
			prefixed = true;
			k++;
		} else break;
	}
	if (k >= tokens.length) return;
	// A wrapper whose options this gate cannot read (`sudo -u dev`, `timeout 30`)
	// is not a reason to call this not-a-git-command: look behind it instead.
	if (basename(tokens[k]) !== "git") {
		if (basename(tokens[k]) === "cd") scan.moves = true;
		if (!prefixed) return;
		while (k < tokens.length && basename(tokens[k]) !== "git") k++;
		if (k >= tokens.length) return;
	}
	// Global options run until the first word that is not one; a global option
	// taking a separate value carries that value with it.
	let j = k + 1;
	const globalsFrom = j;
	while (j < tokens.length && tokens[j].startsWith("-")) j += GIT_GLOBAL_VALUE.has(tokens[j]) ? 2 : 1;
	const globalsTo = Math.min(j - 1, tokens.length - 1);
	const subcommand = j < tokens.length ? tokens[j] : "";
	// A core.hooksPath line disarms the hook before the commit reaches it; a read
	// is refused with the write, and the key is matched in any case.
	if (subcommand === "config") {
		for (let m = j + 1; m < tokens.length; m++) if (tokens[m].toLowerCase().includes("hookspath")) setBypass(scan, tokens[m]);
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
	// git allows any unique prefix of --no-verify, and -n alone or in a cluster is
	// the same flag; it skips commit-msg too, whose gate is unknowable here. git
	// option boundaries hold: `--` ends them, and an option value is not a flag.
	for (let m = j + 1; m < tokens.length; m++) {
		const t = tokens[m];
		if (t === "--") return;
		if (t.startsWith("--")) {
			if (/^--no-veri/.test(t)) return setBypass(scan, t);
			if (COMMIT_VALUE.has(t)) m++;
		} else if (t.startsWith("-")) {
			if (/^-[A-Za-z]*n[A-Za-z]*$/.test(t)) return setBypass(scan, t);
			if (SHORT_VALUE.includes(t[t.length - 1])) m++;
		}
	}
}

/** The rule this parser replaced, kept for a command whose quoting never closes. */
function fallback(command: string, scan: CommandScan): void {
	const words = ` ${command} `.replace(/[^a-zA-Z0-9_=-]+/g, " ");
	const git = words.indexOf(" git ");
	if (git < 0 || words.indexOf(" commit ", git + 4) < 0) return;
	scan.commit = true;
	const flag = / (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|-c|--config-env[^ ]*|GIT_CONFIG_[^ ]*) /.exec(words);
	if (flag) setBypass(scan, flag[1]);
}

/**
 * Split a bash command into simple commands and judge each `git` argv. One
 * left-to-right pass: quotes hold a word together, control operators end a
 * simple command, and a heredoc body is skipped whole because it is not shell.
 * Text outside a git argv — a heredoc body, a comment, another program's
 * arguments, an operand after `--`, the value of an option that takes one — is
 * not a flag, which is the whole reason for the split.
 *
 * It fails closed where it can: a wrapper whose options it cannot read (`sudo
 * -u dev`, `timeout 30`) does not hide the git word behind it, and a command
 * whose quoting never closes falls back to the word-order rule. `sh -c '...'`,
 * git aliases, a wrapper outside the transparent list and the inside of a
 * `$(...)` stay invisible: this guards habit, and git's hooks are the control.
 *
 * Linear in the command's length: ordinary characters are counted, not copied.
 * Mirrors `hooks/pre-commit-check.sh`.
 */
export function scanCommand(command: string): CommandScan {
	// This runs synchronously on Pi's event loop for every bash call, and most
	// carry no git at all. No path below reports a commit without the word, so
	// one native substring search answers those before any of it runs.
	if (!command.includes("git")) return { commit: false, moves: false, bypass: null };
	const scan: CommandScan = { commit: false, moves: false, bypass: null };
	const n = command.length;
	let tokens: string[] = [];
	let word = "";
	let haveWord = false;
	let unbalanced = false;
	let heredocs: { delim: string; dash: boolean }[] = [];
	let i = 0;
	const flush = (): void => {
		if (!haveWord) return;
		tokens.push(word);
		word = "";
		haveWord = false;
	};
	const endCommand = (): void => {
		flush();
		if (tokens.length > 0) judge(tokens, scan);
		tokens = [];
	};
	/** A single-quoted or backtick run: no escapes inside either. */
	const quoted = (q: string): void => {
		const start = ++i;
		while (i < n && command[i] !== q) i++;
		word += command.slice(start, i);
		haveWord = true;
		if (i >= n) unbalanced = true;
		i++;
	};
	/** A backslash escapes the next character, unless it is a newline: line joining. */
	const dquoted = (): void => {
		let start = ++i;
		haveWord = true;
		while (i < n) {
			if (command[i] === '"') {
				word += command.slice(start, i++);
				return;
			}
			if (command[i] === "\\") {
				word += command.slice(start, i);
				if (command[i + 1] !== "\n") word += command[i + 1] ?? "";
				i += 2;
				start = i;
				continue;
			}
			i++;
		}
		word += command.slice(start, i);
		unbalanced = true;
	};
	/** Consume a $(...) or ${...} whole: its operators never split a command. */
	const substitution = (): void => {
		const opener = command[i + 1];
		const closer = opener === "(" ? ")" : "}";
		const start = i++;
		let depth = 0;
		while (i < n) {
			if (command[i] === opener) depth++;
			else if (command[i] === closer && --depth === 0) {
				i++;
				break;
			}
			i++;
		}
		word += command.slice(start, i);
		haveWord = true;
	};
	/** A redirection ends the word. `<<`/`<<-` name a heredoc: the delimiter is
	 * recorded here, the body skipped at the newline. */
	const redirect = (): void => {
		flush();
		if (command.startsWith("<<<", i)) return void (i += 3);
		if (command.startsWith(">&", i) || command.startsWith("<&", i)) return void (i += 2);
		if (!command.startsWith("<<", i)) return void i++;
		i += 2;
		const dash = command[i] === "-";
		if (dash) i++;
		while (i < n && (command[i] === " " || command[i] === "\t")) i++;
		let delim = "";
		while (i < n) {
			const ch = command[i];
			if (ch === " " || ch === "\t" || ch === "<" || ch === ">" || SEPARATORS.has(ch)) break;
			if (ch === "'" || ch === '"') {
				i++;
				while (i < n && command[i] !== ch) delim += command[i++];
				i++;
			} else if (ch === "\\") {
				delim += command[i + 1] ?? "";
				i += 2;
			} else {
				delim += ch;
				i++;
			}
		}
		if (delim) heredocs.push({ delim, dash });
	};
	/** Skip each heredoc body opened on the line just ended, terminator included. */
	const heredocBodies = (): void => {
		i++;
		for (const h of heredocs) {
			while (i < n) {
				const start = i;
				while (i < n && command[i] !== "\n") i++;
				let line = command.slice(start, i).replace(/\r$/, "");
				if (i < n) i++;
				if (h.dash) line = line.replace(/^\t+/, "");
				if (line === h.delim) break;
			}
		}
		heredocs = [];
	};
	while (i < n) {
		const start = i;
		while (i < n) {
			const c = command[i];
			if (c === " " || c === "\t" || c === "\\" || c === "'" || c === '"' || c === "`" || c === "$" || c === "<" || c === ">" || c === "#" || c === "{" || c === "}" || SEPARATORS.has(c)) break;
			i++;
		}
		if (i > start) {
			word += command.slice(start, i);
			haveWord = true;
		}
		if (i >= n) break;
		const ch = command[i];
		if (ch === " " || ch === "\t") {
			flush();
			i++;
		} else if (ch === "\\") {
			// A backslash-newline is line joining: the shell removes both.
			if (command[i + 1] === "\n") i += 2;
			else if (command[i + 1] === "\r" && command[i + 2] === "\n") i += 3;
			else {
				word += command[i + 1] ?? "";
				haveWord = true;
				i += 2;
			}
		} else if (ch === "'" || ch === "`") quoted(ch);
		else if (ch === '"') dquoted();
		else if (ch === "$" && (command[i + 1] === "(" || command[i + 1] === "{")) substitution();
		else if (ch === "#" && !haveWord) {
			// A # begins a comment at word start only; mid-word it is `-m x#y`.
			while (i < n && command[i] !== "\n") i++;
		} else if ((ch === "{" || ch === "}") && !haveWord && (i + 1 >= n || command[i + 1] === " " || command[i + 1] === "\t" || SEPARATORS.has(command[i + 1]))) {
			// A brace is a keyword only as a whole word; inside one it is expansion,
			// so `git commit -m a{b} --no-verify` is one commit argv.
			endCommand();
			i++;
		} else if (ch === "<" || ch === ">") redirect();
		else if (ch === "&" && command[i + 1] === ">") {
			flush();
			i += 2;
		} else if (SEPARATORS.has(ch)) {
			endCommand();
			if (ch === "\n") heredocBodies();
			else i++;
		} else {
			word += ch;
			haveWord = true;
			i++;
		}
	}
	endCommand();
	if (unbalanced && !scan.commit) fallback(command, scan);
	return scan;
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
 * to anything at all is not armed: deciding otherwise is the taxonomy that kept
 * answering "armed" about repositories that were not. Exit 1 from `git config
 * --get` is git for "not set" and the only answer that means unredirected; any
 * other failure is a repository nobody measured, which is not armed either.
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
 * On a git commit, defer to the working directory's armed git hooks — both
 * pre-commit and commit-msg, marked and executable (`kendex guard install`
 * arms them). Where one is armed, a git argv that sidesteps it is refused: git
 * would skip commit-msg too, and nothing here can check the message. Otherwise
 * the commit is refused naming that command: arming is the local act that asks
 * for those scripts, and this gate never runs them on a repository's behalf.
 *
 * Gates the working directory only. A commit aimed elsewhere is that
 * repository's own armed hook's to gate; this gate never follows `-C`, `cd`,
 * `--git-dir` or `--work-tree`, and says which directory it judged where it
 * could not defer.
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
