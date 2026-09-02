import { execFile } from "node:child_process";
import * as path from "node:path";
import { stringifyError } from "./format.js";
import type { CwdSnapshot } from "./types.js";

type ExecFileProcess = typeof execFile;

let execFileProcess: ExecFileProcess = execFile;
const GIT_SNAPSHOT_TIMEOUT_MS = 5_000;
const GIT_SNAPSHOT_MAX_BUFFER = 256 * 1024;
const GIT_STATUS_MAX_BUFFER = 8 * 1024 * 1024;
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

function porcelainStatusLines(raw: string | undefined): string[] {
	// `git status --porcelain -z` emits NUL-terminated `XY <path>` records; a
	// rename or copy is followed by one more record holding the origin path.
	const fields = splitZ(raw);
	const lines: string[] = [];
	for (let i = 0; i < fields.length; i += 1) {
		const record = fields[i] ?? "";
		if (record.length < 4) continue;
		const code = record.slice(0, 2);
		const filePath = record.slice(3);
		if (code.includes("R") || code.includes("C")) {
			const origin = fields[i + 1];
			i += 1;
			const line = origin === undefined
				? formatStatusLine(code, filePath)
				: formatStatusLine(code, `${origin} -> ${filePath}`);
			if (line) lines.push(line);
			continue;
		}
		const line = formatStatusLine(code, filePath);
		if (line) lines.push(line);
	}
	return lines;
}

async function readDirtyStatus(cwd: string, addDiagnostic: (diagnostic: string) => void): Promise<string | undefined> {
	const raw = await readGit(cwd, ["status", "--porcelain", "-z", "--untracked-files=all"], addDiagnostic, { maxBuffer: GIT_STATUS_MAX_BUFFER });
	if (raw == null) return undefined;
	return porcelainStatusLines(raw).join("\n");
}

export async function snapshotCwdGitState(cwd: string | undefined, addDiagnostic: (diagnostic: string) => void): Promise<CwdSnapshot | undefined> {
	if (!cwd) return undefined;
	const resolvedCwd = path.resolve(cwd);
	const insideWorkTree = (await readGit(resolvedCwd, ["rev-parse", "--is-inside-work-tree"], addDiagnostic))?.trim();
	if (insideWorkTree !== "true") return undefined;
	// Snapshot commands are read-only and run with --no-optional-locks plus GIT_OPTIONAL_LOCKS=0
	// so agent triage never creates .git/index.lock or blocks concurrent worker git operations.
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
