import { accessSync, constants, existsSync, realpathSync, statSync } from "node:fs";
import { spawn } from "node:child_process";
import { isAbsolute, relative, resolve } from "node:path";

import { findCargoWorkspaceRootResultAsync, runCargoAsync, runWorkspaceClippyAsync } from "./cargo.js";

/**
 * Match a bash command that is exactly `cd <target>` with no shell operators
 * that would scope the directory change (no `&&`, `||`, `|`, `;`, parens,
 * backticks, `$(...)`, or embedded newlines). Such commands change Pi's CWD
 * across subsequent tool calls and leak state between unrelated tools.
 *
 * Mirrors `hooks/block-bare-cd.sh`.
 */
const BARE_CD = /^cd\s+[^&|;()`$\n]+$/;

export function isBareCd(command: string): boolean {
	return BARE_CD.test(command.trim());
}

function normalizeShell(command: string): string {
	return command.replace(/\\\r?\n/g, " ");
}

export function isGitCommit(command: string): boolean {
	return gitCommitSyntaxCount(command) > 0;
}

function countRegexMatches(pattern: RegExp, text: string): number {
	return [...text.matchAll(new RegExp(pattern.source, "g"))].length;
}

function gitCommitSyntaxCount(command: string): number {
	return countShellCVerb(command, "commit")
		+ countShellDispatchVerb(command, "commit")
		+ (dynamicGitVerbSyntax(command, "commit") ? 1 : 0);
}

function commandMayStageFiles(command: string): boolean {
	return countShellCVerb(command, "add") > 0
		|| countShellDispatchVerb(command, "add") > 0
		|| dynamicGitVerbSyntax(command, "add")
		|| commandMayRunGitAddAlias(command);
}

interface CommandResult {
	exitCode: number;
	stdout: string;
	stderr: string;
	timedOut: boolean;
}

function appendChunk(chunks: Buffer[], chunk: Buffer | string, totalBytes: { value: number }, maxBuffer: number): void {
	const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
	const remaining = maxBuffer - totalBytes.value;
	if (remaining <= 0) return;
	chunks.push(buffer.length > remaining ? buffer.subarray(0, remaining) : buffer);
	totalBytes.value += Math.min(buffer.length, remaining);
}

function runCommand(command: string, args: string[], cwd: string, timeoutMs: number): Promise<CommandResult> {
	return new Promise((resolveResult) => {
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		const stdoutBytes = { value: 0 };
		const stderrBytes = { value: 0 };
		const maxBuffer = 4 * 1024 * 1024;
		let timedOut = false;
		let settled = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let killTimer: ReturnType<typeof setTimeout> | undefined;
		const detached = process.platform !== "win32";

		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(command, args, {
				cwd,
				detached,
				stdio: ["ignore", "pipe", "pipe"],
			});
		} catch (error) {
			resolveResult({ exitCode: -1, stdout: "", stderr: String(error), timedOut });
			return;
		}

		const finish = (exitCode: number, extraStderr = "") => {
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			if (killTimer) clearTimeout(killTimer);
			if (extraStderr) appendChunk(stderr, extraStderr, stderrBytes, maxBuffer);
			resolveResult({
				exitCode,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
				timedOut,
			});
		};

		const killChild = (signal: NodeJS.Signals) => {
			try {
				if (detached && child.pid) {
					process.kill(-child.pid, signal);
					return;
				}
			} catch {
				// Fall through to direct child kill below.
			}
			try {
				child.kill(signal);
			} catch {
				// Process already exited or cannot be signaled; close/error will settle.
			}
		};

		timer = setTimeout(() => {
			timedOut = true;
			killChild("SIGTERM");
			killTimer = setTimeout(() => {
				killChild("SIGKILL");
				finish(-1, `\n${command} ${args.join(" ")} timed out after ${Math.max(1, timeoutMs)}ms and was killed.`);
			}, 1000);
		}, Math.max(1, timeoutMs));

		child.stdout?.on("data", (chunk) => appendChunk(stdout, chunk, stdoutBytes, maxBuffer));
		child.stderr?.on("data", (chunk) => appendChunk(stderr, chunk, stderrBytes, maxBuffer));
		child.on("error", (error) => finish(-1, String(error)));
		child.on("close", (code, signal) => finish(typeof code === "number" ? code : -1, signal ? `\n${signal}` : ""));
	});
}

function runGit(args: string[], cwd: string, timeoutMs: number): Promise<CommandResult> {
	return runCommand("git", args, cwd, timeoutMs);
}

type RustFilesResult = { kind: "ok"; files: string[] } | { kind: "error"; reason: string };

async function gitListRustFiles(cwd: string, args: string[]): Promise<RustFilesResult> {
	const result = await runGit(args, cwd, 5000);
	if (result.timedOut) return { kind: "error", reason: `git ${args.join(" ")} timed out after 5000ms.` };
	if (result.exitCode !== 0) {
		return { kind: "error", reason: (result.stderr || result.stdout).trim() || `git ${args.join(" ")} failed.` };
	}
	return { kind: "ok", files: result.stdout
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line.endsWith(".rs")) };
}

/**
 * Rust files in the working tree that a `git commit` would care about.
 *
 * The hook fires BEFORE the bash command executes, so when the agent issues
 * `git add x.rs && git commit -m '…'` in a single chained command, `git diff
 * --cached --name-only` still reports an empty staged set at this point. To
 * avoid silently letting that through, also count unstaged-but-modified `.rs`
 * files. When the same command contains `git add`, also include untracked `.rs`
 * files that may be staged before the commit runs. If any set is non-empty, the
 * commit is treated as relevant.
 *
 * Returns the union, deduped.
 */
async function rustFilesRelevantToCommit(cwd: string, repoRoot: string, includeUntracked: boolean): Promise<RustFilesResult> {
	const listCwd = repoRoot || cwd;
	const [staged, unstaged, untracked] = await Promise.all([
		gitListRustFiles(listCwd, ["diff", "--cached", "--name-only"]),
		gitListRustFiles(listCwd, ["diff", "--name-only"]),
		includeUntracked ? gitListRustFiles(listCwd, ["ls-files", "--others", "--exclude-standard"]) : Promise.resolve({ kind: "ok" as const, files: [] }),
	]);
	if (staged.kind === "error") return staged;
	if (unstaged.kind === "error") return unstaged;
	if (untracked.kind === "error") return untracked;
	return { kind: "ok", files: [...new Set([...staged.files, ...unstaged.files, ...untracked.files])] };
}

interface ShellWord {
	kind: "word";
	text: string;
	dynamic: boolean;
}

interface ShellOperator {
	kind: "op";
	text: string;
}

type ShellToken = ShellWord | ShellOperator;

function decodeAnsiCString(input: string): { text: string; unknown: boolean } {
	let unknown = false;
	const text = input.replace(/\\(?:([0-7]{1,3})|x([0-9a-fA-F]{1,2})|u([0-9a-fA-F]{1,4})|U([0-9a-fA-F]{1,8})|([abfnrtv\\'"?])|(.)|$)/g, (_match, octal, hex, unicode, wide, simple, unsupported) => {
		const code = octal ? Number.parseInt(octal, 8) : Number.parseInt(hex ?? unicode ?? wide ?? "", 16);
		if (!Number.isNaN(code)) return String.fromCodePoint(code);
		if (simple) {
			const map: Record<string, string> = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", "\\": "\\", "'": "'", '"': '"', "?": "?" };
			return map[simple as string] ?? String(simple);
		}
		unknown = true;
		return unsupported ? `\\${unsupported}` : "\\";
	});
	return { text, unknown };
}

export interface GitCommitTarget {
	/** Worktree directory in effect when `git commit` runs, or null when shell expansion hides it. */
	cwd: string | null;
	/** True when the target is known to be a temp/external path without needing filesystem probes. */
	external: boolean;
	/** True when shell expansion prevents resolving the target safely. */
	unknown: boolean;
	/** Whether the invocation included `--git-dir`. */
	hasGitDir: boolean;
	/** Explicit `--git-dir` when present, resolved when statically knowable. */
	gitDir: string | null;
	/** Whether the invocation included `--work-tree`. */
	hasWorkTree: boolean;
	/** Explicit `--work-tree` when present, resolved when statically knowable. */
	workTree: string | null;
	/** First non-option git subcommand that may be a configured alias. */
	aliasName?: string;
}

interface ShellPathRef {
	path: string | null;
	external: boolean;
	unknown: boolean;
}

type ShellVariables = Map<string, ShellPathRef>;
type ShellTextVariables = Map<string, string>;

interface ShellContext {
	cwd: string | null;
	external: boolean;
	unknown: boolean;
}

interface PendingCommand {
	kind: "cd" | "other";
	before: ShellContext;
	after?: ShellContext;
	conditional: boolean;
	scoped: boolean;
}

function isShellOperatorStart(command: string, index: number): string | null {
	const two = command.slice(index, index + 2);
	if (two === "&&" || two === "||") return two;
	const one = command[index];
	if (one === ";" || one === "|" || one === "(" || one === ")" || one === "{" || one === "}" || one === "\n") return one;
	return null;
}

function tokenizeShell(command: string): ShellToken[] {
	command = normalizeShell(command);
	const tokens: ShellToken[] = [];
	let i = 0;
	while (i < command.length) {
		const ch = command[i];
		const op = isShellOperatorStart(command, i);
		if (op) {
			tokens.push({ kind: "op", text: op });
			i += op.length;
			continue;
		}
		if (/\s/.test(ch)) {
			i += 1;
			continue;
		}

		let text = "";
		let dynamic = false;
		while (i < command.length) {
			const current = command[i];
			if (/\s/.test(current) || isShellOperatorStart(command, i)) break;

			if (current === "$" && command[i + 1] === "'") {
				i += 2;
				let ansi = "";
				while (i < command.length && command[i] !== "'") {
					ansi += command[i];
					i += 1;
				}
				const decoded = decodeAnsiCString(ansi);
				text += decoded.text;
				dynamic ||= decoded.unknown;
				if (command[i] === "'") i += 1;
				continue;
			}

			if (current === "'") {
				i += 1;
				while (i < command.length && command[i] !== "'") {
					text += command[i];
					i += 1;
				}
				if (command[i] === "'") i += 1;
				continue;
			}

			if (current === '"') {
				i += 1;
				while (i < command.length && command[i] !== '"') {
					const quoted = command[i];
					if (quoted === "\\" && i + 1 < command.length) {
						text += command[i + 1];
						i += 2;
						continue;
					}
					if (quoted === "$" || quoted === "`") dynamic = true;
					text += quoted;
					i += 1;
				}
				if (command[i] === '"') i += 1;
				continue;
			}

			if (current === "\\" && i + 1 < command.length) {
				text += command[i + 1];
				i += 2;
				continue;
			}

			if (current === "$" && command[i + 1] === "(") {
				const start = i;
				i += 2;
				let depth = 1;
				while (i < command.length && depth > 0) {
					if (command[i] === "\\" && i + 1 < command.length) {
						i += 2;
						continue;
					}
					if (command[i] === "(") depth += 1;
					else if (command[i] === ")") depth -= 1;
					i += 1;
				}
				text += command.slice(start, i);
				dynamic = true;
				continue;
			}

			if (current === "$" || current === "`" || current === "~" || current === "*" || current === "?") dynamic = true;
			text += current;
			i += 1;
		}

		if (text) tokens.push({ kind: "word", text, dynamic });
	}
	return tokens;
}

