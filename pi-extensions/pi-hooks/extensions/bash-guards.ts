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

/**
 * Match `git commit` as a verb, allowing alias-style invocations like
 * `git -C path commit` and `git commit -m "..."`. Does not match
 * `git commit-tree` or `gitfoo commit`.
 */
const GIT_COMMIT = /(^|\s)git(\s+[^\s]+)*\s+commit(\s|$)/;

export function isGitCommit(command: string): boolean {
	return GIT_COMMIT.test(command);
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
 * files. If either set is non-empty, the commit is treated as relevant.
 *
 * Returns the union, deduped.
 */
async function rustFilesRelevantToCommit(cwd: string): Promise<RustFilesResult> {
	const [staged, unstaged] = await Promise.all([
		gitListRustFiles(cwd, ["diff", "--cached", "--name-only"]),
		gitListRustFiles(cwd, ["diff", "--name-only"]),
	]);
	if (staged.kind === "error") return staged;
	if (unstaged.kind === "error") return unstaged;
	return { kind: "ok", files: [...new Set([...staged.files, ...unstaged.files])] };
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
}

interface ShellPathRef {
	path: string | null;
	external: boolean;
	unknown: boolean;
}

type ShellVariables = Map<string, ShellPathRef>;

function isShellOperatorStart(command: string, index: number): string | null {
	const two = command.slice(index, index + 2);
	if (two === "&&" || two === "||") return two;
	const one = command[index];
	if (one === ";" || one === "|" || one === "(" || one === ")" || one === "\n") return one;
	return null;
}

function tokenizeShell(command: string): ShellToken[] {
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
	return { path: isAbsolute(text) ? resolve(text) : resolve(base, text), external: false, unknown: false };
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

function parseGitTarget(
	tokens: ShellToken[],
	gitIndex: number,
	shellCwd: string | null,
	shellExternal: boolean,
	shellUnknown: boolean,
	variables: ShellVariables,
): { target: GitCommitTarget | null; next: number } {
	let currentCwd = shellCwd;
	let external = shellExternal;
	let unknown = shellUnknown;
	let hasGitDir = false;
	let gitDir: string | null = null;
	let hasWorkTree = false;
	let workTree: string | null = null;
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
			j = consumed.token ? consumed.index + 1 : j + 1;
			continue;
		}
		if (word.startsWith("-")) {
			j += 1;
			continue;
		}

		return { target: word === "commit" ? { cwd: currentCwd, external, unknown, hasGitDir, gitDir, hasWorkTree, workTree } : null, next: j + 1 };
	}

	return { target: null, next: j };
}

