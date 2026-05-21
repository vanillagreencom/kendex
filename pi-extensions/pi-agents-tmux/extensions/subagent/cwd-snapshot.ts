import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { stringifyError } from "./format.js";
import type { CwdSnapshot } from "./types.js";

type ExecFileProcess = typeof execFile;

let execFileProcess: ExecFileProcess = execFile;
const GIT_SNAPSHOT_TIMEOUT_MS = 5_000;
const GIT_SNAPSHOT_MAX_BUFFER = 256 * 1024;
const GIT_INDEX_DEBUG_MAX_BUFFER = 8 * 1024 * 1024;
const DIRTY_STAT_DEADLINE_MS = 750;
const DIRTY_STAT_MAX_ENTRIES = 2_000;
const DIRTY_STAT_MAX_FAILURE_DIAGNOSTICS = 5;
const ANSI_ESCAPE_RE = /\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))/g;

export function setGitExecFileForTests(execFileOverride?: ExecFileProcess): void {
	execFileProcess = execFileOverride ?? execFile;
}

export function sanitizeCwdSnapshotText(value: string, options: { multiline?: boolean } = {}): string {
	const preserveMultiline = options.multiline === true;
	let text = value.replace(ANSI_ESCAPE_RE, "");
	text = preserveMultiline
		? text.replace(/\r\n?/g, "\n").replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/g, "")
		: text.replace(/[\x00-\x1F\x7F-\x9F]/g, " ");
	return text.replace(/```/g, "`\u200b``");
}

function stringField(value: unknown, options?: { multiline?: boolean }): string | undefined {
	return typeof value === "string" ? sanitizeCwdSnapshotText(value, options) : undefined;
}

export function sanitizeCwdSnapshot(value: unknown): CwdSnapshot | undefined {
	if (!value || typeof value !== "object") return undefined;
	const record = value as Partial<CwdSnapshot>;
	const cwd = stringField(record.cwd);
	const head = stringField(record.head);
	const status = stringField(record.status ?? record.dirtyStatus, { multiline: true }) ?? "";
	const subject = stringField(record.lastCommit?.subject ?? record.lastCommitSubject) ?? "";
	if (cwd === undefined || head === undefined) return undefined;
	return {
		cwd,
		dirty: record.dirty === true,
		dirtyStatus: status,
		head,
		lastCommit: { subject },
		lastCommitSubject: subject,
		status,
	};
}

interface GitCommandResult {
	error?: unknown;
	stderr: string;
	stdout: string;
}

function execGit(cwd: string, args: string[], options: { maxBuffer?: number } = {}): Promise<GitCommandResult> {
	return new Promise((resolve, reject) => {
		try {
			execFileProcess(
				"git",
				[
					"--no-optional-locks",
					"-c",
					"core.fsmonitor=false",
					"-c",
					"core.untrackedCache=false",
					"-c",
					"log.showSignature=false",
					"-C",
					cwd,
					...args,
				],
				{
					encoding: "utf8",
					env: gitSnapshotEnv(),
					maxBuffer: options.maxBuffer ?? GIT_SNAPSHOT_MAX_BUFFER,
					timeout: GIT_SNAPSHOT_TIMEOUT_MS,
				},
				(error, stdout, stderr) => {
					resolve({ error: error ?? undefined, stderr: String(stderr ?? "").trimEnd(), stdout: String(stdout ?? "").trimEnd() });
				},
			);
		} catch (error) {
			reject(error);
		}
	});
}

function gitSnapshotEnv(): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		GIT_CONFIG_GLOBAL: process.platform === "win32" ? "NUL" : "/dev/null",
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_OPTIONAL_LOCKS: "0",
		GIT_TERMINAL_PROMPT: "0",
	};
	for (const key of ["PATH", "SystemRoot", "WINDIR", "ComSpec", "PATHEXT"] as const) {
		if (process.env[key]) env[key] = process.env[key];
	}
	return env;
}

function gitFailureDiagnostic(cwd: string, args: string[], result: GitCommandResult | { error: unknown; stderr?: string }): string {
	const stderr = result.stderr?.trim();
	const detail = stderr || stringifyError(result.error);
	return `cwdSnapshot git failed in ${cwd}: git --no-optional-locks -c core.fsmonitor=false -c core.untrackedCache=false -c log.showSignature=false ${args.join(" ")} (${detail})`;
}

