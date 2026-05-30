#!/usr/bin/env bun
// Safe post-merge repository sync helper for Flightdeck.
// Only fast-forwards a clean local default branch to its remote-tracking ref.

import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { emitRepoMainSync, type RepoMainSyncDiagnostic, type RepoMainSyncResult } from "../activity/workflow-emit.ts";
import { statePath } from "../state/master-state.ts";

interface GitRun {
	args: string[];
	command: string;
	error?: NodeJS.ErrnoException;
	signal: NodeJS.Signals | null;
	status: number | null;
	stdout: string;
	stderr: string;
}

interface Options {
	action: "main";
	branch: string;
	json: boolean;
	projectRoot: string;
	remote: string;
}

function usage(code = 2): never {
	process.stderr.write("Usage: flightdeck-repo-sync main --project-root <path> [--remote origin] [--branch main] [--json]\n");
	process.exit(code);
}

function parseArgs(argv: string[]): Options {
	const action = argv.shift();
	if (action !== "main") usage();
	let projectRoot = "";
	let remote = "origin";
	let branch = "main";
	let json = false;
	for (let i = 0; i < argv.length; i += 1) {
		const arg = argv[i]!;
		if (arg === "--json") { json = true; continue; }
		if (arg === "--project-root") { projectRoot = argv[++i] ?? ""; continue; }
		if (arg.startsWith("--project-root=")) { projectRoot = arg.slice("--project-root=".length); continue; }
		if (arg === "--remote") { remote = argv[++i] ?? ""; continue; }
		if (arg.startsWith("--remote=")) { remote = arg.slice("--remote=".length); continue; }
		if (arg === "--branch") { branch = argv[++i] ?? ""; continue; }
		if (arg.startsWith("--branch=")) { branch = arg.slice("--branch=".length); continue; }
		usage();
	}
	if (!projectRoot.trim()) usage();
	if (!remote.trim() || remote.startsWith("-") || !isSafeRefPath(remote)) usage();
	if (!branch.trim() || branch.startsWith("-") || !isSafeRefPath(branch)) usage();
	return { action: "main", branch: branch.trim(), json, projectRoot: projectRoot.trim(), remote: remote.trim() };
}

function isSafeRefPath(value: string): boolean {
	if (!/^[A-Za-z0-9._/+-]+$/.test(value)) return false;
	if (value === "@") return false;
	if (value.startsWith("/") || value.endsWith("/")) return false;
	if (value.includes("..") || value.includes("@{") || value.includes("//")) return false;
	if (value.endsWith(".")) return false;
	for (const part of value.split("/")) {
		if (!part || part.startsWith(".") || part.endsWith(".lock")) return false;
	}
	return true;
}

function runGit(cwd: string, args: string[], opts: { input?: string } = {}): GitRun {
	const fullArgs = ["-C", cwd, ...args];
	const r = spawnSync("git", fullArgs, { encoding: "utf8", input: opts.input });
	return {
		args: ["git", ...fullArgs],
		command: shellCommand(["git", ...fullArgs]),
		error: r.error as NodeJS.ErrnoException | undefined,
		signal: r.signal,
		status: r.status,
		stderr: r.stderr ?? "",
		stdout: r.stdout ?? "",
	};
}

function ok(run: GitRun): boolean {
	return !run.error && run.status === 0;
}

function fail(reason: string, commands: string[], ahead = 0, behind = 0, dirtyPaths: string[] = [], diagnostics: RepoMainSyncDiagnostic[] = []): RepoMainSyncResult {
	return {
		ahead,
		behind,
		commands_suggested: commands,
		...(diagnostics.length > 0 ? { diagnostics } : {}),
		dirty_paths: dirtyPaths,
		reason: reasonWithDiagnostics(reason, diagnostics),
		status: "failed",
	};
}