function isWord(token: ShellToken | undefined): token is ShellWord {
	return token?.kind === "word";
}

function executableName(word: string): string {
	const slash = word.lastIndexOf("/");
	return slash >= 0 ? word.slice(slash + 1) : word;
}

function isGitExecutable(word: string): boolean {
	return executableName(word) === "git";
}

function isEnvExecutable(word: string): boolean {
	return executableName(word) === "env";
}

function shellExecutableName(word: string): string {
	return executableName(word);
}

function shellCommandContainsGitVerb(commandWord: ShellWord | undefined, verb: "add" | "commit"): boolean {
	if (!commandWord) return false;
	const rawText = commandWord.text;
	const variableCommand = new RegExp(`(?:^|[\\s;&|({!])\\$(?:[0-9]+|[A-Za-z_][A-Za-z0-9_]*|\\{[^}]+\\})\\s+(?:${verb}|\\$\\{[^}]*${verb}[^}]*\\})(?=$|[\\s;&|){}])`);
	if (variableCommand.test(rawText)) return true;
	if (/shopt\s+-s\s+expand_aliases/.test(rawText)) {
		const alias = /alias\s+([A-Za-z_][A-Za-z0-9_]*)=git/.exec(rawText);
		if (alias && new RegExp(`(?:^|[\\s;&|({!])${alias[1]}\\s+${verb}(?=$|[\\s;&|){}])`).test(rawText)) return true;
	}
	if (/(^|[\s;&|({!])(?:[^\s;&|(){}]+\/)?git\b/.test(rawText) && /(?:\$\(|`|\$(?:@|\*|[0-9]|[A-Za-z_][A-Za-z0-9_]*|\{[^}]+\}))/.test(rawText)) return true;
	let text = rawText;
	if (text.startsWith("$")) text = text.slice(1);
	if (/(^|[\s;&|({!])(?:[^\s;&|(){}]+\/)?git\b/.test(text) && /\$(?:@|\*|[0-9]|[A-Za-z_][A-Za-z0-9_]*|\{(?:@|\*|[0-9]+|[A-Za-z_][A-Za-z0-9_]*)\})/.test(text)) return true;
	if (commandWord.dynamic && !/(?:[^\s;&|(){}]+\/)?git(?:\s+[^\s;&|(){}]+)*\s+(?:add|commit)(?=$|\s|[;&|){}])/.test(text)) return true;
	const verbPattern = verb === "add"
		? /(^|[\s;&|({!])(?:[^\s;&|(){}]+\/)?git(?:\s+[^\s;&|(){}]+)*\s+add(?=$|[\s;&|){}])/
		: /(^|[\s;&|({!])(?:[^\s;&|(){}]+\/)?git(?:\s+[^\s;&|(){}]+)*\s+commit(?=$|[\s;&|){}])/;
	return verbPattern.test(text);
}

function dynamicGitVerbSyntax(command: string, verb: "add" | "commit"): boolean {
	const normalized = normalizeShell(command);
	const boundary = `(?:^|[\\s;&|({!])`;
	const end = `(?=$|[\\s;&|){}])`;
	const fieldSplitGit = new RegExp(`${boundary}git(?:\\$IFS|\\$\\{IFS\\})(?:\\s+)?(?:${verb}|\\$(?:[A-Za-z_][A-Za-z0-9_]*|\\{[A-Za-z_][A-Za-z0-9_]*\\}))${end}`);
	const variableGit = new RegExp(`${boundary}\\$(?:[0-9]+|[A-Za-z_][A-Za-z0-9_]*|\\{[^}]+\\})\\s+(?:${verb}|\\$\\{[^}]*${verb}[^}]*\\}|\\$[A-Za-z_][A-Za-z0-9_]*)${end}`);
	const commandSubGit = new RegExp(`${boundary}(?:\\$\\([^)]*git[^)]*\\)|\`[^\`]*git[^\`]*\`)(?:\\$IFS|\\$\\{IFS\\}|\\s+)${verb}${end}`);
	const commandSubFull = new RegExp(`${boundary}(?:\\$\\([^)]*git[^)]*${verb}[^)]*\\)|\`[^\`]*git[^\`]*${verb}[^\`]*\`)(?:\\s+[^;&|(){}]+)*${end}`);
	return fieldSplitGit.test(normalized) || variableGit.test(normalized) || commandSubGit.test(normalized) || commandSubFull.test(normalized);
}

function countShellDispatchVerb(command: string, verb: "add" | "commit"): number {
	const normalized = normalizeShell(command);
	const literalPayload = `git(?:\\s+[^'"]+)*\\s+${verb}(?=$|['"\\s;&|){}])`;
	const dynamicPayload = `(?:git[^'"]*(?:\\$|\`)|(?:\\$[0-9]+|\\$[A-Za-z_][A-Za-z0-9_]*|\\$\\{(?:[0-9]+|[A-Za-z_][A-Za-z0-9_]*)\\})\\s+${verb}(?=$|['"\\s;&|){}]))`;
	const quotedPayload = `(?:\\$?['"][^'"]*(?:${literalPayload}|${dynamicPayload})[^'"]*['"])`;
	const evalPattern = new RegExp(`(?:^|[\\s;&|({!])eval\\s+${quotedPayload}`, "g");
	const hereStringPattern = new RegExp(`(?:^|[\\s;&|({!])(?:[^\\s;&|(){}]+\\/)?(?:sh|bash|zsh|dash)(?:\\s+[^;&|(){}<>]+)*\\s*<<<\\s*${quotedPayload}`, "g");
	const pipePattern = new RegExp(`(?:^|[\\s;&|({!])(?:printf|echo)\\s+${quotedPayload}(?:\\s+[^|]*)?\\|\\s*(?:[^\\s;&|(){}]+\\/)?(?:sh|bash|zsh|dash)(?=$|[\\s;&|){}])`, "g");
	let count = countRegexMatches(evalPattern, normalized) + countRegexMatches(hereStringPattern, normalized) + countRegexMatches(pipePattern, normalized);
	const tokens = tokenizeShell(command);
	for (let index = 0; index < tokens.length; index += 1) {
		if (isWord(tokens[index]) && (tokens[index] as ShellWord).text === "eval" && shellCommandContainsGitVerb(isWord(tokens[index + 1]) ? tokens[index + 1] : undefined, verb)) count += 1;
	}
	return count;
}

function countShellCVerb(command: string, verb: "add" | "commit"): number {
	const tokens = tokenizeShell(command);
	let count = 0;
	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (!isWord(token)) continue;
		if (!["sh", "bash", "zsh", "dash"].includes(shellExecutableName(token.text))) continue;

		let j = i + 1;
		while (isWord(tokens[j])) {
			const option = tokens[j] as ShellWord;
			if (option.text === "--") {
				j += 1;
				continue;
			}
			if (!option.text.startsWith("-") && !option.text.startsWith("+")) break;
			if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.text)) {
				const payloadIndex = isWord(tokens[j + 1]) && (tokens[j + 1] as ShellWord).text === "--" ? j + 2 : j + 1;
				if (shellCommandContainsGitVerb(isWord(tokens[payloadIndex]) ? tokens[payloadIndex] : undefined, verb)) count += 1;
				break;
			}
			if (option.text === "-o" || option.text === "-O" || option.text === "+o" || option.text === "+O" || option.text === "--rcfile" || option.text === "--init-file") {
				j += isWord(tokens[j + 1]) ? 2 : 1;
				continue;
			}
			j += 1;
		}
	}
	return count;
}