async function readGit(cwd: string, args: string[], addDiagnostic: (diagnostic: string) => void, options: { maxBuffer?: number } = {}): Promise<string | undefined> {
	try {
		const result = await execGit(cwd, args, options);
		if (result.error) {
			addDiagnostic(gitFailureDiagnostic(cwd, args, result));
			return undefined;
		}
		return result.stdout;
	} catch (error) {
		addDiagnostic(gitFailureDiagnostic(cwd, args, { error }));
		return undefined;
	}
}

function splitZ(raw: string | undefined): string[] {
	if (!raw) return [];
	return raw.split("\0").filter(Boolean);
}

function safeStatusPath(filePath: string): string {
	return sanitizeCwdSnapshotText(filePath).replace(/\t/g, " ").trim();
}

function formatStatusLine(prefix: string, filePath: string): string | undefined {
	const safePath = safeStatusPath(filePath);
	return safePath ? `${prefix} ${safePath}` : undefined;
}

function stagedStatusLines(raw: string | undefined): string[] {
	const parts = splitZ(raw);
	const lines: string[] = [];
	for (let i = 0; i + 1 < parts.length; i += 2) {
		const status = parts[i]?.trim().charAt(0) || "M";
		const line = formatStatusLine(`${status} `, parts[i + 1] ?? "");
		if (line) lines.push(line);
	}
	return lines;
}

interface IndexDebugEntry {
	path: string;
	ctimeSec: number;
	ctimeNsec: number;
	mtimeSec: number;
	mtimeNsec: number;
	size: number;
}

function parseIndexDebug(raw: string | undefined, addDiagnostic: (diagnostic: string) => void): IndexDebugEntry[] {
	if (!raw) return [];
	const entries: IndexDebugEntry[] = [];
	let offset = 0;
	while (offset < raw.length) {
		const nul = raw.indexOf("\0", offset);
		if (nul < 0) {
			addDiagnostic(`cwdSnapshot dirty scan incomplete: unable to parse git ls-files --debug output after ${entries.length} tracked paths`);
			break;
		}
		const filePath = raw.slice(offset, nul);
		offset = nul + 1;
		const meta = raw.slice(offset).match(/^  ctime: (\d+):(\d+)\n  mtime: (\d+):(\d+)\n  dev: .*\n  uid: .*\n  size: (\d+)\tflags: .*(?:\n|$)/);
		if (!meta) {
			const safePath = safeStatusPath(filePath) || "(empty path)";
			addDiagnostic(`cwdSnapshot dirty scan incomplete: unable to parse git ls-files --debug metadata for ${safePath} after ${entries.length} tracked paths`);
			break;
		}
		entries.push({
			path: filePath,
			ctimeSec: Number(meta[1]),
			ctimeNsec: Number(meta[2]),
			mtimeSec: Number(meta[3]),
			mtimeNsec: Number(meta[4]),
			size: Number(meta[5]),
		});
		offset += meta[0].length;
	}
	return entries;
}

async function statDiffersFromIndex(cwd: string, entry: IndexDebugEntry, addDiagnostic: (diagnostic: string) => void): Promise<boolean> {
	try {
		const stat = await fs.promises.stat(path.join(cwd, entry.path), { bigint: true });
		const mtimeSec = Number(stat.mtimeNs / 1_000_000_000n);
		const mtimeNsec = Number(stat.mtimeNs % 1_000_000_000n);
		const ctimeSec = Number(stat.ctimeNs / 1_000_000_000n);
		const ctimeNsec = Number(stat.ctimeNs % 1_000_000_000n);
		return Number(stat.size) !== entry.size
			|| mtimeSec !== entry.mtimeSec
			|| mtimeNsec !== entry.mtimeNsec
			|| ctimeSec !== entry.ctimeSec
			|| ctimeNsec !== entry.ctimeNsec;
	} catch (error) {
		const safePath = safeStatusPath(entry.path) || "(empty path)";
		addDiagnostic(`cwdSnapshot dirty scan incomplete: unable to stat tracked path ${safePath}: ${stringifyError(error)}`);
		return false;
	}
}

