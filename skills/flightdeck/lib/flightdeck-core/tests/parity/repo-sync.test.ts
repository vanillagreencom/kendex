import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

function git(cwd: string, args: string[]): string {
	const r = sh("git", ["-C", cwd, ...args]);
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
	if (!fixture) throw new Error("fixture missing");
	const env = { ...GIT_ENV, ...extraEnv };
	const r = sh(SCRIPT, ["main", "--project-root", fixture.clone, "--remote", "origin", "--branch", "main", "--json"], { env });
	const json = JSON.parse(r.stdout) as SyncResult;
	return { ...r, json };
}

function rev(repo: string, ref: string): string {
	return git(repo, ["rev-parse", ref]);
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
		const result = runSync({ FLIGHTDECK_ACTIVITY_FILE: activityFile });
		expect(result.status).toBe(0);
		expect(result.json).toMatchObject({ ahead: 0, behind: 0, reason: "already-synced", status: "already-synced" });
		expect(result.json.dirty_paths).toEqual([]);
		const [row] = readFileSync(activityFile, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
		expect(row).toMatchObject({ severity: "success", source: "workflow", type: "repo.main_synced" });
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
		expect(result.json.commands_suggested.join("\n")).toContain("git -C");
		expect(rev(fixture.clone, "main")).toBe(before);
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
});