function blocked(reason: string, commands: string[], ahead = 0, behind = 0, dirtyPaths: string[] = []): RepoMainSyncResult {
	return { ahead, behind, commands_suggested: commands, dirty_paths: dirtyPaths, reason, status: "blocked" };
}

function success(status: "synced" | "already-synced", reason: string, ahead = 0, behind = 0): RepoMainSyncResult {
	return { ahead, behind, commands_suggested: [], dirty_paths: [], reason, status };
}

function failGit(reason: string, run: GitRun, commands: string[] = [], ahead = 0, behind = 0, dirtyPaths: string[] = []): RepoMainSyncResult {
	return fail(reason, commands.length ? commands : [run.command], ahead, behind, dirtyPaths, [gitDiagnostic(run)]);
}

function cleanOneLine(value: string): string {
	return value.trim().replace(/\s+/g, " ");
}

function reasonWithDiagnostics(reason: string, diagnostics: RepoMainSyncDiagnostic[]): string {
	const first = diagnostics[0];
	if (!first) return reason;
	const status = first.error_code
		? `spawn ${first.error_code}`
		: first.exit_status !== undefined && first.exit_status !== null
			? `exit ${first.exit_status}`
			: first.signal
				? `signal ${first.signal}`
				: "failed";
	const stderr = cleanOneLine(first.stderr ?? "");
	const error = cleanOneLine(first.error_message ?? "");
	const suffix = [first.command, status, stderr || error].filter(Boolean).join("; ");
	return suffix ? `${reason}: ${suffix}` : reason;
}

const DIAGNOSTIC_STREAM_CAP_BYTES = 2048;

function capDiagnosticStream(value: string): string {
	const trimmed = value.trim();
	if (trimmed.length <= DIAGNOSTIC_STREAM_CAP_BYTES) return trimmed;
	const keep = DIAGNOSTIC_STREAM_CAP_BYTES;
	return `${trimmed.slice(0, keep)}…[truncated ${trimmed.length - keep} bytes]`;
}

function gitDiagnostic(run: GitRun): RepoMainSyncDiagnostic {
	const diagnostic: RepoMainSyncDiagnostic = {
		args: run.args,
		command: run.command,
		exit_status: run.status,
		signal: run.signal,
	};
	if (run.stderr.trim()) diagnostic.stderr = capDiagnosticStream(run.stderr);
	if (run.stdout.trim()) diagnostic.stdout = capDiagnosticStream(run.stdout);
	if (run.error) {
		if (run.error.code) diagnostic.error_code = run.error.code;
		diagnostic.error_message = run.error.message;
	}
	return diagnostic;
}

function shellQuote(value: string): string {
	if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(value)) return value;
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

function shellCommand(args: string[]): string {
	return args.map(shellQuote).join(" ");
}

function suggestedRerun(root: string, remote: string, branch: string): string {
	return `flightdeck-repo-sync main --project-root ${shellQuote(root)} --remote ${shellQuote(remote)} --branch ${shellQuote(branch)} --json`;
}

function ensureDirectory(path: string): string | null {
	const root = resolve(path);
	if (!existsSync(root)) return null;
	try {
		if (!statSync(root).isDirectory()) return null;
	} catch {
		return null;
	}
	return root;
}

function repoTopLevel(projectRoot: string): { root?: string; result?: RepoMainSyncResult } {
	const dir = ensureDirectory(projectRoot);
	if (!dir) return { result: fail("project-root-not-directory", []) };
	const top = runGit(dir, ["rev-parse", "--show-toplevel"]);
	if (!ok(top)) return { result: failGit("git-repo-invalid", top) };
	return { root: top.stdout.trim() || dir };
}

type RevParseResult =
	| { ok: true; sha: string }
	| { missing: true; ok: false }
	| { ok: false; result: RepoMainSyncResult };

