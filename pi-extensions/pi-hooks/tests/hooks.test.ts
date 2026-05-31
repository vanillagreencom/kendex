import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import piHooks from "../extensions/hooks.ts";

const CONFIG_ID = "@vanillagreen/pi-hooks";

type ToolCallHandler = (event: { toolName: string; input: Record<string, unknown> }, ctx: Record<string, unknown>) => Promise<unknown>;

function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

function writePiConfig(project: string): void {
	mkdirSync(join(project, ".pi"), { recursive: true });
	writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
		vstack: {
			extensionManager: {
				config: {
					[CONFIG_ID]: {
						enabled: true,
						preCommitCheck: true,
						postEditLint: false,
						taskCompletedCheck: false,
						clippyTimeoutMs: 3000,
					},
				},
			},
		},
	}, null, 2));
}

function initRustRepo(prefix: string): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	runGit(["init", "-q"], dir);
	writePiConfig(dir);
	mkdirSync(join(dir, "src"), { recursive: true });
	writeFileSync(join(dir, "src", "lib.rs"), "pub fn answer() -> i32 { 42 }\n");
	runGit(["add", "src/lib.rs"], dir);
	return dir;
}

function initCleanRustRepo(prefix: string): string {
	const dir = initRustRepo(prefix);
	runGit(["-c", "user.email=pi-hooks@example.com", "-c", "user.name=pi-hooks", "commit", "-q", "-m", "init"], dir);
	return dir;
}

function fakeCargoBin(root: string): { bin: string; log: string } {
	const bin = join(root, "bin");
	mkdirSync(bin, { recursive: true });
	const log = join(root, "cargo.log");
	const cargo = join(bin, "cargo");
	writeFileSync(cargo, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CARGO_LOG"
case "\${1:-}" in
  metadata)
    if [ "\${FAKE_METADATA_EXIT:-0}" != "0" ]; then
      echo metadata failed >&2
      exit "\${FAKE_METADATA_EXIT:-1}"
    fi
    printf '{"workspace_root":"%s"}\n' "$PWD"
    exit 0
    ;;
  fmt)
    exit "\${FAKE_FMT_EXIT:-0}"
    ;;
  clippy)
    exit "\${FAKE_CLIPPY_EXIT:-0}"
    ;;
  *)
    exit 0
    ;;