const KNOWN_NON_STAGING_GIT_COMMANDS = new Set([
	"archive", "bisect", "blame", "branch", "checkout", "clone", "commit", "config", "describe", "diff", "fetch", "grep",
	"help", "init", "log", "ls-files", "merge", "pull", "push", "rebase", "remote", "restore", "rev-parse", "show", "stash",
	"status", "switch", "tag", "version", "worktree",
]);

const KNOWN_NON_COMMIT_GIT_COMMANDS = new Set([...KNOWN_NON_STAGING_GIT_COMMANDS, "add"]);

function parseGitMayRunAdd(tokens: ShellToken[], gitIndex: number): { mayStage: boolean; next: number } {
	const aliases = new Map<string, string | null>();
	let j = gitIndex + 1;
	while (j < tokens.length) {
		const token = tokens[j];
		if (!isWord(token)) break;
		const word = token.text;
		if (word === "-c" || word === "--config-env" || word === "--namespace") {
			const consumed = nextWord(tokens, j + 1);
			if (consumed.token) {
				if (word === "-c") recordInlineAlias(consumed.token.text, aliases, new Map());
				else if (word === "--config-env") recordInlineAlias(consumed.token.text, aliases, new Map(), true);
			}
			j = consumed.token ? consumed.index + 1 : j + 1;
			continue;
		}
		if (word.startsWith("-c") && word.length > 2) {
			recordInlineAlias(word.slice(2), aliases, new Map());
			j += 1;
			continue;
		}
		if (word.startsWith("--config-env=")) {
			recordInlineAlias(word.slice("--config-env=".length), aliases, new Map(), true);
			j += 1;
			continue;
		}
		if (["-C", "--git-dir", "--work-tree", "--exec-path", "--html-path", "--man-path", "--info-path"].includes(word)) {
			const consumed = nextWord(tokens, j + 1);
			j = consumed.token ? consumed.index + 1 : j + 1;
			continue;
		}
		if (word.startsWith("-C") || word.startsWith("--git-dir=") || word.startsWith("--work-tree=") || word.startsWith("--exec-path=")) {
			j += 1;
			continue;
		}
		if (word.startsWith("-")) {
			j += 1;
			continue;
		}
		if (word === "add" || token.dynamic) return { mayStage: true, next: j + 1 };
		if (aliases.has(word)) {
			const alias = aliases.get(word);
			return { mayStage: alias === null || aliasValueMatchesVerb(alias, "add", null, new Map(), new Map()) !== "non-match", next: j + 1 };
		}
		return { mayStage: !KNOWN_NON_STAGING_GIT_COMMANDS.has(word), next: j + 1 };
	}
	return { mayStage: false, next: j };
}

function commandMayRunGitAddAlias(command: string): boolean {
	const tokens = tokenizeShell(command);
	const textVariables: ShellTextVariables = new Map();
	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (!isWord(token)) continue;
		if (isAssignment(token.text)) recordTextAssignment(token, textVariables);
		if (dynamicCommandStartGitVerb(token, isWord(tokens[i + 1]) ? tokens[i + 1] : undefined, "add", textVariables)) return true;
		if (isEnvExecutable(token.text)) {
			let j = i + 1;
			while (isWord(tokens[j])) {
				const word = (tokens[j] as ShellWord).text;
				if (word === "-S" || word === "--split-string") {
					const consumed = nextWord(tokens, j + 1);
					if (consumed.token && commandMayStageFiles(consumed.token.text)) return true;
					break;
				}
				const shortSplit = /^-[A-Za-z]*S(.*)$/.exec(word);
				if (shortSplit && word !== "-S") {
					if (shortSplit[1] ? commandMayStageFiles(shortSplit[1]) : commandMayStageFiles((nextWord(tokens, j + 1).token?.text) ?? "")) return true;
					break;
				}
				if (word.startsWith("--split-string=")) {
					if (commandMayStageFiles(word.slice("--split-string=".length))) return true;
					break;
				}
				if (!word.startsWith("-") && !isAssignment(word)) break;
				j += 1;
			}
		}
		if (isGitExecutable(token.text)) {
			const parsed = parseGitMayRunAdd(tokens, i);
			if (parsed.mayStage) return true;
			i = Math.max(i, parsed.next - 1);
		}
	}
	return false;
}

function isAssignment(word: string): boolean {
	return /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);
}

function unknownPath(): ShellPathRef {
	return { path: null, external: false, unknown: true };
}

function externalPath(): ShellPathRef {
	return { path: null, external: true, unknown: false };
}

function literalPath(base: string | null, text: string): ShellPathRef {
	if (!base || !text) return unknownPath();
	if (text === "/proc/self/cwd") return { path: resolve(base), external: false, unknown: false };
	if (text.startsWith("/proc/self/cwd/")) return { path: resolve(base, text.slice("/proc/self/cwd/".length)), external: false, unknown: false };
	return { path: isAbsolute(text) ? resolve(text) : resolve(base, text), external: false, unknown: false };
}

function shellContext(ref: ShellPathRef): ShellContext {
	return { cwd: ref.path, external: ref.external, unknown: ref.unknown };
}

function cloneContext(ctx: ShellContext): ShellContext {
	return { cwd: ctx.cwd, external: ctx.external, unknown: ctx.unknown };
}