async function unstagedModifiedStatusLines(cwd: string, rawDebug: string | undefined, deleted: Set<string>, addDiagnostic: (diagnostic: string) => void): Promise<string[]> {
	const entries = parseIndexDebug(rawDebug, addDiagnostic);
	const lines: string[] = [];
	const deadline = Date.now() + DIRTY_STAT_DEADLINE_MS;
	let checked = 0;
	let statFailures = 0;
	const addStatFailureDiagnostic = (diagnostic: string) => {
		statFailures += 1;
		if (statFailures <= DIRTY_STAT_MAX_FAILURE_DIAGNOSTICS) addDiagnostic(diagnostic);
	};
	for (const entry of entries) {
		if (checked >= DIRTY_STAT_MAX_ENTRIES) {
			addDiagnostic(`cwdSnapshot dirty scan incomplete: checked ${checked} tracked paths; ${entries.length - checked} skipped by file cap`);
			break;
		}
		if (Date.now() >= deadline) {
			addDiagnostic(`cwdSnapshot dirty scan incomplete: checked ${checked} tracked paths before ${DIRTY_STAT_DEADLINE_MS}ms deadline`);
			break;
		}
		checked += 1;
		if (deleted.has(entry.path)) continue;
		if (!(await statDiffersFromIndex(cwd, entry, addStatFailureDiagnostic))) continue;
		const line = formatStatusLine(" M", entry.path);
		if (line) lines.push(line);
	}
	if (statFailures > DIRTY_STAT_MAX_FAILURE_DIAGNOSTICS) {
		addDiagnostic(`cwdSnapshot dirty scan incomplete: ${statFailures - DIRTY_STAT_MAX_FAILURE_DIAGNOSTICS} additional tracked path stat failures omitted`);
	}
	return lines;
}

async function readDirtyStatus(cwd: string, addDiagnostic: (diagnostic: string) => void): Promise<string | undefined> {
	// Avoid `git status` / worktree content hashing here: clean/process filters from
	// local .gitattributes can execute arbitrary commands. This stat-based view is
	// intentionally conservative and uses only index metadata, directory listing,
	// and index-vs-HEAD diff metadata.
	const [stagedRaw, debugRaw, deletedRaw, untrackedRaw] = await Promise.all([
		readGit(cwd, ["diff", "--cached", "--name-status", "-z", "--no-ext-diff", "--no-textconv", "--no-renames", "--"], addDiagnostic),
		readGit(cwd, ["ls-files", "--debug", "-z"], addDiagnostic, { maxBuffer: GIT_INDEX_DEBUG_MAX_BUFFER }),
		readGit(cwd, ["ls-files", "--deleted", "-z"], addDiagnostic),
		readGit(cwd, ["ls-files", "--others", "--exclude-standard", "-z"], addDiagnostic),
	]);
	if (stagedRaw == null || debugRaw == null || deletedRaw == null || untrackedRaw == null) return undefined;
	const deleted = new Set(splitZ(deletedRaw));
	const lines = [
		...stagedStatusLines(stagedRaw),
		...(await unstagedModifiedStatusLines(cwd, debugRaw, deleted, addDiagnostic)),
		...Array.from(deleted).map((filePath) => formatStatusLine(" D", filePath)).filter((line): line is string => Boolean(line)),
		...splitZ(untrackedRaw).map((filePath) => formatStatusLine("??", filePath)).filter((line): line is string => Boolean(line)),
	];
	return lines.join("\n");
}

export async function snapshotCwdGitState(cwd: string | undefined, addDiagnostic: (diagnostic: string) => void): Promise<CwdSnapshot | undefined> {
	if (!cwd) return undefined;
	const resolvedCwd = path.resolve(cwd);
	const insideWorkTree = (await readGit(resolvedCwd, ["rev-parse", "--is-inside-work-tree"], addDiagnostic))?.trim();
	if (insideWorkTree !== "true") return undefined;
	// Snapshot commands are read-only and run with --no-optional-locks plus GIT_OPTIONAL_LOCKS=0
	// so agent triage never creates .git/index.lock or blocks concurrent worker git operations.
	// Dirty-state collection deliberately avoids `git status` so repository clean/process
	// filters cannot execute during needs_completion triage.
	const [rawHead, dirtyStatus, lastCommitSubject] = await Promise.all([
		readGit(resolvedCwd, ["rev-parse", "HEAD"], addDiagnostic),
		readDirtyStatus(resolvedCwd, addDiagnostic),
		readGit(resolvedCwd, ["log", "-1", "--pretty=%s"], addDiagnostic),
	]);
	if (rawHead == null || dirtyStatus == null || lastCommitSubject == null) return undefined;
	const head = rawHead.trim();
	if (!/^[0-9a-f]{40}$/.test(head)) {
		addDiagnostic(`cwdSnapshot git returned malformed HEAD for ${resolvedCwd}: ${JSON.stringify(rawHead)}`);
		return undefined;
	}
	return sanitizeCwdSnapshot({
		cwd: resolvedCwd,
		dirty: dirtyStatus.length > 0,
		dirtyStatus,
		head,
		lastCommit: { subject: lastCommitSubject },
		lastCommitSubject,
		status: dirtyStatus,
	});
}