esac
`);
	chmodSync(cargo, 0o755);
	return { bin, log };
}

function installToolCallHandler(): ToolCallHandler {
	let handler: ToolCallHandler | undefined;
	const pi = {
		on(event: string, cb: ToolCallHandler) {
			if (event === "tool_call") handler = cb;
		},
	};
	piHooks(pi as never);
	if (!handler) throw new Error("tool_call handler was not registered");
	return handler;
}

async function withFakeCargo<T>(run: (paths: { bin: string; log: string }) => Promise<T>): Promise<T> {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-cargo-"));
	const paths = fakeCargoBin(root);
	const oldPath = process.env.PATH;
	const oldLog = process.env.FAKE_CARGO_LOG;
	const oldMetadata = process.env.FAKE_METADATA_EXIT;
	const oldFmt = process.env.FAKE_FMT_EXIT;
	const oldClippy = process.env.FAKE_CLIPPY_EXIT;
	process.env.PATH = `${paths.bin}:${oldPath ?? ""}`;
	process.env.FAKE_CARGO_LOG = paths.log;
	try {
		return await run(paths);
	} finally {
		if (oldPath === undefined) delete process.env.PATH;
		else process.env.PATH = oldPath;
		if (oldLog === undefined) delete process.env.FAKE_CARGO_LOG;
		else process.env.FAKE_CARGO_LOG = oldLog;
		if (oldMetadata === undefined) delete process.env.FAKE_METADATA_EXIT;
		else process.env.FAKE_METADATA_EXIT = oldMetadata;
		if (oldFmt === undefined) delete process.env.FAKE_FMT_EXIT;
		else process.env.FAKE_FMT_EXIT = oldFmt;
		if (oldClippy === undefined) delete process.env.FAKE_CLIPPY_EXIT;
		else process.env.FAKE_CLIPPY_EXIT = oldClippy;
		rmSync(root, { recursive: true, force: true });
	}
}

describe("pi-hooks pre-commit tool_call", () => {
	test("blocks when async cargo fmt fails", async () => {
		await withFakeCargo(async () => {
			const project = initRustRepo("pi-hooks-project-");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "git commit -m test" } }, { cwd: project });
				expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("blocks when async cargo clippy fails", async () => {
		await withFakeCargo(async () => {
			const project = initRustRepo("pi-hooks-project-");
			process.env.FAKE_CLIPPY_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "git commit -m test" } }, { cwd: project });
				expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo clippy found warnings. Fix them before committing." });
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("blocks metadata probe failures after Rust changes", async () => {
		await withFakeCargo(async () => {
			const project = initRustRepo("pi-hooks-project-");
			process.env.FAKE_METADATA_EXIT = "2";
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "git commit -m test" } }, { cwd: project }) as { block?: boolean; reason?: string };
				expect(result.block).toBe(true);
				expect(result.reason).toContain("found Rust files but could not identify a Cargo workspace");
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("checks untracked Rust files staged by the same bash command", async () => {
		await withFakeCargo(async () => {
			const project = initCleanRustRepo("pi-hooks-project-");
			writeFileSync(join(project, "src", "new.rs"), "pub fn new_answer() -> i32 { 7 }\n");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				runGit(["config", "alias.a", "add"], project);
				const handler = installToolCallHandler();
				for (const command of [
					"git add src/new.rs\ngit commit -m test",
					"git -c alias.a=add a src/new.rs && git commit -m test",
					"git a src/new.rs && git commit -m test",
					"git${IFS}add src/new.rs && git commit -m test",
					"git${IFS} add src/new.rs && git commit -m test",
					"$(echo git) add src/new.rs && git commit -m test",
					"$(printf 'git add') src/new.rs && git commit -m test",
					"`echo git` add src/new.rs && git commit -m test",
					"G=git; ${G} add src/new.rs && git commit -m test",
				]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project });
					expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
				}
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("checks env split-string wrapped git commits", async () => {
		await withFakeCargo(async () => {
			const project = initRustRepo("pi-hooks-project-");
			const other = mkdtempSync(join(tmpdir(), "pi-hooks-other-"));
			runGit(["init", "-q"], other);
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				for (const command of [
					"env -S 'git commit -m test'",
					"env -S'git commit -m test'",
					"env -iS'git commit -m test'",
					"env -S 'bash -c \"git commit -m test\"'",
					"/usr/bin/env -S 'git commit -m test'",
					"env -S 'git -C . commit -m test'",
					"env --split-string 'git commit -m test'",
					"env --split-string='git commit -m test'",
					`env GIT_WORK_TREE=${JSON.stringify(project)} -S "git --git-dir=${join(other, ".git")} commit -m test"`,
				]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project });
					expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
				}
			} finally {
				rmSync(project, { recursive: true, force: true });
				rmSync(other, { recursive: true, force: true });
			}
		});
	});

	test("checks later shell-c project commit after parsed outside commit", async () => {
		await withFakeCargo(async () => {
			const project = initRustRepo("pi-hooks-project-");
			const other = mkdtempSync(join(tmpdir(), "pi-hooks-other-"));
			runGit(["init", "-q"], other);
			process.env.FAKE_FMT_EXIT = "1";
			try {
				runGit(["config", "alias.ca", "commit -a"], project);
				runGit(["config", "alias.co", "-c user.name=pi-hooks commit"], project);
				runGit(["config", "alias.sh", "!git commit"], project);
				const handler = installToolCallHandler();
				for (const command of [
					`git -C ${JSON.stringify(other)} commit -m fixture; bash -c "git commit -m project"`,
					`git -C ${JSON.stringify(other)} commit -m fixture; bash -lc "git commit -m project"`,
					`bash -o pipefail -c "git commit -m project"`,
					`bash +o pipefail -c "git commit -m project"`,
					`bash -c $'git commit -m project'`,
					`bash -c 'git "$@"' _ commit -m project`,
					`bash -c 'git ${"${@}"}' _ commit -m project`,
					`bash -c 'git ${"${1}"} -m project' _ commit`,
					`/usr/bin/git commit -m project`,
					`command /usr/bin/git commit -m project`,
					`git -c alias.ci=commit ci -m project`,
					`git -c ALIAS.upper=commit upper -m project`,
					`git -c alias.zzz=commit ZZZ -m project`,
					`git -c 'alias.ci=commit -m project' ci`,
					`ALIAS=commit git --config-env=alias.ce=ALIAS ce -m project`,
					`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.zzz276 GIT_CONFIG_VALUE_0=commit git zzz276 -am project`,
					`git config alias.zzz276 commit; git zzz276 -am project`,
					`git config --file .git/config alias.zzz277 commit; git zzz277 -am project`,
					`shopt -s expand_aliases; alias g=git; g commit -am project`,
					`shopt -s expand_aliases\nalias gc="git commit"\ngc -am project`,
					`eval "git commit -am project"`,
					`eval 'git \`echo commit\` -am project'`,
					`eval 'git "$(echo commit)" -am project'`,
					`bash <<<"git commit -am project"`,
					`bash -c -- 'git commit -am project'`,
					`bash -c '$1 commit -am project' _ git`,
					`cmd=git bash -c '$cmd commit -am project'`,
					`bash -c '${"${G:-git}"} commit -am project'`,
					`bash -c 'git $(echo commit) -am project'`,
					`bash -c $'shopt -s expand_aliases\nalias g=git\ng commit -am project'`,
					`printf 'git commit -am project\\n' | bash`,
					`git ca -m project`,
					`git co -m project`,
					`git sh -m project`,
					`git $'commit' -m project`,
					`git $'co\\x6dmit' -m project`,
					`git $'co\\155mit' -m project`,
					`git -C ${JSON.stringify(other)} commit -m fixture; git --exec-path ${JSON.stringify("/usr/lib/git-core")} commit -m project`,
				]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project });
					expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
				}
				for (const command of [
					`cmd=git; $cmd commit -am project`,
					`G=git; ${"${G}"} commit -am project`,
					`${"${G:-git}"} commit -am project`,
					`${"${G:-git}"} ${"${C:-commit}"} -am project`,
					`$(echo git) commit -am project`,
					`$(printf 'git commit') -am project`,
					`$(echo git)${"${IFS}"}commit -am project`,
					`\`echo git\` commit -am project`,
					`v=commit; git${"${IFS}"}$v -am project`,
					`git${"${IFS}"}commit -am project`,
					`git${"${IFS}"} commit -am project`,
					`x=zz; ALIAS=commit git --config-env=alias.$x=ALIAS zz -m project`,
					`n=1; GIT_CONFIG_COUNT=$n GIT_CONFIG_KEY_0=alias.zzz276 GIT_CONFIG_VALUE_0=commit git zzz276 -am project`,
					`CFG=alias.zzz276=commit; git -c $CFG zzz276 -am project`,
					`git config ${"${K:-alias.zzz276}"} commit; git zzz276 -am project`,
					`GIT_CONFIG_GLOBAL=/tmp/pi-hooks-aliases git zzz276 -am project`,
					`HOME=$h git zzz276 -am project`,
					`export GIT_CONFIG_GLOBAL=/tmp/pi-hooks-aliases; git zzz276 -am project`,
					`git -c include.path=/tmp/pi-hooks-aliases zzz276 -am project`,
					`git -c includeIf.gitdir:${project}/.git.path=/tmp/pi-hooks-aliases zzz276 -am project`,
				]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project }) as { block?: boolean } | undefined;
					expect(result?.block).toBe(true);
				}
			} finally {
				rmSync(project, { recursive: true, force: true });
				rmSync(other, { recursive: true, force: true });
			}
		});
	});

	test("checks untracked Rust files staged inside env split-string", async () => {
		await withFakeCargo(async () => {
			const project = initCleanRustRepo("pi-hooks-project-");
			writeFileSync(join(project, "src", "split_new.rs"), "pub fn split_new() -> i32 { 9 }\n");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				for (const command of [
					"env -S 'git add src/split_new.rs && git commit -m test'",
					"env --split-string 'git add src/split_new.rs && git commit -m test'",
					"env --split-string='git add src/split_new.rs && git commit -m test'",
				]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project });
					expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
				}
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("checks untracked Rust files staged inside shell -c fallback", async () => {
		await withFakeCargo(async () => {
			const project = initCleanRustRepo("pi-hooks-project-");
			writeFileSync(join(project, "src", "shell_new.rs"), "pub fn shell_new() -> i32 { 11 }\n");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "sh -c 'git add src/shell_new.rs && git commit -m test'" } }, { cwd: project });
				expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("checks same-command untracked Rust from nested cwd", async () => {
		await withFakeCargo(async () => {
			const project = initCleanRustRepo("pi-hooks-project-");
			const nested = join(project, "nested");
			mkdirSync(nested);
			writeFileSync(join(project, "src", "nested_new.rs"), "pub fn nested_new() -> i32 { 13 }\n");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: "git add ../src/nested_new.rs && git commit -m test" } }, { cwd: nested });
				expect(result).toEqual({ block: true, reason: "pi-hooks pre-commit: cargo fmt --check failed. Run `cargo fmt` first." });
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("allows non-executed git commit text without running cargo", async () => {
		await withFakeCargo(async ({ log }) => {
			const project = initRustRepo("pi-hooks-project-");
			process.env.FAKE_FMT_EXIT = "1";
			try {
				const handler = installToolCallHandler();
				for (const command of ["echo git commit", "# git commit", "printf 'git commit'"]) {
					const result = await handler({ toolName: "bash", input: { command } }, { cwd: project });
					expect(result).toBeUndefined();
				}
				expect(readFileSync(log, { encoding: "utf8", flag: "a+" })).toBe("");
			} finally {
				rmSync(project, { recursive: true, force: true });
			}
		});
	});

	test("allows other-repo commits without running cargo", async () => {
		await withFakeCargo(async ({ log }) => {
			const project = initRustRepo("pi-hooks-project-");
			const other = mkdtempSync(join(tmpdir(), "pi-hooks-other-"));
			runGit(["init", "-q"], other);
			try {
				const handler = installToolCallHandler();
				const result = await handler({ toolName: "bash", input: { command: `git -C ${JSON.stringify(other)} commit -m fixture` } }, { cwd: project });
				expect(result).toBeUndefined();
				expect(readFileSync(log, { encoding: "utf8", flag: "a+" })).toBe("");
			} finally {
				rmSync(project, { recursive: true, force: true });
				rmSync(other, { recursive: true, force: true });
			}
		});
	});
});