export function gitCommitTargets(command: string, cwd: string): GitCommitTarget[] {
	const tokens = tokenizeShell(command);
	const targets: GitCommitTarget[] = [];
	const variables: ShellVariables = new Map();
	let shellCwd: string | null = resolve(cwd);
	let shellExternal = false;
	let shellUnknown = false;
	let commandStart = true;

	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (token.kind === "op") {
			if (token.text !== ")") commandStart = true;
			continue;
		}

		if (commandStart && isAssignment(token.text)) {
			recordAssignment(token, shellCwd, variables);
			continue;
		}

		if (commandStart && token.text === "cd") {
			let targetIndex = i + 1;
			while (isWord(tokens[targetIndex]) && (tokens[targetIndex] as ShellWord).text.startsWith("-")) targetIndex += 1;
			const ref = resolveShellPath(shellCwd, isWord(tokens[targetIndex]) ? tokens[targetIndex] : undefined, variables);
			shellCwd = ref.path;
			shellExternal = ref.external;
			shellUnknown = ref.unknown;
			i = targetIndex;
			commandStart = false;
			continue;
		}

		if (commandStart && token.text === "command") {
			let commandIndex = i + 1;
			while (isWord(tokens[commandIndex]) && (tokens[commandIndex] as ShellWord).text.startsWith("-")) commandIndex += 1;
			if (isWord(tokens[commandIndex]) && (tokens[commandIndex] as ShellWord).text === "git") {
				const parsed = parseGitTarget(tokens, commandIndex, shellCwd, shellExternal, shellUnknown, variables);
				if (parsed.target) targets.push(parsed.target);
				i = Math.max(i, parsed.next - 1);
				commandStart = false;
				continue;
			}
		}

		if (commandStart && token.text === "env") {
			let envIndex = i + 1;
			let envCwd = shellCwd;
			let envExternal = shellExternal;
			let envUnknown = shellUnknown;
			while (isWord(tokens[envIndex])) {
				const envWord = tokens[envIndex] as ShellWord;
				if (envWord.text === "--") {
					envIndex += 1;
					break;
				}
				if (envWord.text === "-C" || envWord.text === "--chdir") {
					const consumed = consumePathOption(tokens, envIndex + 1, envCwd, variables);
					envCwd = consumed.ref.path;
					envExternal = consumed.ref.external;
					envUnknown = consumed.ref.unknown;
					envIndex = consumed.next;
					continue;
				}
				if (envWord.text.startsWith("--chdir=")) {
					const ref = resolveShellPath(envCwd, { kind: "word", text: envWord.text.slice("--chdir=".length), dynamic: envWord.dynamic }, variables);
					envCwd = ref.path;
					envExternal = ref.external;
					envUnknown = ref.unknown;
					envIndex += 1;
					continue;
				}
				if (isAssignment(envWord.text)) {
					recordAssignment(envWord, envCwd, variables);
					envIndex += 1;
					continue;
				}
				if (envWord.text.startsWith("-")) {
					envIndex += 1;
					continue;
				}
				break;
			}
			if (isWord(tokens[envIndex]) && (tokens[envIndex] as ShellWord).text === "git") {
				const parsed = parseGitTarget(tokens, envIndex, envCwd, envExternal, envUnknown, variables);
				if (parsed.target) targets.push(parsed.target);
				i = Math.max(i, parsed.next - 1);
				commandStart = false;
				continue;
			}
		}

		if (commandStart && token.text === "git") {
			const parsed = parseGitTarget(tokens, i, shellCwd, shellExternal, shellUnknown, variables);
			if (parsed.target) targets.push(parsed.target);
			i = Math.max(i, parsed.next - 1);
			commandStart = false;
			continue;
		}

		commandStart = false;
	}

	return targets;
}

function pathContains(parent: string, child: string): boolean {
	const rel = relative(resolve(parent), resolve(child));
	return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

type GitRootResult =
	| { kind: "ok"; root: string }
	| { kind: "none"; reason: string }
	| { kind: "error"; reason: string };

export type ProjectGitCommitProbe =
	| { kind: "project"; cwd: string; root: string }
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

export async function resolveProjectGitCommit(command: string, cwd: string, timeoutMs = 5000): Promise<ProjectGitCommitProbe> {
	const project = await gitRoot(cwd, timeoutMs);
	if (project.kind === "error") return project;
	if (project.kind === "none") return { kind: "error", reason: `pi-hooks pre-commit: cannot identify project git root for ${cwd}: ${project.reason}` };

	const targets = gitCommitTargets(command, cwd);
	if (targets.length === 0) return { kind: "skip", reason: "no-git-commit" };

	let unresolvedReason: string | null = null;

	for (const target of targets) {
		if (target.external) continue;
		if (target.unknown) {
			unresolvedReason = "pi-hooks pre-commit: cannot resolve git commit target with shell expansion; use a literal project path or disable preCommitCheck for this command.";
			continue;
		}
		if (target.hasGitDir && (!target.gitDir || !pathContains(project.root, target.gitDir))) continue;
		const candidate = target.hasWorkTree ? target.workTree : target.cwd;
		if (!candidate) {
			unresolvedReason = "pi-hooks pre-commit: cannot resolve git commit working tree.";
			continue;
		}
		if (!pathContains(project.root, candidate)) continue;

		const targetRoot = await gitRoot(candidate, timeoutMs);
		if (targetRoot.kind === "error") return { kind: "error", reason: `pi-hooks pre-commit: ${targetRoot.reason}` };
		if (targetRoot.kind === "none") {
			unresolvedReason = `pi-hooks pre-commit: ${candidate} is inside the project but not a git worktree: ${targetRoot.reason}`;
			continue;
		}
		if (targetRoot.root === project.root) return { kind: "project", cwd: candidate, root: project.root };
	}

	if (unresolvedReason) return { kind: "error", reason: unresolvedReason };
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
 * different repository, or when there are no staged/modified `.rs` files (so
 * unrelated and non-Rust commits aren't slowed down).
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

	const rustFiles = await rustFilesRelevantToCommit(commit.cwd);
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
