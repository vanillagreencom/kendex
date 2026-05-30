import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-repo-sync");

const GIT_ENV: Record<string, string> = {
	...(process.env as Record<string, string>),
	GIT_AUTHOR_EMAIL: "flightdeck@example.test",
	GIT_AUTHOR_NAME: "Flightdeck Test",
	GIT_COMMITTER_EMAIL: "flightdeck@example.test",
	GIT_COMMITTER_NAME: "Flightdeck Test",
};

interface Fixture {
	clone: string;
	origin: string;
	seed: string;
	tmp: string;
}

interface SyncResult {
	status: "synced" | "already-synced" | "blocked" | "failed";
	ahead: number;
	behind: number;
	dirty_paths: string[];
	reason: string;
	commands_suggested: string[];
	diagnostics?: Array<Record<string, unknown>>;
}

let fixture: Fixture | null = null;

beforeEach(() => {
	fixture = makeFixture();
});

afterEach(() => {
	if (fixture?.tmp && existsSync(fixture.tmp)) rmSync(fixture.tmp, { force: true, recursive: true });
	fixture = null;
});

function sh(cmd: string, args: string[], opts: { cwd?: string; env?: Record<string, string> } = {}): { status: number | null; stdout: string; stderr: string } {
	const r = spawnSync(cmd, args, { cwd: opts.cwd, encoding: "utf8", env: opts.env ?? GIT_ENV });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function realGit(): string {
	const r = spawnSync("bash", ["-lc", "command -v git"], { encoding: "utf8" });
	if (r.status !== 0 || !r.stdout.trim()) throw new Error(`cannot locate real git: ${r.stderr}`);
	return r.stdout.trim();
}

function bashQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

function gitShim(failureCase: string): Record<string, string> {
	if (!fixture) throw new Error("fixture missing");
	const bin = join(fixture.tmp, "fake-bin");
	mkdirSync(bin, { recursive: true });
	const script = join(bin, "git");
	writeFileSync(script, `#!/usr/bin/env bash
set -euo pipefail
case " $* " in
${failureCase}
esac
exec ${bashQuote(realGit())} "$@"
`, "utf8");
	chmodSync(script, 0o755);
	return { PATH: `${bin}:${process.env.PATH ?? ""}` };
}

function failStatusShim(): Record<string, string> {
	return gitShim(`  *" status --porcelain=v1 --untracked-files=all "*) echo "status exploded" >&2; exit 44 ;;`);
}

function failStatusOversizedStdoutShim(): Record<string, string> {
	// Emit > 4 KiB of NUL-separated path-like junk on stdout plus a short stderr,
	// then exit non-zero. Mirrors the real-world failure mode where a `git ls-files
	// -z` or `git diff --name-only -z` run produces huge stdout and a downstream
	// failure ends up dumping that stdout into the diagnostic JSON.
	return gitShim(`  *" status --porcelain=v1 --untracked-files=all "*) python3 -c 'import sys; sys.stdout.write("path/" + "\\x00".join("file" + str(i) + ".rs" for i in range(800)))' ; echo "status exploded" >&2; exit 44 ;;`);
}

function hugeIgnoredListShim(): Record<string, string> {
	return gitShim(`  *" ls-files -z -o -i --exclude-standard "*) python3 -c 'import sys; sys.stdout.write("".join("ignored/tree/file-" + str(i) + ".txt\\x00" for i in range(90000)))' ; exit 0 ;;`);
}

function hugeDirectoryOthersShim(): Record<string, string> {
	// Force the directory-collision predicate's `ls-files --others -- foo` probe to
	// emit > 1 MiB of NUL-separated output so spawnSync raises ENOBUFS, exercising the
	// directoryHasNonTrackedEntries ENOBUFS -> treat-as-collision fail-safe branch.
	return gitShim(`  *" ls-files -z --others --exclude-standard -- foo "*) python3 -c 'import sys; sys.stdout.write("".join("foo/junk-" + str(i) + ".txt\\x00" for i in range(90000)))' ; exit 0 ;;`);
}

function failDirectoryOthersShim(): Record<string, string> {
	// Force the directory-collision predicate's `ls-files --others -- foo` probe to
	// fail non-zero, exercising the directory-collision-check-failed propagation path.
	return gitShim(`  *" ls-files -z --others --exclude-standard -- foo "*) echo "ls-files exploded" >&2; exit 33 ;;`);
}

function failFetchShim(): Record<string, string> {
	return gitShim(`  *" fetch --prune --no-tags --refmap= origin +refs/heads/main:refs/remotes/origin/main "*) echo "fetch exploded" >&2; exit 47 ;;`);
}

function failWorktreeListShim(): Record<string, string> {
	return gitShim(`  *" worktree list --porcelain "*) echo "worktree list exploded" >&2; exit 45 ;;`);
}

function failSymbolicRefShim(): Record<string, string> {
	return gitShim(`  *" symbolic-ref --quiet --short HEAD "*) echo "symbolic-ref exploded" >&2; exit 1 ;;`);
}

function git(cwd: string, args: string[]): string {
	const r = sh("git", ["-c", "commit.gpgsign=false", "-C", cwd, ...args]);
	if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
	return r.stdout.trim();
}

function makeFixture(): Fixture {
	const tmp = mkdtempSync(join(tmpdir(), "fd-repo-sync-"));
	const seed = join(tmp, "seed");
	const origin = join(tmp, "origin.git");
	const clone = join(tmp, "primary");
	sh("git", ["init", "-q", "-b", "main", seed]);
	writeFileSync(join(seed, "README.md"), "base\n", "utf8");
	git(seed, ["add", "README.md"]);
	git(seed, ["commit", "-q", "-m", "base"]);
	sh("git", ["init", "--bare", "-q", origin]);
	git(seed, ["remote", "add", "origin", origin]);
	git(seed, ["push", "-q", "-u", "origin", "main"]);
	git(origin, ["symbolic-ref", "HEAD", "refs/heads/main"]);
	sh("git", ["clone", "-q", origin, clone]);
	return { clone, origin, seed, tmp };
}

function commitFile(repo: string, file: string, content: string, message: string): void {
	mkdirSync(dirname(join(repo, file)), { recursive: true });
	writeFileSync(join(repo, file), content, "utf8");
	git(repo, ["add", file]);
	git(repo, ["commit", "-q", "-m", message]);
}

function pushSeed(file: string, content: string, message: string): void {
	if (!fixture) throw new Error("fixture missing");
	commitFile(fixture.seed, file, content, message);
	git(fixture.seed, ["push", "-q", "origin", "main"]);
}

function runSync(extraEnv: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string; json: SyncResult } {
	return runSyncForBranch("main", extraEnv);
}

function runSyncForBranch(branch: string, extraEnv: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string; json: SyncResult } {
	if (!fixture) throw new Error("fixture missing");
	const env = { ...GIT_ENV, ...extraEnv };
	const r = sh(SCRIPT, ["main", "--project-root", fixture.clone, "--remote", "origin", "--branch", branch, "--json"], { env });
	const json = JSON.parse(r.stdout) as SyncResult;
	return { ...r, json };
}

function rev(repo: string, ref: string): string {
	return git(repo, ["rev-parse", ref]);
}

function hasRef(repo: string, ref: string): boolean {
	return sh("git", ["-C", repo, "rev-parse", "--verify", "--quiet", ref]).status === 0;
}

describe("flightdeck-repo-sync main", () => {
	test("helper source never shells out to destructive cleanup commands", () => {
		const source = readFileSync(resolve(HERE, "../../src/bin/flightdeck-repo-sync.ts"), "utf8");
		expect(source).not.toContain("reset --hard");
		expect(source).not.toContain("stash");
		expect(source).not.toContain("clean -fd");
		expect(source).not.toContain("force-push");
	});

	test("already synced local main returns already-synced and emits activity", () => {
		if (!fixture) throw new Error("fixture missing");
		const activityFile = join(fixture.tmp, "activity.jsonl");
		const result = runSync({ FLIGHTDECK_ACTIVITY_FILE: activityFile, FLIGHTDECK_SESSION: "explicit-session", FLIGHTDECK_STATE_DIR: "/dev/null/fd-state" });
		expect(result.status).toBe(0);
		expect(result.stderr).not.toContain("activity emit failed");
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "already-synced", status: "already-synced" });
		expect(result.json.dirty_paths).toEqual([]);
		const [row] = readFileSync(activityFile, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
		expect(row).toMatchObject({ severity: "success", source: "workflow", type: "repo.main_synced" });
	});

	test("managed activity setup failure logs stderr without changing helper result", () => {
		// vstack#227: FLIGHTDECK_STATE_DIR no longer controls live
		// state. Point FLIGHTDECK_RUN_STORE_ROOT at a non-directory
		// path so the run-store setup throws and the helper logs the
		// emit failure on stderr without altering the JSON payload's
		// `status: already-synced`.
		const result = runSync({ FLIGHTDECK_MANAGED: "1", FLIGHTDECK_SESSION: "managed-session", FLIGHTDECK_RUN_STORE_ROOT: "/dev/null/fd-state" });
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("already-synced");
		expect(result.stderr).toContain("flightdeck-repo-sync: activity emit failed");
		expect(result.stderr).toContain("status=already-synced");
		expect(result.stderr).toContain("session=managed-session");
	});

	test("missing remote branch blocks instead of reporting fetch failure", () => {
		if (!fixture) throw new Error("fixture missing");
		git(fixture.clone, ["switch", "-q", "-c", "local-only"]);
		const result = runSyncForBranch("local-only");
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "missing-remote-branch", status: "blocked" });
		expect(result.json.diagnostics).toBeUndefined();
		expect(result.json.commands_suggested.join("\n")).toContain("ls-remote --exit-code origin refs/heads/local-only");
		expect(result.json.commands_suggested.join("\n")).toContain("fetch --prune --no-tags --refmap= origin +refs/heads/local-only:refs/remotes/origin/local-only");
	});

	test("git fetch failure returns failed diagnostics", () => {
		const result = runSync(failFetchShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		expect(result.json.reason).toContain("git-fetch-failed");
		expect(result.json.reason).toContain("exit 47");
		expect(result.json.reason).toContain("fetch exploded");
		expect(result.json.diagnostics?.[0]).toMatchObject({ exit_status: 47, stderr: "fetch exploded" });
		expect(result.json.diagnostics?.[0]?.command).toContain("fetch --prune --no-tags --refmap= origin +refs/heads/main:refs/remotes/origin/main");
	});

	test("clean behind local main fast-forwards to origin/main", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("remote.txt", "remote\n", "remote update");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "fast-forwarded-worktree", status: "synced" });
		expect(rev(fixture.clone, "main")).toBe(rev(fixture.clone, "origin/main"));
		expect(readFileSync(join(fixture.clone, "remote.txt"), "utf8")).toBe("remote\n");
	});

	test("fetch uses no-tags and does not auto-follow remote tags", () => {
		if (!fixture) throw new Error("fixture missing");
		const tagName = "repo-sync-auto-follow";
		const tagRef = `refs/tags/${tagName}`;
		const control = join(fixture.tmp, "control");
		const controlClone = sh("git", ["clone", "-q", fixture.origin, control]);
		expect(controlClone.status).toBe(0);
		commitFile(fixture.seed, "tagged.txt", "tagged\n", "tagged update");
		git(fixture.seed, ["tag", "-a", tagName, "-m", "tag that default fetch would auto-follow"]);
		git(fixture.seed, ["push", "-q", "origin", "main", tagRef]);

		expect(hasRef(control, tagRef)).toBe(false);
		const controlFetch = sh("git", ["-C", control, "fetch", "--prune", "--refmap=", "origin", "+refs/heads/main:refs/remotes/origin/main"]);
		expect(controlFetch.status).toBe(0);
		expect(hasRef(control, tagRef)).toBe(true);

		git(fixture.clone, ["config", "remote.origin.tagOpt", "--tags"]);
		expect(hasRef(fixture.clone, tagRef)).toBe(false);
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "fast-forwarded-worktree", status: "synced" });
		expect(rev(fixture.clone, "main")).toBe(rev(fixture.clone, "origin/main"));
		expect(readFileSync(join(fixture.clone, "tagged.txt"), "utf8")).toBe("tagged\n");
		expect(hasRef(fixture.clone, tagRef)).toBe(false);
	});

	test("large unrelated ignored output does not block checked-out main fast-forward", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("remote.txt", "remote\n", "remote update");
		const result = runSync(hugeIgnoredListShim());
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "fast-forwarded-worktree", status: "synced" });
		expect(result.json.diagnostics).toBeUndefined();
		expect(rev(fixture.clone, "main")).toBe(rev(fixture.clone, "origin/main"));
		expect(readFileSync(join(fixture.clone, "remote.txt"), "utf8")).toBe("remote\n");
	});

	test("ignored file collision blocks before checked-out main fast-forward", () => {
		if (!fixture) throw new Error("fixture missing");
		const ignoredPath = join(fixture.clone, "ignored.txt");
		writeFileSync(join(fixture.clone, ".git/info/exclude"), "\nignored.txt\n", { flag: "a" });
		writeFileSync(ignoredPath, "local ignored work\n", "utf8");
		expect(git(fixture.clone, ["status", "--porcelain=v1", "--untracked-files=all"])).toBe("");
		const before = rev(fixture.clone, "main");
		pushSeed("ignored.txt", "remote tracked\n", "track ignored path");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("ignored-file-collision");
		expect(result.json.ahead).toBe(0);
		expect(result.json.behind).toBe(1);
		expect(result.json.dirty_paths).toContain("ignored.txt");
		expect(result.json.commands_suggested.join("\n")).toContain("ls-files -o -i --exclude-standard");
		expect(result.json.commands_suggested.join("\n")).toContain("do not delete or discard ignored/untracked files");
		expect(readFileSync(ignoredPath, "utf8")).toBe("local ignored work\n");
		expect(rev(fixture.clone, "main")).toBe(before);
		expect(rev(fixture.clone, "origin/main")).not.toBe(before);
	});

	test("tracked-only directory replaced by incoming file fast-forwards checked-out main", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("foo/a.txt", "tracked dir content\n", "track foo dir");
		const setup = runSync();
		expect(setup.status).toBe(0);
		expect(setup.json.status).toBe("synced");
		expect(readFileSync(join(fixture.clone, "foo/a.txt"), "utf8")).toBe("tracked dir content\n");

		rmSync(join(fixture.seed, "foo"), { force: true, recursive: true });
		writeFileSync(join(fixture.seed, "foo"), "remote file content\n", "utf8");
		git(fixture.seed, ["add", "-A", "foo"]);
		git(fixture.seed, ["commit", "-q", "-m", "replace foo dir with file"]);
		git(fixture.seed, ["push", "-q", "origin", "main"]);
		expect(git(fixture.clone, ["status", "--porcelain=v1", "--untracked-files=all"])).toBe("");

		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "fast-forwarded-worktree", status: "synced" });
		expect(result.json.dirty_paths).toEqual([]);
		expect(readFileSync(join(fixture.clone, "foo"), "utf8")).toBe("remote file content\n");
		expect(existsSync(join(fixture.clone, "foo/a.txt"))).toBe(false);
		expect(rev(fixture.clone, "main")).toBe(rev(fixture.clone, "origin/main"));
	});

	test("ignored entry inside directory replaced by incoming file still blocks", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("foo/a.txt", "tracked dir content\n", "track foo dir");
		const setup = runSync();
		expect(setup.status).toBe(0);
		expect(setup.json.status).toBe("synced");

		const ignoredPath = join(fixture.clone, "foo/ignored.txt");
		writeFileSync(join(fixture.clone, ".git/info/exclude"), "\nfoo/ignored.txt\n", { flag: "a" });
		writeFileSync(ignoredPath, "local ignored work\n", "utf8");
		expect(git(fixture.clone, ["status", "--porcelain=v1", "--untracked-files=all"])).toBe("");
		const before = rev(fixture.clone, "main");

		rmSync(join(fixture.seed, "foo"), { force: true, recursive: true });
		writeFileSync(join(fixture.seed, "foo"), "remote file content\n", "utf8");
		git(fixture.seed, ["add", "-A", "foo"]);
		git(fixture.seed, ["commit", "-q", "-m", "replace foo dir with file"]);
		git(fixture.seed, ["push", "-q", "origin", "main"]);

		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("ignored-file-collision");
		expect(result.json.ahead).toBe(0);
		expect(result.json.behind).toBe(1);
		expect(result.json.dirty_paths).toContain("foo");
		expect(readFileSync(ignoredPath, "utf8")).toBe("local ignored work\n");
		expect(rev(fixture.clone, "main")).toBe(before);
		expect(rev(fixture.clone, "origin/main")).not.toBe(before);
	});

	test("oversized directory others-listing treats dir->file transition as collision (ENOBUFS fail-safe)", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("foo/a.txt", "tracked dir content\n", "track foo dir");
		expect(runSync().json.status).toBe("synced");

		rmSync(join(fixture.seed, "foo"), { force: true, recursive: true });
		writeFileSync(join(fixture.seed, "foo"), "remote file content\n", "utf8");
		git(fixture.seed, ["add", "-A", "foo"]);
		git(fixture.seed, ["commit", "-q", "-m", "replace foo dir with file"]);
		git(fixture.seed, ["push", "-q", "origin", "main"]);
		expect(git(fixture.clone, ["status", "--porcelain=v1", "--untracked-files=all"])).toBe("");
		const before = rev(fixture.clone, "main");

		// Huge `ls-files --others -- foo` output trips spawnSync ENOBUFS; the predicate
		// must fail safe by treating the directory as a collision and blocking the ff.
		const result = runSync(hugeDirectoryOthersShim());
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("ignored-file-collision");
		expect(result.json.dirty_paths).toContain("foo");
		expect(existsSync(join(fixture.clone, "foo/a.txt"))).toBe(true);
		expect(rev(fixture.clone, "main")).toBe(before);
	});

	test("directory others-listing git failure surfaces directory-collision-check-failed", () => {
		if (!fixture) throw new Error("fixture missing");
		pushSeed("foo/a.txt", "tracked dir content\n", "track foo dir");
		expect(runSync().json.status).toBe("synced");

		rmSync(join(fixture.seed, "foo"), { force: true, recursive: true });
		writeFileSync(join(fixture.seed, "foo"), "remote file content\n", "utf8");
		git(fixture.seed, ["add", "-A", "foo"]);
		git(fixture.seed, ["commit", "-q", "-m", "replace foo dir with file"]);
		git(fixture.seed, ["push", "-q", "origin", "main"]);
		const before = rev(fixture.clone, "main");

		const result = runSync(failDirectoryOthersShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		expect(result.json.reason).toContain("directory-collision-check-failed");
		expect(result.json.reason).toContain("exit 33");
		expect(result.json.diagnostics?.[0]).toMatchObject({ exit_status: 33 });
		expect(rev(fixture.clone, "main")).toBe(before);
	});

	test("clean non-main checkout fast-forwards local main ref without switching", () => {
		if (!fixture) throw new Error("fixture missing");
		git(fixture.clone, ["switch", "-q", "-c", "feature"]);
		pushSeed("remote.txt", "remote\n", "remote update");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "fast-forwarded-local-ref", status: "synced" });
		expect(git(fixture.clone, ["branch", "--show-current"])).toBe("feature");
		expect(rev(fixture.clone, "main")).toBe(rev(fixture.clone, "origin/main"));
		expect(existsSync(join(fixture.clone, "remote.txt"))).toBe(false);
	});

	test("dirty checkout blocks and leaves local main unchanged", () => {
		if (!fixture) throw new Error("fixture missing");
		const before = rev(fixture.clone, "main");
		pushSeed("remote.txt", "remote\n", "remote update");
		writeFileSync(join(fixture.clone, "README.md"), "dirty\n", "utf8");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("dirty-worktree");
		expect(result.json.ahead).toBe(0);
		expect(result.json.behind).toBe(1);
		expect(result.json.dirty_paths).toContain("README.md");
		const suggestions = result.json.commands_suggested.join("\n");
		expect(suggestions).toContain("git -C");
		expect(suggestions).toContain("move/copy it aside intentionally");
		expect(suggestions).toContain("do not delete or discard dirty paths");
		expect(suggestions).not.toContain("commit, remove");
		expect(rev(fixture.clone, "main")).toBe(before);
	});

	test("explicit fetch refspec ignores configured local-branch refspec and preserves local main", () => {
		if (!fixture) throw new Error("fixture missing");
		commitFile(fixture.clone, "local.txt", "local\n", "local main only");
		git(fixture.clone, ["switch", "-q", "-c", "feature"]);
		const before = rev(fixture.clone, "refs/heads/main");
		git(fixture.clone, ["config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/heads/main"]);
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 1, behind: 0, reason: "local-branch-ahead", status: "blocked" });
		expect(rev(fixture.clone, "refs/heads/main")).toBe(before);
		expect(rev(fixture.clone, "refs/remotes/origin/main")).not.toBe(before);
	});

	test("untracked nested paths are reported as dirty", () => {
		if (!fixture) throw new Error("fixture missing");
		mkdirSync(join(fixture.clone, "newdir"));
		writeFileSync(join(fixture.clone, "newdir/new.txt"), "new\n", "utf8");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("dirty-worktree");
		expect(result.json.dirty_paths).toContain("newdir/new.txt");
	});

	test("staged paths are reported as dirty", () => {
		if (!fixture) throw new Error("fixture missing");
		writeFileSync(join(fixture.clone, "staged.txt"), "staged\n", "utf8");
		git(fixture.clone, ["add", "staged.txt"]);
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("dirty-worktree");
		expect(result.json.dirty_paths).toContain("staged.txt");
	});

	test("git status failure returns failed diagnostics instead of dirty placeholder", () => {
		const result = runSync(failStatusShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		expect(result.json.reason).toContain("git-status-failed");
		expect(result.json.reason).toContain("exit 44");
		expect(result.json.reason).toContain("status exploded");
		expect(result.json.dirty_paths).toEqual([]);
		expect(result.json.diagnostics?.[0]).toMatchObject({ exit_status: 44, stderr: "status exploded" });
		expect(result.json.diagnostics?.[0]?.command).toContain("status --porcelain=v1 --untracked-files=all");
	});

	test("diagnostic stdout/stderr are capped on oversized output", () => {
		const result = runSync(failStatusOversizedStdoutShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		const diag = result.json.diagnostics?.[0];
		expect(diag).toBeDefined();
		const stdout = (diag?.stdout ?? "") as string;
		// Cap is 2048 bytes; allow some headroom for the truncation marker (“ellipsis + [truncated N bytes]”).
		expect(stdout.length).toBeGreaterThan(0);
		expect(stdout.length).toBeLessThan(2200);
		expect(stdout).toContain("truncated");
	});

	test("symbolic-ref failure fails before updating checked-out main ref", () => {
		if (!fixture) throw new Error("fixture missing");
		const before = rev(fixture.clone, "main");
		pushSeed("remote.txt", "remote\n", "remote update");
		const result = runSync(failSymbolicRefShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		expect(result.json.reason).toContain("git-symbolic-ref-failed");
		expect(result.json.reason).toContain("exit 1");
		expect(result.json.reason).toContain("symbolic-ref exploded");
		expect(result.json.diagnostics?.[0]).toMatchObject({ exit_status: 1, stderr: "symbolic-ref exploded" });
		expect(result.json.diagnostics?.[0]?.command).toContain("symbolic-ref --quiet --short HEAD");
		expect(rev(fixture.clone, "main")).toBe(before);
		expect(existsSync(join(fixture.clone, "remote.txt"))).toBe(false);
	});

	test("ahead-only local main blocks safely", () => {
		if (!fixture) throw new Error("fixture missing");
		commitFile(fixture.clone, "local.txt", "local\n", "local only");
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 1, behind: 0, reason: "local-branch-ahead", status: "blocked" });
		expect(result.json.commands_suggested.join("\n")).toContain("log --oneline");
	});

	test("clean diverged main regression blocks with ahead 8 behind 9", () => {
		if (!fixture) throw new Error("fixture missing");
		for (let i = 1; i <= 8; i += 1) commitFile(fixture.clone, `local-${i}.txt`, `local ${i}\n`, `local ${i}`);
		for (let i = 1; i <= 9; i += 1) pushSeed(`remote-${i}.txt`, `remote ${i}\n`, `remote ${i}`);
		const result = runSync();
		expect(result.status).toBe(0);
		expect(result.json.status).toBe("blocked");
		expect(result.json.reason).toBe("local-branch-diverged");
		expect(result.json.ahead).toBe(8);
		expect(result.json.behind).toBe(9);
		expect(result.json.dirty_paths).toEqual([]);
		expect(rev(fixture.clone, "main")).not.toBe(rev(fixture.clone, "origin/main"));
	});

	test("worktree enumeration failure fails closed before update-ref", () => {
		if (!fixture) throw new Error("fixture missing");
		git(fixture.clone, ["switch", "-q", "-c", "feature"]);
		const before = rev(fixture.clone, "main");
		pushSeed("remote.txt", "remote\n", "remote update");
		const result = runSync(failWorktreeListShim());
		expect(result.status).toBe(1);
		expect(result.json.status).toBe("failed");
		expect(result.json.reason).toContain("git-worktree-list-failed");
		expect(result.json.reason).toContain("exit 45");
		expect(result.json.reason).toContain("worktree list exploded");
		expect(result.json.diagnostics?.[0]).toMatchObject({ exit_status: 45, stderr: "worktree list exploded" });
		expect(result.json.diagnostics?.[0]?.command).toContain("worktree list --porcelain");
		expect(rev(fixture.clone, "main")).toBe(before);
		expect(rev(fixture.clone, "main")).not.toBe(rev(fixture.clone, "origin/main"));
	});
});
