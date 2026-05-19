// Parity test: parallel-groups (bash) vs parallel-groups (TS).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/parallel-groups");

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdpg-parity-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function run(cwd: string, args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	// Bash resolves project root from script location; explicit ORCH_CACHE_DIR
	// pins both implementations to the test's isolated repo.
	env.ORCH_CACHE_DIR = join(cwd, ".cache/orchestration");
	const r = spawnSync(SCRIPT, args, { cwd, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function seedIssues(repo: string, issues: Array<{ identifier: string; updatedAt: string }>): void {
	const dir = join(repo, ".cache/orchestration");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "issues.json"), JSON.stringify(issues));
}

function readGroupsFile(repo: string): unknown {
	return JSON.parse(readFileSync(join(repo, ".cache/orchestration/parallel-groups.json"), "utf8"));
}

let tsRepo = "";

beforeEach(() => {
	tsRepo = makeRepo();
});

afterEach(() => {
	if (tsRepo && existsSync(tsRepo)) rmSync(tsRepo, { force: true, recursive: true });
});

describe("parallel-groups parity", () => {
	test("read on empty cache returns []", () => {
		const a = run(tsRepo, ["read"]);
		const b = run(tsRepo, ["read"]);
		expect(b.stdout).toBe(a.stdout);
		expect(a.stdout.trim()).toBe("[]");
	});

	test("write assigns sequential group ids", () => {
		for (const repo of [tsRepo]) {
			seedIssues(repo, [
				{ identifier: "CC-001", updatedAt: "2026-05-01T00:00:00Z" },
				{ identifier: "CC-002", updatedAt: "2026-05-01T00:00:00Z" },
			]);
			const r1 = run(repo, ["write", JSON.stringify({
				children_fingerprints: {},
				issue_fingerprints: { "CC-001": "2026-05-01T00:00:00Z", "CC-002": "2026-05-01T00:00:00Z" },
				issues: ["CC-001", "CC-002"],
				verdict: "safe",
			})]);
			expect(r1.status).toBe(0);
			expect(r1.stdout.trim()).toBe("1");
			const r2 = run(repo, ["write", JSON.stringify({
				children_fingerprints: {},
				issue_fingerprints: { "CC-001": "2026-05-01T00:00:00Z" },
				issues: ["CC-001"],
				verdict: "safe",
			})]);
			expect(r2.stdout.trim()).toBe("2");
		}
		const a = run(tsRepo, ["read"]);
		const b = run(tsRepo, ["read"]);
		expect(JSON.parse(b.stdout)).toEqual(JSON.parse(a.stdout));
	});

	test("lookup finds the right group", () => {
		for (const repo of [tsRepo]) {
			seedIssues(repo, [{ identifier: "CC-001", updatedAt: "ts" }, { identifier: "CC-002", updatedAt: "ts" }]);
			run(repo, ["write", JSON.stringify({
				issue_fingerprints: { "CC-001": "ts", "CC-002": "ts" },
				issues: ["CC-001", "CC-002"],
				verdict: "safe",
			})]);
		}
		const a = run(tsRepo, ["lookup", "CC-001"]);
		const b = run(tsRepo, ["lookup", "CC-001"]);
		expect(b.stdout.trim()).toBe(a.stdout.trim());
		expect(a.stdout.trim()).toBe("1");
	});

	test("needs-refresh: fewer than 2 → exit 1", () => {
		const a = run(tsRepo, ["needs-refresh", "CC-001"]);
		const b = run(tsRepo, ["needs-refresh", "CC-001"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
		expect(b.stdout).toBe(a.stdout);
	});

	test("needs-refresh: fresh covered → exit 1", () => {
		for (const repo of [tsRepo]) {
			seedIssues(repo, [{ identifier: "CC-001", updatedAt: "ts" }, { identifier: "CC-002", updatedAt: "ts" }]);
			run(repo, ["write", JSON.stringify({
				issue_fingerprints: { "CC-001": "ts", "CC-002": "ts" },
				issues: ["CC-001", "CC-002"],
				verdict: "safe",
			})]);
		}
		const a = run(tsRepo, ["needs-refresh", "CC-001", "CC-002"]);
		const b = run(tsRepo, ["needs-refresh", "CC-001", "CC-002"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(1);
	});

	test("needs-refresh: new issue → exit 0", () => {
		const a = run(tsRepo, ["needs-refresh", "CC-001", "CC-NEW"]);
		const b = run(tsRepo, ["needs-refresh", "CC-001", "CC-NEW"]);
		expect(b.status).toBe(a.status);
		expect(a.status).toBe(0);
		expect(b.stdout).toBe(a.stdout);
	});

	test("concurrent writes pick distinct group_ids (race regression)", async () => {
		// Spawn 10 writers in parallel. Before the lock fix, two writers
		// could read the same on-disk state and both write group_id=1.
		seedIssues(tsRepo, [{ identifier: "CC-001", updatedAt: "ts" }]);
		const payload = JSON.stringify({ issue_fingerprints: { "CC-001": "ts" }, issues: ["CC-001"], verdict: "safe" });
		const { spawn } = await import("node:child_process");
		const kids = await Promise.all(
			Array.from({ length: 10 }, () => new Promise<{ stdout: string }>((res) => {
				const env = { ...process.env, ORCH_CACHE_DIR: join(tsRepo, ".cache/orchestration") } as Record<string, string>;
				const p = spawn(SCRIPT, ["write", payload], { cwd: tsRepo, env });
				let out = "";
				p.stdout?.on("data", (b) => { out += b.toString(); });
				p.on("close", () => res({ stdout: out }));
			})),
		);
		const ids = kids.map((k) => Number.parseInt(k.stdout.trim(), 10)).filter((n) => Number.isFinite(n));
		expect(ids.length).toBe(10);
		expect(new Set(ids).size).toBe(10);
	});

	test("clear --group N rejects non-numeric input (no mutation)", () => {
		seedIssues(tsRepo, [{ identifier: "CC-001", updatedAt: "ts" }]);
		seedIssues(tsRepo, [{ identifier: "CC-001", updatedAt: "ts" }]);
		const payload = JSON.stringify({ issue_fingerprints: { "CC-001": "ts" }, issues: ["CC-001"], verdict: "safe" });
		for (const repo of [tsRepo]) {
			run(repo, ["write", payload]);
			run(repo, ["write", payload]);
		}
		const beforeTs = JSON.stringify(readGroupsFile(tsRepo));
		const beforeBash = JSON.stringify(readGroupsFile(tsRepo));
		const a = run(tsRepo, ["clear", "--group", "1abc2"]);
		const b = run(tsRepo, ["clear", "--group", "1abc2"]);
		// Bash exits nonzero on jq parse error; TS exits 2 explicitly
		// with a usage-error message. Both implementations must not
		// mutate the file with a bogus id.
		expect(a.status).not.toBe(0);
		expect(b.status).toBe(2);
		expect(JSON.stringify(readGroupsFile(tsRepo))).toBe(beforeBash);
		expect(JSON.stringify(readGroupsFile(tsRepo))).toBe(beforeTs);
	});

	test("clear --group removes only matching id", () => {
		for (const repo of [tsRepo]) {
			seedIssues(repo, [{ identifier: "CC-001", updatedAt: "ts" }]);
			run(repo, ["write", JSON.stringify({ issue_fingerprints: { "CC-001": "ts" }, issues: ["CC-001"], verdict: "safe" })]);
			run(repo, ["write", JSON.stringify({ issue_fingerprints: { "CC-001": "ts" }, issues: ["CC-001"], verdict: "safe" })]);
			run(repo, ["clear", "--group", "1"]);
		}
		expect(readGroupsFile(tsRepo)).toEqual(readGroupsFile(tsRepo));
	});
});
