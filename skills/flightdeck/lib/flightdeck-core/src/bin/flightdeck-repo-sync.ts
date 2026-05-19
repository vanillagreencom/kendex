#!/usr/bin/env bun
// Safe post-merge repository sync helper for Flightdeck.
// Only fast-forwards a clean local default branch to its remote-tracking ref.

import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";

import { emitRepoMainSync, type RepoMainSyncResult } from "../activity/workflow-emit.ts";
import { statePath } from "../state/master-state.ts";

interface GitRun {
	status: number | null;
	stdout: string;
	stderr: string;
	error?: Error;
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
	if (!remote.trim() || remote.startsWith("-")) usage();
	if (!branch.trim() || branch.startsWith("-") || !isSafeRefComponent(branch)) usage();
	return { action: "main", branch: branch.trim(), json, projectRoot: projectRoot.trim(), remote: remote.trim() };
}

function isSafeRefComponent(value: string): boolean {
	if (!/^[A-Za-z0-9._/+-]+$/.test(value)) return false;
	if (value.includes("..") || value.includes("@{") || value.includes("//")) return false;
	if (value.endsWith(".") || value.endsWith("/") || value.includes(".lock")) return false;
	return true;
}

function runGit(cwd: string, args: string[]): GitRun {
	const r = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
	return { error: r.error, status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function ok(run: GitRun): boolean {
	return !run.error && run.status === 0;
}

function fail(reason: string, commands: string[], stderr = "", ahead = 0, behind = 0, dirtyPaths: string[] = []): RepoMainSyncResult {
	return { ahead, behind, commands_suggested: commands, dirty_paths: dirtyPaths, reason: withStderr(reason, stderr), status: "failed" };
}

function blocked(reason: string, commands: string[], ahead = 0, behind = 0, dirtyPaths: string[] = []): RepoMainSyncResult {
	return { ahead, behind, commands_suggested: commands, dirty_paths: dirtyPaths, reason, status: "blocked" };
}

function success(status: "synced" | "already-synced", reason: string, ahead = 0, behind = 0): RepoMainSyncResult {
	return { ahead, behind, commands_suggested: [], dirty_paths: [], reason, status };
}

function withStderr(reason: string, stderr: string): string {
	const clean = stderr.trim().replace(/\s+/g, " ");
	return clean ? `${reason}: ${clean}` : reason;
}

function shellQuote(value: string): string {
	if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(value)) return value;
	return `'${value.replace(/'/g, `'\\''`)}'`;
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
	if (!ok(top)) return { result: fail("git-repo-invalid", [], top.stderr) };
	return { root: top.stdout.trim() || dir };
}

function revParse(root: string, ref: string): string | null {
	const r = runGit(root, ["rev-parse", "--verify", "--quiet", ref]);
	return ok(r) ? r.stdout.trim() : null;
}

function aheadBehind(root: string, localRef: string, remoteRef: string): { ahead: number; behind: number; error?: string } {
	const r = runGit(root, ["rev-list", "--left-right", "--count", `${localRef}...${remoteRef}`]);
	if (!ok(r)) return { ahead: 0, behind: 0, error: withStderr("ahead-behind-failed", r.stderr) };
	const [aheadRaw, behindRaw] = r.stdout.trim().split(/\s+/);
	const ahead = Number.parseInt(aheadRaw ?? "0", 10);
	const behind = Number.parseInt(behindRaw ?? "0", 10);
	if (!Number.isFinite(ahead) || !Number.isFinite(behind)) return { ahead: 0, behind: 0, error: "ahead-behind-parse-failed" };
	return { ahead, behind };
}

function dirtyPaths(root: string): string[] {
	const r = runGit(root, ["status", "--porcelain=v1", "--untracked-files=all"]);
	if (!ok(r)) return ["<git-status-failed>"];
	return r.stdout
		.split("\n")
		.map((line) => line.trimEnd())
		.filter(Boolean)
		.map((line) => line.length > 3 ? line.slice(3) : line)
		.filter(Boolean);
}

function currentBranch(root: string): string {
	const r = runGit(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
	return ok(r) ? r.stdout.trim() : "";
}

function branchCheckoutPaths(root: string, branchRef: string): string[] {
	const r = runGit(root, ["worktree", "list", "--porcelain"]);
	if (!ok(r)) return [];
	const matches: string[] = [];
	let worktree = "";
	for (const raw of r.stdout.split("\n")) {
		const line = raw.trimEnd();
		if (!line) { worktree = ""; continue; }
		if (line.startsWith("worktree ")) { worktree = line.slice("worktree ".length); continue; }
		if (line === `branch ${branchRef}` && worktree) matches.push(resolve(worktree));
	}
	return matches;
}

function commandsForDirty(root: string, remote: string, branch: string): string[] {
	return [
		`git -C ${shellQuote(root)} status --short`,
		"commit, remove, or move dirty paths out of the checkout",
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

function syncMain(opts: Options): { projectRoot?: string; result: RepoMainSyncResult } {
	const top = repoTopLevel(opts.projectRoot);
	if (top.result) return { result: top.result };
	const root = top.root!;
	try { process.chdir(root); } catch { /* best effort: git -C still pins repo operations */ }

	const fetch = runGit(root, ["fetch", opts.remote, "--prune"]);
	if (!ok(fetch)) return { projectRoot: root, result: fail("git-fetch-failed", [], fetch.stderr) };

	const localRef = `refs/heads/${opts.branch}`;
	const remoteRef = `refs/remotes/${opts.remote}/${opts.branch}`;
	const localSha = revParse(root, localRef);
	const remoteSha = revParse(root, remoteRef);
	if (!remoteSha) {
		return { projectRoot: root, result: blocked("missing-remote-branch", [
			`git -C ${shellQuote(root)} remote -v`,
			`git -C ${shellQuote(root)} fetch ${shellQuote(opts.remote)} --prune`,
		], 0, 0, dirtyPaths(root)) };
	}
	if (!localSha) {
		return { projectRoot: root, result: blocked("missing-local-branch", [
			`git -C ${shellQuote(root)} branch --list ${shellQuote(opts.branch)}`,
			`git -C ${shellQuote(root)} switch -c ${shellQuote(opts.branch)} ${shellQuote(remoteRef)}`,
		], 0, 0, dirtyPaths(root)) };
	}

	const counts = aheadBehind(root, localRef, remoteRef);
	if (counts.error) return { projectRoot: root, result: fail(counts.error, [], "") };
	const dirty = dirtyPaths(root);
	if (dirty.length > 0) return { projectRoot: root, result: blocked("dirty-worktree", commandsForDirty(root, opts.remote, opts.branch), counts.ahead, counts.behind, dirty) };

	if (counts.ahead === 0 && counts.behind === 0) return { projectRoot: root, result: success("already-synced", "already-synced") };
	if (counts.ahead > 0 && counts.behind > 0) return { projectRoot: root, result: blocked("local-branch-diverged", commandsForDiverged(root, remoteRef, opts.branch), counts.ahead, counts.behind) };
	if (counts.ahead > 0) return { projectRoot: root, result: blocked("local-branch-ahead", commandsForAhead(root, remoteRef, opts.branch), counts.ahead, counts.behind) };

	const ancestor = runGit(root, ["merge-base", "--is-ancestor", localRef, remoteRef]);
	if (!ok(ancestor)) return { projectRoot: root, result: blocked("fast-forward-ambiguous", commandsForDiverged(root, remoteRef, opts.branch), counts.ahead, counts.behind) };

	const current = currentBranch(root);
	if (current === opts.branch) {
		const merge = runGit(root, ["merge", "--ff-only", remoteRef]);
		if (!ok(merge)) return { projectRoot: root, result: fail("fast-forward-failed", commandsForDirty(root, opts.remote, opts.branch), merge.stderr, counts.ahead, counts.behind) };
	} else {
		const checkoutPaths = branchCheckoutPaths(root, localRef).filter((path) => path !== resolve(root));
		if (checkoutPaths.length > 0) {
			return { projectRoot: root, result: blocked("branch-checked-out-in-other-worktree", [
				`run from worktree: ${checkoutPaths[0]}`,
				`git -C ${shellQuote(checkoutPaths[0]!)} status --short`,
				suggestedRerun(checkoutPaths[0]!, opts.remote, opts.branch),
			], counts.ahead, counts.behind) };
		}
		const update = runGit(root, ["update-ref", localRef, remoteSha, localSha]);
		if (!ok(update)) return { projectRoot: root, result: fail("fast-forward-ref-update-failed", [], update.stderr, counts.ahead, counts.behind) };
	}

	const after = aheadBehind(root, localRef, remoteRef);
	if (after.error) return { projectRoot: root, result: fail(after.error, [], "") };
	if (after.ahead !== 0 || after.behind !== 0) return { projectRoot: root, result: fail("post-sync-verify-failed", [], "", after.ahead, after.behind) };
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
	try {
		const session = tmuxSessionName();
		emitRepoMainSync({
			activityPath: process.env.FLIGHTDECK_ACTIVITY_FILE,
			sessionId: session || undefined,
			stateFile: session ? statePath(session) : undefined,
			tmuxSession: session || undefined,
		}, result, { branch: opts.branch, projectRoot, remote: opts.remote });
	} catch {
		// Activity is best-effort; helper JSON is the source of truth for callers.
	}
}

const opts = parseArgs(process.argv.slice(2));
const { projectRoot, result } = syncMain(opts);
emitIfManaged(result, projectRoot, opts);
process.stdout.write(`${JSON.stringify(result)}\n`);
process.exit(result.status === "failed" ? 1 : 0);
