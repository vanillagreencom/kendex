import { spawn } from "node:child_process";
import { isAbsolute, relative, resolve } from "node:path";

import { findCargoWorkspaceRootAsync, runCargoAsync, runWorkspaceClippyAsync } from "./cargo.js";

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

		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(command, args, {
				cwd,
				stdio: ["ignore", "pipe", "pipe"],
			});
		} catch (error) {
			resolveResult({ exitCode: -1, stdout: "", stderr: String(error), timedOut });
			return;
		}

		const finish = (exitCode: number, extraStderr = "") => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			if (extraStderr) appendChunk(stderr, extraStderr, stderrBytes, maxBuffer);
			resolveResult({
				exitCode,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
				timedOut,
			});
		};

		const timer = setTimeout(() => {
			timedOut = true;
			child.kill("SIGTERM");
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

async function gitListRustFiles(cwd: string, args: string[]): Promise<string[]> {
	const result = await runGit(args, cwd, 5000);
	if (result.exitCode !== 0) return [];
	return result.stdout
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line.endsWith(".rs"));
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
async function rustFilesRelevantToCommit(cwd: string): Promise<string[]> {
	const [staged, unstaged] = await Promise.all([
		gitListRustFiles(cwd, ["diff", "--cached", "--name-only"]),
		gitListRustFiles(cwd, ["diff", "--name-only"]),
	]);
	return [...new Set([...staged, ...unstaged])];
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
	/** Whether the invocation included `--git-dir`. */
	hasGitDir: boolean;
	/** Explicit `--git-dir` when present, resolved when statically knowable. */
	gitDir: string | null;
	/** Whether the invocation included `--work-tree`. */
	hasWorkTree: boolean;
	/** Explicit `--work-tree` when present, resolved when statically knowable. */
	workTree: string | null;
}

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
		if (/\s/.test(ch)) {
			i += 1;
			continue;
		}

		const op = isShellOperatorStart(command, i);
		if (op) {
			tokens.push({ kind: "op", text: op });
			i += op.length;
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

function resolveShellPath(base: string | null, word: ShellWord | undefined): string | null {
	if (!word || word.dynamic || !base) return null;
	if (!word.text) return null;
	return isAbsolute(word.text) ? resolve(word.text) : resolve(base, word.text);
}

function nextWord(tokens: ShellToken[], start: number): { token: ShellWord | undefined; index: number } {
	let index = start;
	while (tokens[index]?.kind === "op" && tokens[index]?.text === "\n") index += 1;
	return { token: isWord(tokens[index]) ? tokens[index] : undefined, index };
}

function consumePathOption(tokens: ShellToken[], index: number, currentCwd: string | null): { path: string | null; next: number } {
	const { token, index: valueIndex } = nextWord(tokens, index);
	return { path: resolveShellPath(currentCwd, token), next: token ? valueIndex + 1 : index + 1 };
}

function parseGitTarget(tokens: ShellToken[], gitIndex: number, shellCwd: string | null): { target: GitCommitTarget | null; next: number } {
	let currentCwd = shellCwd;
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
			const consumed = consumePathOption(tokens, j + 1, currentCwd);
			currentCwd = consumed.path;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("-C") && word.length > 2) {
			currentCwd = resolveShellPath(currentCwd, { kind: "word", text: word.slice(2), dynamic: token.dynamic });
			j += 1;
			continue;
		}
		if (word === "--git-dir") {
			const consumed = consumePathOption(tokens, j + 1, currentCwd);
			hasGitDir = true;
			gitDir = consumed.path;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("--git-dir=")) {
			hasGitDir = true;
			gitDir = resolveShellPath(currentCwd, { kind: "word", text: word.slice("--git-dir=".length), dynamic: token.dynamic });
			j += 1;
			continue;
		}
		if (word === "--work-tree") {
			const consumed = consumePathOption(tokens, j + 1, currentCwd);
			hasWorkTree = true;
			workTree = consumed.path;
			j = consumed.next;
			continue;
		}
		if (word.startsWith("--work-tree=")) {
			hasWorkTree = true;
			workTree = resolveShellPath(currentCwd, { kind: "word", text: word.slice("--work-tree=".length), dynamic: token.dynamic });
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

		return { target: word === "commit" ? { cwd: currentCwd, hasGitDir, gitDir, hasWorkTree, workTree } : null, next: j + 1 };
	}

	return { target: null, next: j };
}

export function gitCommitTargets(command: string, cwd: string): GitCommitTarget[] {
	const tokens = tokenizeShell(command);
	const targets: GitCommitTarget[] = [];
	let shellCwd: string | null = resolve(cwd);
	let commandStart = true;

	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (token.kind === "op") {
			if (token.text !== ")") commandStart = true;
			continue;
		}

		if (commandStart && isAssignment(token.text)) continue;

		if (commandStart && token.text === "cd") {
			let targetIndex = i + 1;
			while (isWord(tokens[targetIndex]) && (tokens[targetIndex] as ShellWord).text.startsWith("-")) targetIndex += 1;
			shellCwd = resolveShellPath(shellCwd, isWord(tokens[targetIndex]) ? tokens[targetIndex] : undefined);
			i = targetIndex;
			commandStart = false;
			continue;
		}

		if (commandStart && token.text === "git") {
			const parsed = parseGitTarget(tokens, i, shellCwd);
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

async function gitRoot(cwd: string, timeoutMs: number): Promise<string | null> {
	const result = await runGit(["rev-parse", "--show-toplevel"], cwd, timeoutMs);
	if (result.exitCode !== 0) return null;
	const root = result.stdout.trim();
	return root ? resolve(root) : null;
}

export async function projectGitCommitCwd(command: string, cwd: string, timeoutMs = 5000): Promise<string | null> {
	const projectRoot = await gitRoot(cwd, timeoutMs);
	if (!projectRoot) return null;

	for (const target of gitCommitTargets(command, cwd)) {
		if (target.hasGitDir && (!target.gitDir || !pathContains(projectRoot, target.gitDir))) continue;
		const candidate = target.hasWorkTree ? target.workTree : target.cwd;
		if (!candidate) continue;
		if (!pathContains(projectRoot, candidate)) continue;

		const targetRoot = await gitRoot(candidate, timeoutMs);
		if (targetRoot === projectRoot) return candidate;
	}

	return null;
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
	const commitCwd = await projectGitCommitCwd(command, cwd, metadataBudget);
	if (!commitCwd) return undefined;

	const root = await findCargoWorkspaceRootAsync(commitCwd, metadataBudget);
	if (!root) return undefined;

	const rustFiles = await rustFilesRelevantToCommit(commitCwd);
	if (rustFiles.length === 0) return undefined;

	const remaining = Math.max(1, timeoutMs - metadataBudget);
	const fmtBudget = Math.max(1, Math.floor(remaining / 3));
	const clippyBudget = Math.max(1, remaining - fmtBudget);

	const fmt = await runCargoAsync(["fmt", "--check"], root, fmtBudget);
	if (fmt.timedOut) {
		return { reason: `pi-hooks pre-commit: cargo fmt --check timed out after ${fmtBudget}ms.` };
	}
	if (fmt.exitCode !== 0) {
		return { reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." };
	}

	const clippy = await runWorkspaceClippyAsync(root, clippyBudget);
	if (clippy.timedOut) {
		return { reason: `pi-hooks pre-commit: cargo clippy timed out after ${clippyBudget}ms.` };
	}
	if (clippy.exitCode !== 0) {
		return { reason: "pi-hooks pre-commit: cargo clippy found warnings. Fix them before committing." };
	}
	return undefined;
}
