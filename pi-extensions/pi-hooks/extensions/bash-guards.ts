import { accessSync, constants, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { runCommandAsync } from "./process.js";

/** A command that is exactly `cd` or `cd <target>` with no operator scoping the
 * change (no `&&`, `|`, `;`, parens, backticks, `$(...)`, newlines): it moves
 * Pi's CWD for every later call. Mirrors `hooks/block-bare-cd.sh`. */
const BARE_CD = /^cd(\s+[^&|;()`$\n]+)?$/;
export function isBareCd(command: string): boolean {
	return BARE_CD.test(command.trim());
}

/** The marker the growth-guards installer ends every hook line it writes with. */
const MARKER = "# kendex-guards-hook";
/** How long a git probe may run before the repository counts as unmeasured. */
const GIT_BUDGET_MS = 5000;
/** Shell control operators that end one simple command and start the next. */
const SEPARATORS = new Set([";", "&", "|", "(", ")", "\n", "\r"]);
/** Characters that end a run of ordinary word text. */
const BREAK = new Set([" ", "\t", "\\", "'", '"', "`", "$", "<", ">", "#", ...SEPARATORS]);
/** `git commit` short options whose value is attached or the next word. */
const SHORT_VALUE = "mFcCt";

/** What the scan found across the live words of one bash command: whether they
 * name a commit, whether it may land elsewhere, the first word bypassing a hook
 * or injecting config, and any construct this scanner does not model. */
export interface CommandScan {
	commit: boolean;
	moves: boolean;
	bypass: string | null;
	unmodelled: string | null;
}
const basename = (token: string): string => token.replace(/^.*\//, "");
function setBypass(scan: CommandScan, token: string): void {
	if (scan.bypass !== null) return;
	const flat = token.replace(/[\n\r\t]+/g, " ");
	scan.bypass = flat.length > 60 ? flat.slice(0, 60) : flat;
}

/** Constructs this scanner does not model, named rather than decoded: an alias
 * config key, ANSI-C quoting, a line continuation inside quotes, and a shift
 * operator inside arithmetic, which is not the heredoc this reads it as. Seeing
 * one is the whole rule. Each decoder added here invites the next construct, and
 * the answer to text this cannot read is to refuse, not to parse harder.
 *
 * They are asked of the NORMALIZED command — quote characters removed — so a
 * spelling the shell assembles reads as its letters and `com''mit` holds the
 * word. One text test over text this cannot parse, rather than a parse. An
 * alias key is the exception and keeps the bare git prerequisite: it defines
 * the commit under another name, so the word can be absent altogether. */
function unmodelled(command: string, quotedContinuation: boolean, norm: string): string | null {
	if (!norm.includes("git")) return null;
	if (command.toLowerCase().includes("alias.")) return "an alias config key";
	if (!norm.includes("commit")) return null;
	if (command.includes("$'")) return "ANSI-C quoting";
	if (quotedContinuation) return "a line continuation inside quotes";
	if (/\(\([^)]*<</.test(command)) return "a shift inside arithmetic";
	return null;
}
/** Quote characters carry no letters of their own, so removing them joins the
 * fragments a word was split into and leaves everything else where it was. */
const normalize = (command: string): string => command.replace(/['"]/g, "");

/** The rule over the live words of one command. */
function judge(tokens: string[], scan: CommandScan): void {
	let git = false;
	let commit = false;
	for (const t of tokens) {
		if (t === "-C" || t === "cd" || t.startsWith("--git-dir") || t.startsWith("--work-tree") || t.startsWith("GIT_DIR=") || t.startsWith("GIT_WORK_TREE=")) scan.moves = true;
		// Configuration reaches git from anywhere: an assignment, an export, a
		// config write in an earlier command. A bypass prints only beside a commit.
		if (!/[ \t\n\r]/.test(t) && (t.startsWith("GIT_CONFIG_") || t.toLowerCase().includes("hookspath"))) setBypass(scan, t);
		if (!git) git = basename(t) === "git";
		else if (t === "commit") commit = true;
	}
	if (!git || !commit) return;
	scan.commit = true;
	for (const t of tokens) {
		// A word is a bypass only where the WHOLE word is one, which is what keeps a
		// quoted commit message out of it: `git commit -m "why --no-verify is banned"`
		// is one word of prose, not the flag. Any `-c<value>` injects configuration,
		// whatever the value: an included file can set core.hooksPath.
		if (/[ \t\n\r]/.test(t)) continue;
		if (/^--no-veri/.test(t) || /^-c/.test(t) || t.startsWith("--config-env")) return setBypass(scan, t);
		if (!/^-[A-Za-z]/.test(t)) continue;
		// A cluster reads left to right: from the first value-taking option the rest
		// of the word is its value, so `-mnote` is a message and `-nm` is not.
		for (let p = 1; p < t.length; p++) {
			if (SHORT_VALUE.includes(t[p])) break;
			if (t[p] === "n") return setBypass(scan, t);
		}
	}
}

/**
 * Only live command text is judged. A quoted run, a comment tail and a heredoc
 * body are not commands, so their contents never reach a word; what survives is
 * whole words, and the rule over them is the word order: a `git` word with a
 * later `commit` word is a commit, and a word in it that skips the hooks or
 * injects configuration is the bypass. Whole words, so `--grep=commit` is not a
 * commit and `-mnote` is a message rather than -n.
 *
 * Nothing here models an argv. Every round that tried named one more construct
 * and opened the next hole, so this scanner answers one question — which text is
 * a live word — and knows nothing of options, wrappers or subcommands. An
 * unrecognised prefix simply leaves `git commit --no-verify` standing.
 *
 * Its blind spot is the other side of that trade: text a shell would run but
 * this drops, inside quotes (`sh -c "git commit --no-verify"`) or a heredoc
 * body. Those are the false refusals this gate exists to end, and git's own
 * hooks remain the control. Mirrors `hooks/pre-commit-check.sh`.
 */
export function scanCommand(command: string): CommandScan {
	const scan: CommandScan = { commit: false, moves: false, bypass: null, unmodelled: null };
	const n = command.length;
	let quotedContinuation = false;
	let tokens: string[] = [];
	let word = "";
	let haveWord = false;
	let heredocs: { delim: string; dash: boolean }[] = [];
	let depth = 0;
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
	/** Quoting sets a word boundary; it does not stop the word existing, so the
	 * contents join the word unquoted: `g''it` is git and a quoted --no-verify is
	 * the flag. Inside a double-quoted or backtick run a backslash escapes the next
	 * character, so an escaped quote does not close the run; single quotes take no
	 * escapes. A run that never closes contributes nothing and its opening quote is
	 * one stray character, which leaves the rest live. */
	const quoted = (q: string): void => {
		let start = ++i;
		let text = "";
		while (i < n) {
			if (command[i] === q) {
				word += text + command.slice(start, i);
				haveWord = true;
				i++;
				return;
			}
			if (command[i] === "\\" && q !== "'") {
				if (command[i + 1] === "\n") quotedContinuation = true;
				text += command.slice(start, i) + (command[i + 1] ?? "");
				i += 2;
				start = i;
				continue;
			}
			i++;
		}
		i = start;
	};
	/** A heredoc delimiter: quotes and line continuations come out of it, so
	 * `<<EO\<newline>F` names EOF and the body ends where bash ends it. */
	const heredoc = (dash: boolean): void => {
		while (i < n && (command[i] === " " || command[i] === "\t")) i++;
		let delim = "";
		while (i < n) {
			const ch = command[i];
			if (ch === " " || ch === "\t" || ch === "<" || ch === ">" || SEPARATORS.has(ch)) break;
			if (ch === "'" || ch === '"') {
				i++;
				while (i < n && command[i] !== ch) delim += command[i++];
				i++;
			} else if (ch === "\\" && command[i + 1] === "\n") i += 2;
			else if (ch === "\\") {
				delim += command[i + 1] ?? "";
				i += 2;
			} else {
				delim += ch;
				i++;
			}
		}
		if (delim) heredocs.push({ delim, dash });
	};
	/** Skip each body opened on the line just ended, terminator included. One that
	 * never terminates is left live rather than swallowing the rest. */
	const heredocBodies = (): void => {
		const start = ++i;
		for (const h of heredocs) {
			while (i < n) {
				const from = i;
				while (i < n && command[i] !== "\n") i++;
				// bash accepts a tab-indented terminator for `<<-` only.
				let line = command.slice(from, i).replace(/\r$/, "");
				if (h.dash) line = line.replace(/^\t+/, "");
				if (i < n) i++;
				if (line === h.delim) break;
			}
			if (i >= n) i = start;
		}
		heredocs = [];
	};
	while (i < n) {
		const start = i;
		while (i < n && !BREAK.has(command[i])) i++;
		if (i > start) {
			word += command.slice(start, i);
			haveWord = true;
		}
		if (i >= n) break;
		const ch = command[i];
		const c2 = command[i + 1];
		if (ch === " " || ch === "\t") {
			flush();
			i++;
		} else if (ch === "\\") {
			// A backslash-newline is line joining: the shell removes both.
			if (c2 === "\n") i += 2;
			else if (c2 === "\r" && command[i + 2] === "\n") i += 3;
			else {
				word += c2 ?? "";
				haveWord = true;
				i += 2;
			}
		} else if (ch === "'" || ch === '"' || ch === "`") {
			quoted(ch);
		} else if (ch === "$" && c2 === "(") {
			// `$(`, `<(` and `>(` hold their interior in the command enclosing them:
			// inside one, an operator separates words rather than commands.
			depth++;
			i += 2;
		} else if ((ch === "<" || ch === ">") && c2 === "(") {
			flush();
			depth++;
			i += 2;
		} else if (ch === "$") {
			word += ch;
			haveWord = true;
			i++;
		} else if (ch === "<" && c2 === "<") {
			flush();
			i += 2;
			const dash = command[i] === "-";
			if (dash) i++;
			heredoc(dash);
		} else if (ch === "<" || ch === ">") {
			// A redirection operator ends a word and nothing else: the target that
			// follows is one more word, and `git >x commit` is still a commit.
			flush();
			i++;
			if (command[i] === "&" || command[i] === "|" || command[i] === ">") i++;
		} else if (ch === "&" && c2 === ">") {
			flush();
			i += 2;
		} else if (ch === "#" && haveWord) {
			// A # begins a comment at word start only; mid-word it is `-m x#y`.
			word += ch;
			i++;
		} else if (ch === "#") {
			while (i < n && command[i] !== "\n") i++;
		} else if (ch === ")" && depth > 0) {
			// The close does not end the word: `$(true)#x` is one word to bash, so a
			// hash touching it is an ordinary character rather than a comment opener.
			depth--;
			i++;
		} else if (depth > 0) {
			flush();
			i++;
		} else {
			endCommand();
			if (ch === "\n") heredocBodies();
			else i++;
		}
	}
	endCommand();
	scan.unmodelled = unmodelled(command, quotedContinuation, normalize(command));
	return scan;
}

export type PreCommitVerdict =
	/** Not a commit, or nothing here gates it; a notice is for the UI, never the agent. */
	| { kind: "allow"; notice?: string }
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

/** Armed is the marker in both hook files, in the directory git reads with
 * nothing redirecting it, in files git will actually run. `core.hooksPath` set
 * to anything is not armed. Exit 1 from `git config --get` is git for "not set"
 * and the only answer meaning unredirected; anything else is unmeasured. */
async function hooksArmed(hooksDir: string, cwd: string): Promise<boolean> {
	const hooksPath = await runCommandAsync("git", ["config", "--get", "core.hooksPath"], cwd, GIT_BUDGET_MS);
	if (hooksPath.timedOut || hooksPath.exitCode !== 1) return false;
	for (const lane of ["pre-commit", "commit-msg"]) {
		const file = resolve(hooksDir, lane);
		if (!executableFile(file) || !carriesMarker(file)) return false;
	}
	return true;
}

/** Pre-commit gate: the Pi port of `hooks/pre-commit-check.sh`, same contract.
 * On a git commit, defer to the working directory's armed git hooks — both
 * pre-commit and commit-msg, marked and executable (`kendex guard install`
 * arms them). Where one is armed, a word that sidesteps it is refused: git
 * would skip commit-msg too, and nothing here can check the message. Otherwise
 * the commit is refused naming that command: arming is the local act that asks
 * for those scripts, and this gate never runs them on its behalf. It gates the
 * working directory only, never following `-C`, `cd`, `--git-dir` or
 * `--work-tree`, and names the directory it judged where it cannot defer. */
export async function preCommitGate(command: string, cwd: string): Promise<PreCommitVerdict> {
	const scan = scanCommand(command);
	// A construct this gate does not model can hide a commit or the flag that
	// skips its hooks, so it is refused rather than parsed harder.
	if (scan.unmodelled) {
		return { kind: "refuse", reason: `pi-hooks pre-commit: this command carries ${scan.unmodelled}, which this gate does not model, so it cannot tell whether the commit in it skips the repository's git hooks. Write the command without that construct.` };
	}
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
