import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

import { gitCommitTargets, projectGitCommitCwd } from "../extensions/bash-guards.ts";

function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

function initRepo(prefix: string): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	runGit(["init", "-q"], dir);
	return dir;
}

function q(path: string): string {
	return JSON.stringify(path);
}

describe("git commit target detection", () => {
	test("detects commits in the current project repo", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd("git commit -m test", project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("detects git -C commits inside the project repo", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			const subdir = join(project, "nested");
			mkdirSync(subdir);
			expect(await projectGitCommitCwd(`git -C ${q(subdir)} commit -m test`, project, 1000)).toBe(resolve(subdir));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("skips git -C commits targeting another repo", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		try {
			expect(await projectGitCommitCwd(`git -C ${q(other)} commit -m base`, project, 1000)).toBeNull();
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("skips commands that cd into another repo before committing", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		try {
			expect(await projectGitCommitCwd(`cd ${q(other)} && git commit -m base`, project, 1000)).toBeNull();
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("skips dynamic -C targets that cannot be proven to be the project", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			const command = 'seed=$(mktemp -d); git -C "$seed" commit -m base';
			expect(gitCommitTargets(command, project)).toEqual([
				{ cwd: null, hasGitDir: false, gitDir: null, hasWorkTree: false, workTree: null },
			]);
			expect(await projectGitCommitCwd(command, project, 1000)).toBeNull();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("skips explicit --git-dir outside the project", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		try {
			expect(await projectGitCommitCwd(`git --git-dir=${q(join(other, ".git"))} commit -m base`, project, 1000)).toBeNull();
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});
});