function directoryExists(path: string): boolean {
	try {
		if (!existsSync(path) || !statSync(path).isDirectory()) return false;
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

function variableRef(text: string): string | null {
	const bare = /^\$([A-Za-z_][A-Za-z0-9_]*)$/.exec(text);
	if (bare) return bare[1];
	const braced = /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/.exec(text);
	return braced ? braced[1] : null;
}

function resolveShellPath(base: string | null, word: ShellWord | undefined, variables: ShellVariables): ShellPathRef {
	if (!word) return unknownPath();
	if (!word.dynamic) return literalPath(base, word.text);
	const ref = variableRef(word.text);
	if (ref && variables.has(ref)) return variables.get(ref)!;
	return unknownPath();
}

function recordAssignment(word: ShellWord, base: string | null, variables: ShellVariables): void {
	const separator = word.text.indexOf("=");
	if (separator <= 0) return;
	const name = word.text.slice(0, separator);
	const value = word.text.slice(separator + 1);
	if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return;
	if (/^\$\(\s*mktemp(\s|\))/.test(value) || /^`\s*mktemp(\s|`)/.test(value)) {
		variables.set(name, externalPath());
		return;
	}
	if (!word.dynamic) {
		variables.set(name, literalPath(base, value));
		return;
	}
	const ref = variableRef(value);
	variables.set(name, ref && variables.has(ref) ? variables.get(ref)! : unknownPath());
}

function recordTextAssignment(word: ShellWord, variables: ShellTextVariables): void {
	const separator = word.text.indexOf("=");
	if (separator <= 0) return;
	const name = word.text.slice(0, separator);
	const value = word.text.slice(separator + 1);
	if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return;
	if (word.dynamic) {
		if (name.startsWith("GIT_CONFIG_") || name === "HOME" || name === "XDG_CONFIG_HOME") variables.set("__GIT_CONFIG_UNKNOWN", "1");
		variables.delete(name);
	} else {
		variables.set(name, value);
	}
}

function resolvedCommandText(word: ShellWord, variables: ShellTextVariables): string | null {
	if (!word.dynamic) return word.text;
	const ref = variableRef(word.text);
	return ref ? variables.get(ref) ?? null : null;
}

function dynamicCommandStartGitVerb(word: ShellWord, next: ShellWord | undefined, verb: "add" | "commit", variables: ShellTextVariables): boolean {
	if (!word.dynamic) return false;
	if (new RegExp(`^git(?:\\$IFS|\\$\\{IFS\\})(?:${verb}|\\s+${verb})$`).test(word.text)) return true;
	const commandSub = /^(?:\$\([^)]*git[^)]*\)|`[^`]*git[^`]*`)/.test(word.text);
	if (commandSub && (word.text.includes(verb) || new RegExp(`(?:\\$IFS|\\$\\{IFS\\})${verb}$`).test(word.text) || next?.text === verb || next?.dynamic)) return true;
	const fieldSplitVar = /^git(?:\$IFS|\$\{IFS\})(?:\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([A-Za-z_][A-Za-z0-9_]*)\})$/.exec(word.text);
	if (fieldSplitVar) return (variables.get(fieldSplitVar[1] ?? fieldSplitVar[2]) ?? verb) === verb;
	if (next && (next.text === verb || next.dynamic)) {
		if (/^(?:\$\(|`|\$[A-Za-z_][A-Za-z0-9_]*$|\$\{[^}]+\}$)/.test(word.text)) return true;
	}
	return false;
}

function nextWord(tokens: ShellToken[], start: number): { token: ShellWord | undefined; index: number } {
	let index = start;
	while (tokens[index]?.kind === "op" && tokens[index]?.text === "\n") index += 1;
	return { token: isWord(tokens[index]) ? tokens[index] : undefined, index };
}

function consumePathOption(
	tokens: ShellToken[],
	index: number,
	currentCwd: string | null,
	variables: ShellVariables,
): { ref: ShellPathRef; next: number } {
	const { token, index: valueIndex } = nextWord(tokens, index);
	return { ref: resolveShellPath(currentCwd, token, variables), next: token ? valueIndex + 1 : index + 1 };
}

type AliasVerbDecision = "match" | "non-match" | "unknown";

function aliasCommand(value: string): { command: string; shell: boolean } {
	const trimmed = value.trim();
	return trimmed.startsWith("!") ? { command: trimmed.slice(1), shell: true } : { command: `git ${trimmed}`, shell: false };
}

function aliasValueMatchesVerb(value: string, verb: "add" | "commit", cwd: string | null, variables: ShellVariables, textVariables: ShellTextVariables): AliasVerbDecision {
	if (!value.trim()) return "non-match";
	const { command, shell } = aliasCommand(value);
	if (verb === "commit") {
		const targets = gitCommitTargets(command, cwd ?? process.cwd(), variables, textVariables);
		if (targets.some((target) => target.unknown || target.aliasName)) return "unknown";
		if (targets.length > 0 || gitCommitSyntaxCount(command) > 0) return "match";
		return shell ? "unknown" : "non-match";
	}
	if (commandMayStageFiles(command)) return "match";
	return shell ? "unknown" : "non-match";
}

function recordInlineAlias(config: string, aliases: Map<string, string | null>, textVariables: ShellTextVariables, fromConfigEnv = false): void {
	if (fromConfigEnv) {
		const configEnv = /^alias\.([^=]+)=([A-Za-z_][A-Za-z0-9_]*)$/i.exec(config);
		if (configEnv) aliases.set(configEnv[1].toLowerCase(), textVariables.get(configEnv[2]) ?? null);
		return;
	}
	const direct = /^alias\.([^=]+)=(.*)$/i.exec(config);
	if (direct) aliases.set(direct[1].toLowerCase(), direct[2]);
}

function collectEnvConfigAliases(textVariables: ShellTextVariables, aliases: Map<string, string | null>): boolean {
	if (textVariables.get("__GIT_CONFIG_UNKNOWN") === "1") return true;
	for (const [name, value] of textVariables) {
		if (name.startsWith("__GIT_ALIAS_")) aliases.set(name.slice("__GIT_ALIAS_".length), value);
	}
	for (const source of ["GIT_CONFIG_PARAMETERS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "HOME", "XDG_CONFIG_HOME"]) {
		if (textVariables.has(source)) return true;
	}
	const countText = textVariables.get("GIT_CONFIG_COUNT");
	if (!countText) return false;
	const count = Number.parseInt(countText, 10);
	if (!Number.isFinite(count) || count < 0) return true;
	let unknown = false;
	for (let index = 0; index < count; index += 1) {
		const key = textVariables.get(`GIT_CONFIG_KEY_${index}`);
		const value = textVariables.get(`GIT_CONFIG_VALUE_${index}`);
		if (!key || value === undefined) {
			unknown = true;
			continue;
		}
		const keyLower = key.toLowerCase();
		if (/^include(?:if\..*)?\.path$/.test(keyLower)) unknown = true;
		const alias = /^alias\.([^=]+)$/.exec(keyLower);
		if (alias) aliases.set(alias[1], value);
	}
	return unknown;
}

function recordGitConfigMutation(tokens: ShellToken[], gitIndex: number, textVariables: ShellTextVariables): { recorded: boolean; next: number } {
	let index = gitIndex + 1;
	while (isWord(tokens[index])) {
		const word = (tokens[index] as ShellWord).text;
		if (["-C", "--git-dir", "--work-tree", "--exec-path", "-c", "--config-env"].includes(word)) {
			const consumed = nextWord(tokens, index + 1);
			index = consumed.token ? consumed.index + 1 : index + 1;
			continue;
		}
		if (word.startsWith("-C") || word.startsWith("--git-dir=") || word.startsWith("--work-tree=") || word.startsWith("--exec-path=") || word.startsWith("-c") || word.startsWith("--config-env=")) {
			index += 1;
			continue;
		}
		break;
	}
	if (!isWord(tokens[index]) || (tokens[index] as ShellWord).text.toLowerCase() !== "config") return { recorded: false, next: index };
	index += 1;
	while (isWord(tokens[index])) {
		const option = tokens[index] as ShellWord;
		if (["--file", "-f", "--global", "--system", "--local", "--worktree", "--blob", "--type", "--get", "--get-all"].includes(option.text)) {
			const takesValue = ["--file", "-f", "--blob", "--type"].includes(option.text);
			index += takesValue && isWord(tokens[index + 1]) ? 2 : 1;
			continue;
		}
		if (option.text.startsWith("--file=") || option.text.startsWith("--blob=") || option.text.startsWith("--type=")) {
			index += 1;
			continue;
		}
		if (option.text.startsWith("-") && option.text !== "--") {
			index += 1;
			continue;
		}
		break;
	}
	if (!isWord(tokens[index])) return { recorded: false, next: index };
	const keyToken = tokens[index] as ShellWord;
	const key = resolvedCommandText(keyToken, textVariables) ?? keyToken.text;
	if (keyToken.dynamic && !resolvedCommandText(keyToken, textVariables)) textVariables.set("__GIT_CONFIG_UNKNOWN", "1");
	const keyLower = key.toLowerCase();
	if (/^include(?:if\..*)?\.path$/.test(keyLower)) {
		textVariables.set("__GIT_CONFIG_UNKNOWN", "1");
		return { recorded: true, next: index + 1 };
	}
	const alias = /^alias\.([^=]+)$/.exec(keyLower);
	if (!alias) return { recorded: false, next: index + 1 };
	const value = isWord(tokens[index + 1]) ? (tokens[index + 1] as ShellWord).text : null;
	if (value === null || (tokens[index + 1] as ShellWord).dynamic) textVariables.set("__GIT_CONFIG_UNKNOWN", "1");
	else textVariables.set(`__GIT_ALIAS_${alias[1]}`, value);
	return { recorded: true, next: value === null ? index + 1 : index + 2 };
}

function parseGitTarget(
	tokens: ShellToken[],
	gitIndex: number,
	shellCwd: string | null,
	shellExternal: boolean,
	shellUnknown: boolean,
	variables: ShellVariables,
	textVariables: ShellTextVariables,
): { target: GitCommitTarget | null; next: number } {
	let currentCwd = shellCwd;
	let external = shellExternal;
	let unknown = shellUnknown;
	const gitDirRef = variables.get("GIT_DIR");
	const workTreeRef = variables.get("GIT_WORK_TREE");
	let hasGitDir = Boolean(gitDirRef);
	let gitDir: string | null = gitDirRef?.path ?? null;
	let hasWorkTree = Boolean(workTreeRef);
	let workTree: string | null = workTreeRef?.path ?? null;
	external ||= Boolean(gitDirRef?.external || workTreeRef?.external);
	unknown ||= Boolean(gitDirRef?.unknown || workTreeRef?.unknown);
	const aliases = new Map<string, string | null>();
	let aliasConfigMayDefineUnknown = collectEnvConfigAliases(textVariables, aliases);
	const recordConfig = (config: ShellWord, fromConfigEnv = false) => {
		const resolved = resolvedCommandText(config, textVariables);
		if (config.dynamic && !resolved) aliasConfigMayDefineUnknown = true;
		const configText = resolved ?? config.text;
		const configLower = configText.toLowerCase();
		if (config.dynamic && configText.includes("=")) aliasConfigMayDefineUnknown = true;
		if (/^include(?:if\..*)?\.path(?:=|$)/.test(configLower)) aliasConfigMayDefineUnknown = true;
		recordInlineAlias(configText, aliases, textVariables, fromConfigEnv);
	};
	let j = gitIndex + 1;

	while (j < tokens.length) {
		const token = tokens[j];
		if (!isWord(token)) break;
		const word = token.text;

		if (word === "-C") {
			const consumed = consumePathOption(tokens, j + 1, currentCwd, variables);
			currentCwd = consumed.ref.path;
			external ||= consumed.ref.external;
			unknown ||= consumed.ref.unknown;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("-C") && word.length > 2) {
			const ref = resolveShellPath(currentCwd, { kind: "word", text: word.slice(2), dynamic: token.dynamic }, variables);
			currentCwd = ref.path;
			external ||= ref.external;
			unknown ||= ref.unknown;
			j += 1;
			continue;
		}
		if (word === "--git-dir") {
			const consumed = consumePathOption(tokens, j + 1, currentCwd, variables);
			hasGitDir = true;
			gitDir = consumed.ref.path;
			external ||= consumed.ref.external;
			unknown ||= consumed.ref.unknown;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("--git-dir=")) {
			hasGitDir = true;
			const ref = resolveShellPath(currentCwd, { kind: "word", text: word.slice("--git-dir=".length), dynamic: token.dynamic }, variables);
			gitDir = ref.path;
			external ||= ref.external;
			unknown ||= ref.unknown;
			j += 1;
			continue;
		}
		if (word === "--work-tree") {
			const consumed = consumePathOption(tokens, j + 1, currentCwd, variables);
			hasWorkTree = true;
			workTree = consumed.ref.path;
			external ||= consumed.ref.external;
			unknown ||= consumed.ref.unknown;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("--work-tree=")) {
			hasWorkTree = true;
			const ref = resolveShellPath(currentCwd, { kind: "word", text: word.slice("--work-tree=".length), dynamic: token.dynamic }, variables);
			workTree = ref.path;
			external ||= ref.external;
			unknown ||= ref.unknown;
			j += 1;
			continue;
		}
		if (word === "-c" || word === "--config-env" || word === "--namespace") {
			const consumed = nextWord(tokens, j + 1);
			if (consumed.token) {
				if (word === "-c") recordConfig(consumed.token);
				else if (word === "--config-env") recordConfig(consumed.token, true);
			}
			j = consumed.token ? consumed.index + 1 : j + 1;
			continue;
		}
		if (word.startsWith("-c") && word.length > 2) {
			recordConfig({ kind: "word", text: word.slice(2), dynamic: token.dynamic });
			j += 1;
			continue;
		}
		if (word.startsWith("--config-env=")) {
			recordConfig({ kind: "word", text: word.slice("--config-env=".length), dynamic: token.dynamic }, true);
			j += 1;
			continue;
		}
		if (word === "--exec-path" || word === "--html-path" || word === "--man-path" || word === "--info-path") {
			const consumed = nextWord(tokens, j + 1);
			j = consumed.token ? consumed.index + 1 : j + 1;
			continue;
		}
		if (word.startsWith("--exec-path=")) {
			j += 1;
			continue;
		}
		if (word.startsWith("-")) {
			j += 1;
			continue;
		}

		const commandWord = word.toLowerCase();
		if (commandWord === "commit") return { target: { cwd: currentCwd, external, unknown, hasGitDir, gitDir, hasWorkTree, workTree }, next: j + 1 };
		if (token.dynamic) return { target: { cwd: currentCwd, external, unknown: true, hasGitDir, gitDir, hasWorkTree, workTree }, next: j + 1 };
		if (aliases.has(commandWord)) {
			const alias = aliases.get(commandWord);
			const decision = alias === null ? "unknown" : aliasValueMatchesVerb(alias, "commit", currentCwd, variables, textVariables);
			return {
				target: decision === "non-match" ? null : { cwd: currentCwd, external, unknown: unknown || decision === "unknown", hasGitDir, gitDir, hasWorkTree, workTree },
				next: j + 1,
			};
		}

		if (KNOWN_NON_COMMIT_GIT_COMMANDS.has(commandWord)) return { target: null, next: j + 1 };

		return { target: { cwd: currentCwd, external, unknown: unknown || aliasConfigMayDefineUnknown, hasGitDir, gitDir, hasWorkTree, workTree, aliasName: commandWord }, next: j + 1 };
	}

	return { target: null, next: j };
}

export function gitCommitTargets(command: string, cwd: string, initialVariables?: ShellVariables, initialTextVariables?: ShellTextVariables): GitCommitTarget[] {
	const tokens = tokenizeShell(command);
	const targets: GitCommitTarget[] = [];
	const variables: ShellVariables = new Map(initialVariables ?? []);
	const prefixGitVariables: ShellVariables = new Map();
	const textVariables: ShellTextVariables = new Map(initialTextVariables ?? []);
	const prefixTextVariables: ShellTextVariables = new Map();
	const scopeStack: ShellContext[] = [];
	const shellAliases = new Map<string, string>();
	let ctx: ShellContext = { cwd: resolve(cwd), external: false, unknown: false };
	let pending: PendingCommand | null = null;
	let commandStart = true;
	let expandAliases = false;
	let nextCommandConditional = false;
	let nextCommandScoped = false;
	const controlBoundaries = new Set(["if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "select", "case", "esac", "in"]);
	const envValueOptions = new Set(["-u", "--unset", "-S", "--ignore-signal", "--block-signal", "--default-signal", "--argv0"]);

	const finishPending = (operator: string) => {
		if (!pending) return;
		if (pending.kind === "cd" && pending.after) {
			if (pending.conditional || pending.scoped) {
				ctx = cloneContext(pending.before);
			} else if (operator === "&&") {
				ctx = pending.after.cwd && directoryExists(pending.after.cwd) ? cloneContext(pending.after) : cloneContext(pending.before);
			} else if (operator === "||" || operator === ")" || operator === "|") {
				ctx = cloneContext(pending.before);
			} else if ((pending.after.external || pending.after.unknown) && !pending.after.cwd) {
				ctx = cloneContext(pending.before);
			} else if (pending.after.cwd && directoryExists(pending.after.cwd)) {
				ctx = cloneContext(pending.after);
			} else {
				ctx = cloneContext(pending.before);
			}
		}
		pending = null;
	};

	const pendingCommand = (kind: PendingCommand["kind"], before: ShellContext, after?: ShellContext): PendingCommand => ({
		kind,
		before,
		after,
		conditional: nextCommandConditional,
		scoped: nextCommandScoped,
	});

	const markCommandConsumed = () => {
		nextCommandConditional = false;
		nextCommandScoped = false;
		prefixGitVariables.clear();
		prefixTextVariables.clear();
	};

	const promotePrefixAssignments = () => {
		for (const [name, ref] of prefixGitVariables) variables.set(name, ref);
		for (const [name, value] of prefixTextVariables) textVariables.set(name, value);
		prefixGitVariables.clear();
		prefixTextVariables.clear();
	};

	const gitCommandVariables = (): ShellVariables => new Map([...variables, ...prefixGitVariables]);
	const gitTextVariables = (): ShellTextVariables => new Map([...textVariables, ...prefixTextVariables]);
	const resolvedExecutable = (word: ShellWord): string => shellAliases.get(word.text) ?? resolvedCommandText(word, gitTextVariables()) ?? word.text;
	const envSplitTargets = (payload: string, envCtx: ShellContext, envVariables: ShellVariables, envTextVariables: ShellTextVariables): GitCommitTarget[] => {
		const splitTargets = gitCommitTargets(payload, envCtx.cwd ?? cwd, envVariables, envTextVariables).map((target) => ({
			...target,
			external: target.external || envCtx.external,
			unknown: target.unknown || envCtx.unknown,
		}));
		if (splitTargets.length === 0 && isGitCommit(payload)) {
			return [{ cwd: envCtx.cwd, external: envCtx.external, unknown: envCtx.unknown, hasGitDir: false, gitDir: null, hasWorkTree: false, workTree: null }];
		}
		return splitTargets;
	};

	const parseEnvWrapper = (index: number): { targets: GitCommitTarget[] | null; parsed: ReturnType<typeof parseGitTarget> | null; envIndex: number } => {
		let envIndex = index + 1;
		let envCtx = cloneContext(ctx);
		const envVariables: ShellVariables = gitCommandVariables();
		const envTextVariables: ShellTextVariables = gitTextVariables();
		while (isWord(tokens[envIndex])) {
			const envWord = tokens[envIndex] as ShellWord;
			if (envWord.text === "--") {
				envIndex += 1;
				break;
			}
			if (envWord.text === "-C" || envWord.text === "--chdir") {
				const consumed = consumePathOption(tokens, envIndex + 1, envCtx.cwd, variables);
				envCtx = shellContext(consumed.ref);
				envIndex = consumed.next;
				continue;
			}
			if (envWord.text.startsWith("--chdir=")) {
				const ref = resolveShellPath(envCtx.cwd, { kind: "word", text: envWord.text.slice("--chdir=".length), dynamic: envWord.dynamic }, variables);
				envCtx = shellContext(ref);
				envIndex += 1;
				continue;
			}
			if (envWord.text === "-S" || envWord.text === "--split-string") {
				const consumed = nextWord(tokens, envIndex + 1);
				if (!consumed.token) return { targets: null, parsed: null, envIndex: envIndex + 1 };
				return { targets: envSplitTargets(consumed.token.text, envCtx, envVariables, envTextVariables), parsed: null, envIndex: consumed.index + 1 };
			}
			const shortSplit = /^-[A-Za-z]*S(.*)$/.exec(envWord.text);
			if (shortSplit && envWord.text !== "-S") {
				if (shortSplit[1]) return { targets: envSplitTargets(shortSplit[1], envCtx, envVariables, envTextVariables), parsed: null, envIndex: envIndex + 1 };
				const consumed = nextWord(tokens, envIndex + 1);
				return { targets: consumed.token ? envSplitTargets(consumed.token.text, envCtx, envVariables, envTextVariables) : null, parsed: null, envIndex: consumed.token ? consumed.index + 1 : envIndex + 1 };
			}
			if (envWord.text.startsWith("--split-string=")) {
				return { targets: envSplitTargets(envWord.text.slice("--split-string=".length), envCtx, envVariables, envTextVariables), parsed: null, envIndex: envIndex + 1 };
			}
			if (envValueOptions.has(envWord.text)) {
				const consumed = nextWord(tokens, envIndex + 1);
				envIndex = consumed.token ? consumed.index + 1 : envIndex + 1;
				continue;
			}
			if (envWord.text.startsWith("--unset=") || envWord.text.startsWith("--ignore-signal=") || envWord.text.startsWith("--block-signal=") || envWord.text.startsWith("--default-signal=") || envWord.text.startsWith("--argv0=")) {
				envIndex += 1;
				continue;
			}
			if (isAssignment(envWord.text)) {
				recordTextAssignment(envWord, envTextVariables);
				if (envWord.text.startsWith("GIT_DIR=") || envWord.text.startsWith("GIT_WORK_TREE=")) {
					recordAssignment(envWord, envCtx.cwd, envVariables);
				}
				envIndex += 1;
				continue;
			}
			if (envWord.text.startsWith("-")) {
				envIndex += 1;
				continue;
			}
			break;
		}
		if (isWord(tokens[envIndex]) && isGitExecutable(resolvedCommandText(tokens[envIndex] as ShellWord, envTextVariables) ?? (tokens[envIndex] as ShellWord).text)) {
			return { targets: null, parsed: parseGitTarget(tokens, envIndex, envCtx.cwd, envCtx.external, envCtx.unknown, envVariables, envTextVariables), envIndex };
		}
		return { targets: null, parsed: null, envIndex };
	};

	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (token.kind === "op") {
			if (commandStart) promotePrefixAssignments();
			if (token.text === "(") {
				scopeStack.push(cloneContext(ctx));
				pending = null;
				commandStart = true;
				nextCommandConditional = false;
				nextCommandScoped = false;
				continue;
			}
			if (token.text === ")") {
				finishPending(")");
				ctx = scopeStack.pop() ?? ctx;
				commandStart = true;
				nextCommandConditional = false;
				nextCommandScoped = false;
				continue;
			}
			if (token.text === "{") {
				pending = null;
				commandStart = true;
				nextCommandConditional = false;
				nextCommandScoped = false;
				continue;
			}
			finishPending(token.text);
			commandStart = true;
			nextCommandConditional = token.text === "&&" || token.text === "||";
			nextCommandScoped = token.text === "|";
			continue;
		}

		if (commandStart && (controlBoundaries.has(token.text) || token.text === "!")) {
			pending = null;
			commandStart = true;
			nextCommandConditional = token.text !== "fi" && token.text !== "done" && token.text !== "esac";
			continue;
		}

		if (commandStart && isAssignment(token.text)) {
			recordTextAssignment(token, prefixTextVariables);
			recordAssignment(token, ctx.cwd, prefixGitVariables);
			continue;
		}

		if (commandStart && token.text === "export") {
			let j = i + 1;
			while (isWord(tokens[j])) {
				const exported = tokens[j] as ShellWord;
				if (exported.text.startsWith("-")) {
					j += 1;
					continue;
				}
				if (isAssignment(exported.text)) {
					recordTextAssignment(exported, textVariables);
					if (exported.text.startsWith("GIT_DIR=") || exported.text.startsWith("GIT_WORK_TREE=")) recordAssignment(exported, ctx.cwd, variables);
				}
				j += 1;
			}
			i = Math.max(i, j - 1);
			pending = pendingCommand("other", cloneContext(ctx));
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		if (commandStart && token.text === "cd") {
			let targetIndex = i + 1;
			while (isWord(tokens[targetIndex]) && (tokens[targetIndex] as ShellWord).text.startsWith("-") && (tokens[targetIndex] as ShellWord).text !== "--") targetIndex += 1;
			if (isWord(tokens[targetIndex]) && (tokens[targetIndex] as ShellWord).text === "--") targetIndex += 1;
			const before = cloneContext(ctx);
			const ref = resolveShellPath(ctx.cwd, isWord(tokens[targetIndex]) ? tokens[targetIndex] : undefined, variables);
			pending = pendingCommand("cd", before, shellContext(ref));
			i = targetIndex;
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		if (commandStart && token.text === "shopt") {
			let j = i + 1;
			let setMode = false;
			while (isWord(tokens[j])) {
				const word = (tokens[j] as ShellWord).text;
				if (word === "-s") {
					setMode = true;
					j += 1;
					continue;
				}
				if (setMode && word === "expand_aliases") expandAliases = true;
				j += 1;
			}
			i = Math.max(i, j - 1);
			pending = pendingCommand("other", cloneContext(ctx));
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		if (commandStart && token.text === "alias") {
			let j = i + 1;
			while (expandAliases && isWord(tokens[j])) {
				const assignment = (tokens[j] as ShellWord).text;
				const separator = assignment.indexOf("=");
				if (separator > 0) shellAliases.set(assignment.slice(0, separator), assignment.slice(separator + 1));
				j += 1;
			}
			i = Math.max(i, j - 1);
			pending = pendingCommand("other", cloneContext(ctx));
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		if (commandStart && token.text === "command") {
			let commandIndex = i + 1;
			while (isWord(tokens[commandIndex]) && (tokens[commandIndex] as ShellWord).text.startsWith("-")) commandIndex += 1;
			if (isWord(tokens[commandIndex]) && isGitExecutable(resolvedExecutable(tokens[commandIndex] as ShellWord))) {
				const parsed = parseGitTarget(tokens, commandIndex, ctx.cwd, ctx.external, ctx.unknown, gitCommandVariables(), gitTextVariables());
				if (parsed.target) targets.push(parsed.target);
				i = Math.max(i, parsed.next - 1);
				pending = pendingCommand("other", cloneContext(ctx));
				commandStart = false;
				markCommandConsumed();
				continue;
			}
		}

		if (commandStart && isEnvExecutable(resolvedExecutable(token))) {
			const { targets: envTargets, parsed, envIndex } = parseEnvWrapper(i);
			if (envTargets) {
				targets.push(...envTargets);
				i = Math.max(i, envIndex - 1);
				pending = pendingCommand("other", cloneContext(ctx));
				commandStart = false;
				markCommandConsumed();
				continue;
			}
			if (parsed) {
				if (parsed.target) targets.push(parsed.target);
				i = Math.max(i, parsed.next - 1);
				pending = pendingCommand("other", cloneContext(ctx));
				commandStart = false;
				markCommandConsumed();
				continue;
			}
			i = Math.max(i, envIndex - 1);
		}

		if (commandStart && dynamicCommandStartGitVerb(token, isWord(tokens[i + 1]) ? tokens[i + 1] : undefined, "commit", gitTextVariables())) {
			targets.push({ cwd: ctx.cwd, external: ctx.external, unknown: true, hasGitDir: false, gitDir: null, hasWorkTree: false, workTree: null });
			pending = pendingCommand("other", cloneContext(ctx));
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		if (commandStart && shellAliases.has(token.text)) {
			const aliasValue = shellAliases.get(token.text) ?? "";
			const aliasTargets = gitCommitTargets(aliasValue, ctx.cwd ?? cwd, gitCommandVariables(), gitTextVariables()).map((target) => ({
				...target,
				external: target.external || ctx.external,
				unknown: target.unknown || ctx.unknown,
			}));
			if (aliasTargets.length > 0) targets.push(...aliasTargets);
			else if (/\s/.test(aliasValue) || /\$|`/.test(aliasValue)) targets.push({ cwd: ctx.cwd, external: ctx.external, unknown: true, hasGitDir: false, gitDir: null, hasWorkTree: false, workTree: null });
			if (aliasTargets.length > 0 || /\s/.test(aliasValue) || /\$|`/.test(aliasValue)) {
				pending = pendingCommand("other", cloneContext(ctx));
				commandStart = false;
				markCommandConsumed();
				continue;
			}
		}

		if (commandStart && isGitExecutable(resolvedExecutable(token))) {
			const configMutation = recordGitConfigMutation(tokens, i, textVariables);
			if (configMutation.recorded) {
				i = Math.max(i, configMutation.next - 1);
				pending = pendingCommand("other", cloneContext(ctx));
				commandStart = false;
				markCommandConsumed();
				continue;
			}
			const parsed = parseGitTarget(tokens, i, ctx.cwd, ctx.external, ctx.unknown, gitCommandVariables(), gitTextVariables());
			if (parsed.target) targets.push(parsed.target);
			i = Math.max(i, parsed.next - 1);
			pending = pendingCommand("other", cloneContext(ctx));
			commandStart = false;
			markCommandConsumed();
			continue;
		}

		pending = pendingCommand("other", cloneContext(ctx));
		commandStart = false;
		markCommandConsumed();
	}

	return targets;
}

function pathContains(parent: string, child: string): boolean {
	const rel = relative(resolve(parent), resolve(child));
	return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function samePath(left: string, right: string): boolean {
	try {
		return realpathSync(left) === realpathSync(right);
	} catch {
		return resolve(left) === resolve(right);
	}
}

function isLinkedWorktreeGitDir(gitDir: string): boolean {
	return existsSync(resolve(gitDir, "gitdir"));
}

type GitRootResult =
	| { kind: "ok"; root: string }
	| { kind: "none"; reason: string }
	| { kind: "error"; reason: string };

export type ProjectGitCommitProbe =
	| { kind: "project"; cwd: string; root: string; includeUntracked: boolean }
	| { kind: "skip"; reason: "outside-repo" | "no-git-commit" }
	| { kind: "error"; reason: string };

async function gitRoot(cwd: string, timeoutMs: number): Promise<GitRootResult> {
	const result = await runGit(["rev-parse", "--show-toplevel"], cwd, timeoutMs);
	if (result.timedOut) return { kind: "error", reason: `git rev-parse timed out after ${Math.max(1, timeoutMs)}ms for ${cwd}.` };
	if (result.exitCode !== 0) {
		const detail = (result.stderr || result.stdout).trim();
		if (/not a git repository/i.test(detail)) return { kind: "none", reason: detail || `${cwd} is not a git repository` };
		return { kind: "error", reason: detail || `git rev-parse failed for ${cwd}.` };
	}
	const root = result.stdout.trim();
	return root ? { kind: "ok", root: resolve(root) } : { kind: "error", reason: `git rev-parse returned no root for ${cwd}.` };
}

async function gitRootFromGitDir(gitDir: string, cwd: string, timeoutMs: number): Promise<GitRootResult> {
	const result = await runGit(["--git-dir", gitDir, "rev-parse", "--show-toplevel"], cwd, timeoutMs);
	if (result.timedOut) return { kind: "error", reason: `git --git-dir ${gitDir} rev-parse timed out after ${Math.max(1, timeoutMs)}ms.` };
	if (result.exitCode !== 0) {
		const detail = (result.stderr || result.stdout).trim();
		return { kind: "none", reason: detail || `git --git-dir ${gitDir} rev-parse did not find a worktree` };
	}
	const root = result.stdout.trim();
	return root ? { kind: "ok", root: resolve(root) } : { kind: "error", reason: `git --git-dir ${gitDir} rev-parse returned no root.` };
}

async function gitAliasCommitDecision(cwd: string, aliasName: string, timeoutMs: number): Promise<AliasVerbDecision> {
	const result = await runGit(["config", "--get", `alias.${aliasName.toLowerCase()}`], cwd, timeoutMs);
	if (result.timedOut) return "unknown";
	if (result.exitCode !== 0) return "non-match";
	return aliasValueMatchesVerb(result.stdout.trim(), "commit", cwd, new Map(), new Map());
}

export async function resolveProjectGitCommit(command: string, cwd: string, timeoutMs = 5000): Promise<ProjectGitCommitProbe> {
	const targets = gitCommitTargets(command, cwd);
	const unparsedCommitCount = gitCommitSyntaxCount(command);
	const hasCommit = targets.length > 0 || unparsedCommitCount > 0;
	const hasUnparsedCommit = unparsedCommitCount > 0;
	if (!hasCommit) return { kind: "skip", reason: "no-git-commit" };

	const project = await gitRoot(cwd, timeoutMs);
	if (project.kind === "error") return project;
	if (project.kind === "none") return { kind: "error", reason: `pi-hooks pre-commit: cannot identify project git root for ${cwd}: ${project.reason}` };

	if (targets.length === 0) {
		return { kind: "project", cwd: resolve(cwd), root: project.root, includeUntracked: true };
	}

	let unresolvedReason: string | null = null;

	for (const target of targets) {
		if (target.external) continue;
		if (target.unknown) {
			unresolvedReason = "pi-hooks pre-commit: cannot resolve git commit target with shell expansion; use a literal project path or disable preCommitCheck for this command.";
			continue;
		}
		if (target.aliasName) {
			if (!target.cwd) {
				unresolvedReason = "pi-hooks pre-commit: cannot resolve git alias working tree.";
				continue;
			}
			const decision = await gitAliasCommitDecision(target.cwd, target.aliasName, timeoutMs);
			if (decision === "non-match") continue;
			if (decision === "unknown") {
				unresolvedReason = `pi-hooks pre-commit: cannot prove git alias ${target.aliasName} is non-commit; use a literal git commit command or disable preCommitCheck for this command.`;
				continue;
			}
		}
		if (target.hasGitDir) {
			if (!target.gitDir) {
				unresolvedReason = "pi-hooks pre-commit: cannot resolve git commit --git-dir target.";
				continue;
			}
			let canonicalGitDir = target.gitDir;
			try {
				canonicalGitDir = realpathSync(target.gitDir);
			} catch {
				// Fall back to lexical path checks when the git-dir does not exist yet.
			}
			if (pathContains(project.root, canonicalGitDir)) return { kind: "project", cwd: resolve(cwd), root: project.root, includeUntracked: false };
			if (target.hasWorkTree && target.workTree) {
				const workTreeInside = pathContains(project.root, target.workTree);
				const workTreeRoot = await gitRoot(target.workTree, timeoutMs);
				if (workTreeRoot.kind === "error") return { kind: "error", reason: `pi-hooks pre-commit: ${workTreeRoot.reason}` };
				if (workTreeRoot.kind === "none") {
					if (workTreeInside) unresolvedReason = `pi-hooks pre-commit: ${target.workTree} is inside the project but not a git worktree: ${workTreeRoot.reason}`;
					continue;
				}
				if (samePath(workTreeRoot.root, project.root)) return { kind: "project", cwd: target.workTree, root: project.root, includeUntracked: false };
				continue;
			}
			if (isLinkedWorktreeGitDir(target.gitDir)) {
				const gitDirRoot = await gitRootFromGitDir(target.gitDir, cwd, timeoutMs);
				if (gitDirRoot.kind === "error") return { kind: "error", reason: `pi-hooks pre-commit: ${gitDirRoot.reason}` };
				if (gitDirRoot.kind === "ok" && samePath(gitDirRoot.root, project.root)) {
					return { kind: "project", cwd: project.root, root: project.root, includeUntracked: false };
				}
			}
			continue;
		}
		const candidate = target.hasWorkTree ? target.workTree : target.cwd;
		if (!candidate) {
			unresolvedReason = "pi-hooks pre-commit: cannot resolve git commit working tree.";
			continue;
		}
		if (target.hasWorkTree && !target.hasGitDir) {
			const cwdRoot = target.cwd ? await gitRoot(target.cwd, timeoutMs) : { kind: "none" as const, reason: "no git cwd" };
			if (cwdRoot.kind === "error") return { kind: "error", reason: `pi-hooks pre-commit: ${cwdRoot.reason}` };
			if (cwdRoot.kind === "ok" && samePath(cwdRoot.root, project.root)) return { kind: "project", cwd: target.cwd ?? resolve(cwd), root: project.root, includeUntracked: false };
		}
		const candidateInside = pathContains(project.root, candidate);
		const targetRoot = await gitRoot(candidate, timeoutMs);
		if (targetRoot.kind === "error") return { kind: "error", reason: `pi-hooks pre-commit: ${targetRoot.reason}` };
		if (targetRoot.kind === "none") {
			if (candidateInside) unresolvedReason = `pi-hooks pre-commit: ${candidate} is inside the project but not a git worktree: ${targetRoot.reason}`;
			continue;
		}
		if (samePath(targetRoot.root, project.root)) return { kind: "project", cwd: candidate, root: project.root, includeUntracked: false };
	}

	if (unresolvedReason) return { kind: "error", reason: unresolvedReason };
	if (hasUnparsedCommit) return { kind: "project", cwd: resolve(cwd), root: project.root, includeUntracked: true };
	return { kind: "skip", reason: "outside-repo" };
}

export async function projectGitCommitCwd(command: string, cwd: string, timeoutMs = 5000): Promise<string | null> {
	const result = await resolveProjectGitCommit(command, cwd, timeoutMs);
	return result.kind === "project" ? result.cwd : null;
}

export interface BlockReason {
	reason: string;
}

/**
 * Pre-commit gate. Runs `cargo fmt --check` then `cargo clippy --workspace
 * --all-targets -- -D warnings` via async child processes so Pi's event loop
 * stays responsive while the check runs. Returns a block reason on failure, or
 * `undefined` to let the commit proceed. No-ops when the command targets a
 * different repository, or when there are no relevant `.rs` files (staged,
 * modified, or untracked files that a same-command `git add` may stage), so
 * unrelated and non-Rust commits aren't slowed down.
 *
 * Budget split: metadata gets a small share, then fmt and clippy each get the
 * configured lint budget. Git target probes use short async timeouts and do not
 * block the main thread.
 */
export async function runPreCommitCheck(cwd: string, timeoutMs: number, command: string): Promise<BlockReason | undefined> {
	const metadataBudget = Math.min(5000, Math.floor(timeoutMs / 4));
	const commit = await resolveProjectGitCommit(command, cwd, metadataBudget);
	if (commit.kind === "skip") return undefined;
	if (commit.kind === "error") return { reason: commit.reason };

	const rustFiles = await rustFilesRelevantToCommit(commit.cwd, commit.root, commit.includeUntracked || commandMayStageFiles(command));
	if (rustFiles.kind === "error") return { reason: `pi-hooks pre-commit: ${rustFiles.reason}` };
	if (rustFiles.files.length === 0) return undefined;

	const workspace = await findCargoWorkspaceRootResultAsync(commit.cwd, metadataBudget);
	if (workspace.kind === "error") return { reason: `pi-hooks pre-commit: ${workspace.reason}` };
	if (workspace.kind === "none") {
		return { reason: `pi-hooks pre-commit: found Rust files but could not identify a Cargo workspace: ${workspace.reason}` };
	}

	const remaining = Math.max(1, timeoutMs - metadataBudget);
	const fmtBudget = Math.max(1, Math.floor(remaining / 3));
	const clippyBudget = Math.max(1, remaining - fmtBudget);

	const fmt = await runCargoAsync(["fmt", "--check"], workspace.root, fmtBudget);
	if (fmt.timedOut) {
		return { reason: `pi-hooks pre-commit: cargo fmt --check timed out after ${fmtBudget}ms.` };
	}
	if (fmt.exitCode !== 0) {
		return { reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." };
	}

	const clippy = await runWorkspaceClippyAsync(workspace.root, clippyBudget);
	if (clippy.timedOut) {
		return { reason: `pi-hooks pre-commit: cargo clippy timed out after ${clippyBudget}ms.` };
	}
	if (clippy.exitCode !== 0) {
		return { reason: "pi-hooks pre-commit: cargo clippy found warnings. Fix them before committing." };
	}
	return undefined;
}
