import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

import { gitCommitTargets, projectGitCommitCwd, resolveProjectGitCommit } from "../extensions/bash-guards.ts";

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

	test("detects multiline git commit commands", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd("git add src/lib.rs\ngit commit -m test", project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("detects env and command wrappers", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd("env FOO=bar git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -u FOO git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -S 'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -S'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -iS'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -S 'bash -c \"git commit -m test\"'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("/usr/bin/env -S 'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env -S 'git -C . commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env --split-string 'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env --split-string='git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("command git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git -c alias.ci=commit ci -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git -c ALIAS.upper=commit upper -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git -c alias.zzz=commit ZZZ -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git -c 'alias.ci=commit -m test' ci", project, 1000)).toBe(resolve(project));
			runGit(["config", "alias.ci", "commit"], project);
			runGit(["config", "alias.ca", "commit -a"], project);
			runGit(["config", "alias.co", "-c user.name=pi-hooks commit"], project);
			runGit(["config", "alias.sh", "!git commit"], project);
			expect(await projectGitCommitCwd("git ci -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git ca -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git co -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git sh -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("ALIAS=commit git --config-env=alias.ce=ALIAS ce -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("env ALIAS=commit git --config-env=alias.ee=ALIAS ee -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.zzz276 GIT_CONFIG_VALUE_0=commit git zzz276 -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git config alias.zzz276 commit; git zzz276 -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git config --file .git/config alias.zzz277 commit; git zzz277 -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("shopt -s expand_aliases; alias g=git; g commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("shopt -s expand_aliases\nalias gc=\"git commit\"\ngc -m test", project, 1000)).toBe(resolve(project));
			expect((await resolveProjectGitCommit("cmd=git; $cmd commit -m test", project, 1000)).kind).toBe("error");
			expect(await projectGitCommitCwd("G=git; ${G} commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("${G:-git} commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("${G:-git} ${C:-commit} -m test", project, 1000)).toBe(resolve(project));
			expect((await resolveProjectGitCommit("$(echo git) commit -m test", project, 1000)).kind).toBe("error");
			expect((await resolveProjectGitCommit("$(printf 'git commit') -m test", project, 1000)).kind).toBe("error");
			expect(await projectGitCommitCwd("$(echo git)${IFS}commit -m test", project, 1000)).toBe(resolve(project));
			expect((await resolveProjectGitCommit("`echo git` commit -m test", project, 1000)).kind).toBe("error");
			expect(await projectGitCommitCwd("v=commit; git${IFS}$v -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git${IFS}commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git${IFS} commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("eval \"git commit -m test\"", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("eval 'git `echo commit` -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("eval 'git \"$(echo commit)\" -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash <<<\"git commit -m test\"", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash -c -- 'git commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash -c '$1 commit -m test' _ git", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("cmd=git bash -c '$cmd commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash -c '${G:-git} commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash -c 'git $(echo commit) -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("bash -c $'shopt -s expand_aliases\nalias g=git\ng commit -m test'", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("printf 'git commit -m test\\n' | bash", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git $'commit' -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git $'co\\x6dmit' -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("git $'co\\155mit' -m test", project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("handles long env and shell wrapper inputs without regex backtracking", async () => {
		const project = initRepo("pi-hooks-project-");
		const spaces = " ".repeat(1000);
		try {
			expect(await projectGitCommitCwd(`env -S 'git${spaces}commit -m test'`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`sh -c "git${spaces}commit -m test"`, project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("does not let env assignments override shell variables used by git -C", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd("repo=.; env repo=$(mktemp -d) git -C $repo commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("GIT_DIR=/tmp /bin/true; git commit -m test", project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("detects control-flow and scoped project commits", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd("if true; then git commit -m test; fi", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("! git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("{ git commit -m test; }", project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("detects commits after failed or scoped cd forms as project commits", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		const noExec = join(project, "noexec");
		try {
			mkdirSync(noExec);
			chmodSync(noExec, 0o000);
			expect(await projectGitCommitCwd(`(cd ${q(other)} && true); git commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`(cd ${q(other)} && git commit -m other); git commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("cd /path/that/does/not/exist; git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("cd /path/that/does/not/exist || git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("cd /path/that/does/not/exist && true; git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("false && cd /tmp; git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd("if false; then cd /tmp; fi; git commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`cd ${q(noExec)}; git commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`true | cd ${q(other)}; git commit -m test`, project, 1000)).toBe(resolve(project));
		} finally {
			chmodSync(noExec, 0o700);
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("treats project git-dir with external cwd/work-tree as project commit", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		try {
			expect(await projectGitCommitCwd(`git --git-dir=${q(join(project, ".git"))} --work-tree=${q(other)} commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`git --git-dir=${q(join(other, ".git"))} --work-tree=${q(project)} commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`GIT_DIR=${q(join(project, ".git"))} git -C ${q(other)} commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`GIT_DIR=${q(join(other, ".git"))} GIT_WORK_TREE=${q(project)} git commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`export GIT_WORK_TREE=${q(project)}; git --git-dir=${q(join(other, ".git"))} commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`env GIT_WORK_TREE=${q(project)} -S "git --git-dir=${join(other, ".git")} commit -m test"`, project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("treats linked worktree git-dir as active project commit", async () => {
		const main = initRepo("pi-hooks-main-");
		const parent = mkdtempSync(join(tmpdir(), "pi-hooks-worktree-parent-"));
		const worktree = join(parent, "wt");
		try {
			writeFileSync(join(main, "README.md"), "init\n");
			runGit(["add", "README.md"], main);
			runGit(["-c", "user.email=pi-hooks@example.com", "-c", "user.name=pi-hooks", "commit", "-q", "-m", "init"], main);
			runGit(["worktree", "add", "-q", worktree, "HEAD"], main);
			const gitDir = readFileSync(join(worktree, ".git"), "utf8").trim().replace(/^gitdir:\s*/, "");
			expect(await projectGitCommitCwd(`git --git-dir=${q(gitDir)} commit -m test`, worktree, 1000)).toBe(resolve(worktree));
		} finally {
			rmSync(main, { recursive: true, force: true });
			rmSync(parent, { recursive: true, force: true });
		}
	});

	test("falls back to project commit when later shell-c commit is not parsed", async () => {
		const project = initRepo("pi-hooks-project-");
		const other = initRepo("pi-hooks-other-");
		try {
			expect(await projectGitCommitCwd(`git -C ${q(other)} commit -m fixture; bash -c "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`git -C ${q(other)} commit -m fixture; bash -lc "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash -o pipefail -c "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash +o pipefail -c "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash -c $'git commit -m project'`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash -c 'git "$@"' _ commit -m project`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash -c 'git ${"${@}"}' _ commit -m project`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`bash -c 'git ${"${1}"} -m project' _ commit`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`zsh -fc "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`/bin/bash -c "git commit -m project"`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`/usr/bin/git commit -m project`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`command /usr/bin/git commit -m project`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`git -C ${q(other)} commit -m fixture; git --exec-path ${q("/usr/lib/git-core")} commit -m project`, project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(other, { recursive: true, force: true });
		}
	});

	test("detects canonical project paths that look outside lexically", async () => {
		const project = initRepo("pi-hooks-project-");
		const parent = mkdtempSync(join(tmpdir(), "pi-hooks-links-"));
		const link = join(parent, "project-link");
		const otherWorkTree = join(parent, "other-work-tree");
		try {
			symlinkSync(project, link, "dir");
			mkdirSync(otherWorkTree);
			expect(await projectGitCommitCwd("git -C /proc/self/cwd commit -m test", project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`git -C ${q(link)} commit -m test`, project, 1000)).toBe(resolve(link));
			expect(await projectGitCommitCwd(`git --git-dir=${q(join(link, ".git"))} commit -m test`, project, 1000)).toBe(resolve(project));
			expect(await projectGitCommitCwd(`git --work-tree=${q(otherWorkTree)} commit -m test`, project, 1000)).toBe(resolve(project));
		} finally {
			rmSync(project, { recursive: true, force: true });
			rmSync(parent, { recursive: true, force: true });
		}
	});

	test("detects backslash-newline wrapped git commits", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			expect(await projectGitCommitCwd(`git add src/lib.rs && \\
git commit -m test`, project, 1000)).toBe(resolve(project));
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

	test("skips mktemp -C targets that are provably outside the project", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			const command = 'seed=$(mktemp -d); git -C "$seed" commit -m base';
			expect(gitCommitTargets(command, project)).toEqual([
				expect.objectContaining({ cwd: null, external: true, unknown: false, hasGitDir: false, gitDir: null, hasWorkTree: false, workTree: null }),
			]);
			expect(await projectGitCommitCwd(command, project, 1000)).toBeNull();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("blocks unresolved dynamic targets instead of silently skipping", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			const result = await resolveProjectGitCommit('git -C "$repo" commit -m base', project, 1000);
			expect(result.kind).toBe("error");
			const dynamicSubcommand = await resolveProjectGitCommit('git "$cmd" -m base', project, 1000);
			expect(dynamicSubcommand.kind).toBe("error");
			const dynamicAlias = await resolveProjectGitCommit("x=zz; ALIAS=commit git --config-env=alias.$x=ALIAS zz -m base", project, 1000);
			expect(dynamicAlias.kind).toBe("error");
			expect(await projectGitCommitCwd("CFG=alias.zzz=commit; git -c $CFG zzz -m base", project, 1000)).toBe(resolve(project));
			const dynamicConfigKey = await resolveProjectGitCommit("git config ${K:-alias.zzz} commit; git zzz -m base", project, 1000);
			expect(dynamicConfigKey.kind).toBe("error");
			const includeAlias = await resolveProjectGitCommit("git -c include.path=/tmp/aliases zzz276 -m base", project, 1000);
			expect(includeAlias.kind).toBe("error");
			const includeIfAlias = await resolveProjectGitCommit(`git -c includeIf.gitdir:${project}/.git.path=/tmp/aliases zzz276 -m base`, project, 1000);
			expect(includeIfAlias.kind).toBe("error");
			const globalAlias = await resolveProjectGitCommit("GIT_CONFIG_GLOBAL=/tmp/aliases git zzz276 -m base", project, 1000);
			expect(globalAlias.kind).toBe("error");
			const exportedGlobalAlias = await resolveProjectGitCommit("export GIT_CONFIG_GLOBAL=/tmp/aliases; git zzz276 -m base", project, 1000);
			expect(exportedGlobalAlias.kind).toBe("error");
			const dynamicHomeAlias = await resolveProjectGitCommit("HOME=$h git zzz276 -m base", project, 1000);
			expect(dynamicHomeAlias.kind).toBe("error");
			const dynamicCount = await resolveProjectGitCommit("n=1; GIT_CONFIG_COUNT=$n GIT_CONFIG_KEY_0=alias.zzz GIT_CONFIG_VALUE_0=commit git zzz -m base", project, 1000);
			expect(dynamicCount.kind).toBe("error");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("skips non-executed git commit text", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			for (const command of ["echo git commit", "# git commit", "printf 'git commit'", "cat <<<'git commit'"]) {
				const result = await resolveProjectGitCommit(command, project, 1000);
				expect(result).toEqual({ kind: "skip", reason: "no-git-commit" });
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("does not leak one-shot git config prefix assignments", async () => {
		const project = initRepo("pi-hooks-project-");
		try {
			for (const command of [
				"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.zzz GIT_CONFIG_VALUE_0=commit /bin/true; git zzz -m base",
				"GIT_CONFIG_GLOBAL=/tmp/aliases /bin/true; git zzz276 -m base",
			]) {
				expect(await projectGitCommitCwd(command, project, 1000)).toBeNull();
			}
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