function revParse(root: string, ref: string): RevParseResult {
	const r = runGit(root, ["rev-parse", "--verify", "--quiet", ref]);
	if (ok(r)) return { ok: true, sha: r.stdout.trim() };
	if (!r.error && r.status === 1) return { missing: true, ok: false };
	return { ok: false, result: failGit("git-rev-parse-failed", r) };
}

type AheadBehindResult =
	| { ahead: number; behind: number; ok: true }
	| { ok: false; result: RepoMainSyncResult };

function aheadBehind(root: string, localRef: string, remoteRef: string): AheadBehindResult {
	const r = runGit(root, ["rev-list", "--left-right", "--count", `${localRef}...${remoteRef}`]);
	if (!ok(r)) return { ok: false, result: failGit("ahead-behind-failed", r) };
	const [aheadRaw, behindRaw] = r.stdout.trim().split(/\s+/);
	const ahead = Number.parseInt(aheadRaw ?? "0", 10);
	const behind = Number.parseInt(behindRaw ?? "0", 10);
	if (!Number.isFinite(ahead) || !Number.isFinite(behind)) return { ok: false, result: fail("ahead-behind-parse-failed", [r.command], 0, 0, [], [gitDiagnostic(r)]) };
	return { ahead, behind, ok: true };
}

type DirtyStatusResult =
	| { ok: true; paths: string[] }
	| { ok: false; result: RepoMainSyncResult };

function dirtyStatus(root: string, ahead = 0, behind = 0): DirtyStatusResult {
	const r = runGit(root, ["status", "--porcelain=v1", "--untracked-files=all"]);
	if (!ok(r)) return { ok: false, result: failGit("git-status-failed", r, [r.command], ahead, behind) };
	const paths = r.stdout
		.split("\n")
		.map((line) => line.trimEnd())
		.filter(Boolean)
		.map((line) => line.length > 3 ? line.slice(3) : line)
		.filter(Boolean);
	return { ok: true, paths };
}

type PathListResult =
	| { ok: true; paths: string[] }
	| { ok: false; result: RepoMainSyncResult };

function parseNulPaths(stdout: string): string[] {
	return stdout.split("\0").filter((path) => path.length > 0);
}

function incomingChangedPaths(root: string, localRef: string, remoteRef: string, ahead = 0, behind = 0): PathListResult {
	const r = runGit(root, ["diff", "--name-only", "-z", "--diff-filter=ACMRT", `${localRef}..${remoteRef}`]);
	if (!ok(r)) return { ok: false, result: failGit("incoming-paths-failed", r, [r.command], ahead, behind) };
	return { ok: true, paths: parseNulPaths(r.stdout) };
}

function ignoredFileCollisions(root: string, localRef: string, remoteRef: string, ahead: number, behind: number): PathListResult {
	const incoming = incomingChangedPaths(root, localRef, remoteRef, ahead, behind);
	if (!incoming.ok) return incoming;
	if (incoming.paths.length === 0) return { ok: true, paths: [] };
	const candidates = existingCollisionCandidates(root, incoming.paths, ahead, behind);
	if (!candidates.ok) return { ok: false, result: candidates.result };
	const ignored = ignoredCandidatePaths(root, candidates.checkIgnore, ahead, behind);
	if (!ignored.ok) return ignored;
	return { ok: true, paths: [...new Set([...candidates.directoryCollisions, ...ignored.paths])].sort() };
}

type CollisionCandidateResult =
	| { checkIgnore: string[]; directoryCollisions: string[]; ok: true }
	| { ok: false; result: RepoMainSyncResult };

function existingCollisionCandidates(root: string, incomingPaths: string[], ahead = 0, behind = 0): CollisionCandidateResult {
	const checkIgnore = new Set<string>();
	const directoryCollisions = new Set<string>();
	for (const incomingPath of incomingPaths) {
		const parts = incomingPath.split("/").filter(Boolean);
		for (let i = 1; i <= parts.length; i += 1) {
			const candidate = parts.slice(0, i).join("/");
			let stat;
			try {
				stat = lstatSync(resolve(root, candidate));
			} catch {
				break;
			}

			const isLeaf = i === parts.length;
			if (!isLeaf) {
				if (!stat.isDirectory()) {
					checkIgnore.add(candidate);
					break;
				}
				continue;
			}

			if (stat.isDirectory()) {
				const nonTracked = directoryHasNonTrackedEntries(root, candidate, ahead, behind);
				if (!nonTracked.ok) return nonTracked;
				if (nonTracked.hasNonTrackedEntries) directoryCollisions.add(candidate);
			} else {
				checkIgnore.add(candidate);
			}
		}
	}
	return { checkIgnore: [...checkIgnore].sort(), directoryCollisions: [...directoryCollisions].sort(), ok: true };
}

type DirectoryNonTrackedEntriesResult =
	| { hasNonTrackedEntries: boolean; ok: true }
	| { ok: false; result: RepoMainSyncResult };

function directoryHasNonTrackedEntries(root: string, candidate: string, ahead = 0, behind = 0): DirectoryNonTrackedEntriesResult {
	// Pass candidate as a literal path, not a git pathspec: directory names
	// containing glob magic ([ ] * ?) or a leading ':' must match exactly, or a
	// real collision could be missed and an unsafe fast-forward could clobber
	// local untracked/ignored content.
	const checks = [
		["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", candidate],
		["--literal-pathspecs", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", candidate],
	];
	for (const args of checks) {
		const r = runGit(root, args);
		if (r.error?.code === "ENOBUFS") return { hasNonTrackedEntries: true, ok: true };
		if (!ok(r)) return { ok: false, result: failGit("directory-collision-check-failed", r, [r.command], ahead, behind, [candidate]) };
		if (r.stdout.length > 0) return { hasNonTrackedEntries: true, ok: true };
	}
	return { hasNonTrackedEntries: false, ok: true };
}

const CHECK_IGNORE_STDIN_CHUNK_BYTES = 256 * 1024;
const CHECK_IGNORE_STDIN_CHUNK_PATHS = 512;

function ignoredCandidatePaths(root: string, paths: string[], ahead = 0, behind = 0): PathListResult {
	if (paths.length === 0) return { ok: true, paths: [] };
	const ignored = new Set<string>();
	for (const chunk of pathChunks(paths)) {
		const input = `${chunk.join("\0")}\0`;
		const r = runGit(root, ["check-ignore", "-z", "--stdin"], { input });
		if (r.error || (r.status !== 0 && r.status !== 1)) return { ok: false, result: failGit("ignored-paths-failed", r, [r.command], ahead, behind) };
		if (r.status === 0) {
			for (const path of parseNulPaths(r.stdout)) ignored.add(path);
		}
	}
	return { ok: true, paths: [...ignored].sort() };
}

function pathChunks(paths: string[]): string[][] {
	const chunks: string[][] = [];
	let chunk: string[] = [];
	let bytes = 0;
	for (const path of paths) {
		const size = Buffer.byteLength(path, "utf8") + 1;
		if (chunk.length > 0 && (chunk.length >= CHECK_IGNORE_STDIN_CHUNK_PATHS || bytes + size > CHECK_IGNORE_STDIN_CHUNK_BYTES)) {
			chunks.push(chunk);
			chunk = [];
			bytes = 0;
		}
		chunk.push(path);
		bytes += size;
	}
	if (chunk.length > 0) chunks.push(chunk);
	return chunks;
}

type RemoteBranchResult =
	| { ok: true }
	| { missing: true; ok: false }
	| { ok: false; result: RepoMainSyncResult };

function remoteBranchExists(root: string, remote: string, branch: string): RemoteBranchResult {
	const r = runGit(root, ["ls-remote", "--exit-code", remote, `refs/heads/${branch}`]);
	if (ok(r)) return { ok: true };
	if (!r.error && r.status === 2) return { missing: true, ok: false };
	return { ok: false, result: failGit("git-ls-remote-failed", r) };
}

function fetchRemoteTracking(root: string, remote: string, branch: string): GitRun {
	const sourceRef = `refs/heads/${branch}`;
	const destinationRef = `refs/remotes/${remote}/${branch}`;
	return runGit(root, ["fetch", "--prune", "--no-tags", "--refmap=", remote, `+${sourceRef}:${destinationRef}`]);
}

type CurrentBranchResult =
	| { branch: string; ok: true }
	| { ok: false; result: RepoMainSyncResult };

function currentBranch(root: string, ahead = 0, behind = 0): CurrentBranchResult {
	const r = runGit(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
	if (ok(r)) return { branch: r.stdout.trim(), ok: true };
	if (!r.error && r.status === 1 && !r.stderr.trim()) return { branch: "", ok: true };
	return { ok: false, result: failGit("git-symbolic-ref-failed", r, [r.command], ahead, behind) };
}

type BranchCheckoutResult =
	| { ok: true; paths: string[] }
	| { ok: false; result: RepoMainSyncResult };

function branchCheckoutPaths(root: string, branchRef: string, ahead: number, behind: number): BranchCheckoutResult {
	const r = runGit(root, ["worktree", "list", "--porcelain"]);
	if (!ok(r)) return { ok: false, result: failGit("git-worktree-list-failed", r, [r.command], ahead, behind) };
	const matches: string[] = [];
	let worktree = "";
	for (const raw of r.stdout.split("\n")) {
		const line = raw.trimEnd();
		if (!line) { worktree = ""; continue; }
		if (line.startsWith("worktree ")) { worktree = line.slice("worktree ".length); continue; }
		if (line === `branch ${branchRef}` && worktree) matches.push(resolve(worktree));
	}
	return { ok: true, paths: matches };
}

function commandsForDirty(root: string, remote: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} status --short`,
		"commit dirty work, move/copy it aside intentionally, or rerun later after the checkout is clean",
		"do not delete or discard dirty paths just to make repo sync pass",
		suggestedRerun(root, remote, branch),
	];
}

function commandsForCollision(root: string, localRef: string, remoteRef: string, remote: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} diff --name-only ${shellQuote(`${localRef}..${remoteRef}`)}`,
		`git -C ${shellQuote(root)} ls-files -o --exclude-standard`,
		`git -C ${shellQuote(root)} ls-files -o -i --exclude-standard`,
		"commit work, move/copy colliding ignored files aside intentionally, or rerun later after the checkout is safe",
		"do not delete or discard ignored/untracked files just to make repo sync pass",
		suggestedRerun(root, remote, branch),
	];
}

function commandsForAhead(root: string, remoteRef: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} log --oneline ${shellQuote(remoteRef)}..${shellQuote(branch)}`,
		`push, merge, or rebase local ${branch} commits intentionally`,
		"leave local branch ahead if those commits are deliberate",
	];
}

function commandsForDiverged(root: string, remoteRef: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} log --oneline --left-right ${shellQuote(branch)}...${shellQuote(remoteRef)}`,
		`git -C ${shellQuote(root)} switch ${shellQuote(branch)} && git -C ${shellQuote(root)} merge ${shellQuote(remoteRef)}`,
		`git -C ${shellQuote(root)} switch ${shellQuote(branch)} && git -C ${shellQuote(root)} rebase ${shellQuote(remoteRef)}`,
		`leave local ${branch} divergent`,
	];
}

function commandsForMissingRemote(root: string, remote: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} remote -v`,
		`git -C ${shellQuote(root)} ls-remote --exit-code ${shellQuote(remote)} ${shellQuote(`refs/heads/${branch}`)}`,
		`git -C ${shellQuote(root)} fetch --prune --no-tags --refmap= ${shellQuote(remote)} ${shellQuote(`+refs/heads/${branch}:refs/remotes/${remote}/${branch}`)}`,
	];
}

function syncMain(opts: Options): { projectRoot?: string; result: RepoMainSyncResult } {
	const top = repoTopLevel(opts.projectRoot);
	if (top.result) return { result: top.result };
	const root = top.root!;
	try { process.chdir(root); } catch { /* best effort: git -C still pins repo operations */ }

	const remoteBranch = remoteBranchExists(root, opts.remote, opts.branch);
	if (!remoteBranch.ok) {
		if ("result" in remoteBranch) return { projectRoot: root, result: remoteBranch.result };
		const dirty = dirtyStatus(root);
		if (!dirty.ok) return { projectRoot: root, result: dirty.result };
		return { projectRoot: root, result: blocked("missing-remote-branch", commandsForMissingRemote(root, opts.remote, opts.branch), 0, 0, dirty.paths) };
	}

	const fetch = fetchRemoteTracking(root, opts.remote, opts.branch);
	if (!ok(fetch)) return { projectRoot: root, result: failGit("git-fetch-failed", fetch) };

	const localRef = `refs/heads/${opts.branch}`;
	const remoteRef = `refs/remotes/${opts.remote}/${opts.branch}`;
	const localSha = revParse(root, localRef);
	const remoteSha = revParse(root, remoteRef);
	if (!remoteSha.ok && "result" in remoteSha) return { projectRoot: root, result: remoteSha.result };
	if (!localSha.ok && "result" in localSha) return { projectRoot: root, result: localSha.result };
	const statusBeforeRefBlock = !remoteSha.ok || !localSha.ok ? dirtyStatus(root) : null;
	if (statusBeforeRefBlock && !statusBeforeRefBlock.ok) return { projectRoot: root, result: statusBeforeRefBlock.result };
	if (!remoteSha.ok) {
		return { projectRoot: root, result: blocked("missing-remote-branch", commandsForMissingRemote(root, opts.remote, opts.branch), 0, 0, statusBeforeRefBlock?.paths ?? []) };
	}
	if (!localSha.ok) {
		return { projectRoot: root, result: blocked("missing-local-branch", [
			`git -C ${shellQuote(root)} branch --list ${shellQuote(opts.branch)}`,
			`git -C ${shellQuote(root)} switch -c ${shellQuote(opts.branch)} ${shellQuote(remoteRef)}`,
		], 0, 0, statusBeforeRefBlock?.paths ?? []) };
	}

	const counts = aheadBehind(root, localRef, remoteRef);
	if (!counts.ok) return { projectRoot: root, result: counts.result };
	const dirty = dirtyStatus(root, counts.ahead, counts.behind);
	if (!dirty.ok) return { projectRoot: root, result: dirty.result };
	if (dirty.paths.length > 0) return { projectRoot: root, result: blocked("dirty-worktree", commandsForDirty(root, opts.remote, opts.branch), counts.ahead, counts.behind, dirty.paths) };

	if (counts.ahead === 0 && counts.behind === 0) return { projectRoot: root, result: success("already-synced", "already-synced") };
	if (counts.ahead > 0 && counts.behind > 0) return { projectRoot: root, result: blocked("local-branch-diverged", commandsForDiverged(root, remoteRef, opts.branch), counts.ahead, counts.behind) };
	if (counts.ahead > 0) return { projectRoot: root, result: blocked("local-branch-ahead", commandsForAhead(root, remoteRef, opts.branch), counts.ahead, counts.behind) };

	const ancestor = runGit(root, ["merge-base", "--is-ancestor", localRef, remoteRef]);
	if (!ok(ancestor)) {
		if (!ancestor.error && ancestor.status === 1) return { projectRoot: root, result: blocked("fast-forward-ambiguous", commandsForDiverged(root, remoteRef, opts.branch), counts.ahead, counts.behind) };
		return { projectRoot: root, result: failGit("git-merge-base-failed", ancestor, commandsForDiverged(root, remoteRef, opts.branch), counts.ahead, counts.behind) };
	}

	const currentResult = currentBranch(root, counts.ahead, counts.behind);
	if (!currentResult.ok) return { projectRoot: root, result: currentResult.result };
	const current = currentResult.branch;
	if (current === opts.branch) {
		const collisions = ignoredFileCollisions(root, localRef, remoteRef, counts.ahead, counts.behind);
		if (!collisions.ok) return { projectRoot: root, result: collisions.result };
		if (collisions.paths.length > 0) {
			return { projectRoot: root, result: blocked("ignored-file-collision", commandsForCollision(root, localRef, remoteRef, opts.remote, opts.branch), counts.ahead, counts.behind, collisions.paths) };
		}
		const merge = runGit(root, ["merge", "--ff-only", remoteRef]);
		if (!ok(merge)) return { projectRoot: root, result: failGit("fast-forward-failed", merge, commandsForDirty(root, opts.remote, opts.branch), counts.ahead, counts.behind) };
	} else {
		const checkoutResult = branchCheckoutPaths(root, localRef, counts.ahead, counts.behind);
		if (!checkoutResult.ok) return { projectRoot: root, result: checkoutResult.result };
		const checkoutPaths = checkoutResult.paths.filter((path) => path !== resolve(root));
		if (checkoutPaths.length > 0) {
			return { projectRoot: root, result: blocked("branch-checked-out-in-other-worktree", [
				`run from worktree: ${checkoutPaths[0]}`,
				`git -C ${shellQuote(checkoutPaths[0]!)} status --short`,
				suggestedRerun(checkoutPaths[0]!, opts.remote, opts.branch),
			], counts.ahead, counts.behind) };
		}
		const update = runGit(root, ["update-ref", localRef, remoteSha.sha, localSha.sha]);
		if (!ok(update)) return { projectRoot: root, result: failGit("fast-forward-ref-update-failed", update, [], counts.ahead, counts.behind) };
	}

	const after = aheadBehind(root, localRef, remoteRef);
	if (!after.ok) return { projectRoot: root, result: after.result };
	if (after.ahead !== 0 || after.behind !== 0) return { projectRoot: root, result: fail("post-sync-verify-failed", [], after.ahead, after.behind) };
	return { projectRoot: root, result: success("synced", current === opts.branch ? "fast-forwarded-worktree" : "fast-forwarded-local-ref") };
}

function tmuxSessionName(): string {
	if (process.env.FLIGHTDECK_SESSION?.trim()) return process.env.FLIGHTDECK_SESSION.trim();
	if (!process.env.TMUX) return "";
	const r = spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" });
	return r.status === 0 ? (r.stdout ?? "").trim() : "";
}

function emitIfManaged(result: RepoMainSyncResult, projectRoot: string | undefined, opts: Options): void {
	if (!process.env.FLIGHTDECK_ACTIVITY_FILE && process.env.FLIGHTDECK_MANAGED !== "1") return;
	let session = "";
	try {
		session = tmuxSessionName();
		const explicitActivityPath = process.env.FLIGHTDECK_ACTIVITY_FILE?.trim();
		emitRepoMainSync({
			activityPath: explicitActivityPath || undefined,
			sessionId: session || undefined,
			stateFile: !explicitActivityPath && session ? statePath(session) : undefined,
			tmuxSession: session || undefined,
		}, result, { branch: opts.branch, projectRoot, remote: opts.remote });
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		process.stderr.write(`flightdeck-repo-sync: activity emit failed status=${result.status} reason=${result.reason} session=${session || "<none>"}: ${message}\n`);
	}
}

const opts = parseArgs(process.argv.slice(2));
const { projectRoot, result } = syncMain(opts);
emitIfManaged(result, projectRoot, opts);
process.stdout.write(`${JSON.stringify(result)}\n`);
process.exit(result.status === "failed" ? 1 : 0);
