import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { isBareCd, preCommitGate, scanCommand } from "../extensions/bash-guards.ts";
import { runCommandAsync } from "../extensions/process.ts";

// The marker the growth-guards installer ends its delegating line with, and
// the only thing that makes a hook file ours as far as this gate is
// concerned. Assembled so this file is not itself mistaken for a shim.
const GG_MARK = "# kendex-" + "guards-hook";

function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

// A global init.templateDir can leave git init without a hooks directory,
// so the fixture makes the one it writes into.
function initRepo(root: string, name: string): string {
	const dir = join(root, name);
	mkdirSync(dir, { recursive: true });
	runGit(["init", "-q"], dir);
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
	return dir;
}

// A hook file git would run, carrying the marker; `executable: false` leaves
// the marker in place and takes the bit git needs away.
function writeHook(dir: string, lane: string, executable = true): void {
	const file = join(dir, lane);
	writeFileSync(file, `#!/bin/sh\nexit 0 ${GG_MARK}\n`);
	chmodSync(file, executable ? 0o755 : 0o644);
}

// Every fixture carries a package script that would announce itself if
// anything ran it. Nothing may: this gate defers to an armed hook or refuses,
// and never runs a repository's own scripts on its behalf.
function plantAnnouncingScript(repo: string, log: string): void {
	const scripts = join(repo, ".agents", "skills", "growth-guards", "scripts");
	mkdirSync(scripts, { recursive: true });
	writeFileSync(join(scripts, "pre-commit"), `#!/usr/bin/env bash\necho 'the repository script ran' >>"${log}"\nexit 0\n`);
	chmodSync(join(scripts, "pre-commit"), 0o755);
}

const PROBE = "pi-hooks-path-probe";

/**
 * Prove the narrowed PATH is the one the gate's own spawns resolve against,
 * then take the probe back out so the directory holds git, sh and bash alone.
 * A narrowing that never reaches a child reads exactly like one that holds.
 * That is how a fake cargo sat unreachable while every assertion around it
 * passed (KEN-843), Bun's spawnSync having defaulted to a boot-time
 * environment snapshot. The probe runs through `runCommandAsync` because that
 * is the helper the gate spawns git with, so it answers for the gate's own
 * resolution and not for a lookup this file did itself.
 */
async function expectNarrowedPathReachable(bin: string, cwd: string): Promise<void> {
	const probe = join(bin, PROBE);
	writeFileSync(probe, "#!/bin/sh\nprintf reached\n");
	chmodSync(probe, 0o755);
	const result = await runCommandAsync(PROBE, [], cwd, 5000);
	expect([result.exitCode, result.stdout]).toEqual([0, "reached"]);
	rmSync(probe);
}

describe("pre-commit gate: the bash hook's contract", () => {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-gate-"));
	const ranLog = join(root, "ran.log");
	let unarmed: string;
	let armed: string;
	let armedByPath: string;
	let disarmed: string;
	let disarmedByPath: string;
	let hooksOff: string;
	let halfArmed: string;
	let markedNotExec: string;
	let foreign: string;
	let mixed: string;
	let notARepo: string;
	// Narrowed PATH: git is the one binary this gate resolves, so the fixtures
	// run against a directory holding git, sh and bash and nothing else. A
	// resolution the gate is not supposed to make fails here rather than
	// quietly finding the developer's copy. Git also reads no config of the
	// developer's: a global core.hooksPath would disarm every fixture.
	const savedEnv: Record<string, string | undefined> = {};
	const isolatedEnv: Record<string, string> = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };

	beforeAll(async () => {
		for (const [name, value] of Object.entries(isolatedEnv)) {
			savedEnv[name] = process.env[name];
			process.env[name] = value;
		}

		unarmed = initRepo(root, "unarmed");

		armed = initRepo(root, "armed");
		for (const lane of ["pre-commit", "commit-msg"]) writeHook(join(armed, ".git", "hooks"), lane);

		armedByPath = initRepo(root, "armed-by-path");
		const customHooks = join(root, "custom-hooks");
		mkdirSync(customHooks);
		for (const lane of ["pre-commit", "commit-msg"]) writeHook(customHooks, lane);
		runGit(["config", "core.hooksPath", customHooks], armedByPath);

		// A hook file git will not run: present, execute bit off. Git skips it
		// silently, so it must not count as armed.
		disarmed = initRepo(root, "disarmed");
		writeHook(join(disarmed, ".git", "hooks"), "pre-commit", false);

		disarmedByPath = initRepo(root, "disarmed-by-path");
		const disarmedHooks = join(root, "disarmed-hooks");
		mkdirSync(disarmedHooks);
		writeHook(disarmedHooks, "pre-commit", false);
		runGit(["config", "core.hooksPath", disarmedHooks], disarmedByPath);

		// core.hooksPath set and EMPTY switches hooks off, and git's answer
		// about it misleads: `rev-parse --git-path hooks` reports `./`, so the
		// directory resolves to the repository root. This fixture puts an
		// executable `pre-commit` exactly there, the trap, while git runs
		// nothing at all.
		hooksOff = initRepo(root, "hooks-off");
		runGit(["config", "core.hooksPath", ""], hooksOff);
		writeFileSync(join(hooksOff, "pre-commit"), "#!/bin/sh\nexit 0\n");
		chmodSync(join(hooksOff, "pre-commit"), 0o755);

		// One lane armed and not the other. Deferring here would hand the
		// commit to a gate that checks content and accepts any message.
		halfArmed = initRepo(root, "half-armed");
		writeHook(join(halfArmed, ".git", "hooks"), "pre-commit");

		// Marked on both lanes, and one of them is a file git will not execute.
		markedNotExec = initRepo(root, "marked-not-exec");
		writeHook(join(markedNotExec, ".git", "hooks"), "pre-commit", false);
		writeHook(join(markedNotExec, ".git", "hooks"), "commit-msg");

		// Both lanes executable where git reads them, and neither is ours: a
		// hook somebody else installed is not kendex's arming.
		foreign = initRepo(root, "foreign");
		for (const lane of ["pre-commit", "commit-msg"]) {
			writeFileSync(join(foreign, ".git", "hooks", lane), "#!/bin/sh\nexit 0\n");
			chmodSync(join(foreign, ".git", "hooks", lane), 0o755);
		}

		// Ours on the content lane, somebody else's on the message lane: the
		// marker has to be read on both, not on pre-commit alone.
		mixed = initRepo(root, "mixed");
		writeHook(join(mixed, ".git", "hooks"), "pre-commit");
		writeFileSync(join(mixed, ".git", "hooks", "commit-msg"), "#!/bin/sh\nexit 0\n");
		chmodSync(join(mixed, ".git", "hooks", "commit-msg"), 0o755);

		notARepo = join(root, "plain");
		mkdirSync(notARepo);

		for (const repo of [unarmed, armed, armedByPath, disarmed, disarmedByPath, hooksOff, halfArmed, markedNotExec, foreign, mixed]) {
			plantAnnouncingScript(repo, ranLog);
		}

		const bin = join(root, "git-only-bin");
		mkdirSync(bin);
		for (const tool of ["git", "sh", "bash"]) {
			const found = spawnSync("sh", ["-c", `command -v ${tool}`], { encoding: "utf8" }).stdout.trim();
			if (found) spawnSync("ln", ["-sf", found, join(bin, tool)]);
		}
		savedEnv.PATH = process.env.PATH;
		process.env.PATH = bin;
		await expectNarrowedPathReachable(bin, root);
	});

	afterAll(() => {
		for (const [name, value] of Object.entries(savedEnv)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		rmSync(root, { recursive: true, force: true });
	});

	async function gate(cwd: string, command: string) {
		const verdict = await preCommitGate(command, cwd);
		let ran = "";
		try {
			ran = readFileSync(ranLog, "utf8");
		} catch {
			// Nothing ran, so nothing wrote the log.
		}
		return { verdict, ran };
	}

	// Judge one form in both fixtures. The armed expectation says whether the git
	// argv carries a bypass; the unarmed one is the control proving the commit
	// was found at all, since a form the gate never sees passes there too.
	async function both(command: string, wantArmed: "allow" | "refuse", wantUnarmed: "allow" | "refuse"): Promise<void> {
		const a = await gate(armed, command);
		expect([command, a.verdict.kind]).toEqual([command, wantArmed]);
		if (a.verdict.kind === "refuse") expect(a.verdict.reason).toContain("bypasses this repository's armed git hooks");
		expect(a.ran).toBe("");
		const u = await gate(unarmed, command);
		expect([command, u.verdict.kind]).toEqual([command, wantUnarmed]);
		if (u.verdict.kind === "refuse") expect(u.verdict.reason).toContain("not armed by kendex");
		expect(u.ran).toBe("");
	}

	test("detection reads live words, not the whole command", () => {
		const commit = (c: string): boolean => scanCommand(c).commit;
		expect(commit("ls -la")).toBe(false);
		expect(commit("git commit -m test")).toBe(true);
		expect(commit("git -C /somewhere/else commit -m test")).toBe(true);
		expect(commit("cargo fmt\ngit commit -m x")).toBe(true);
		expect(commit("cargo fmt\r\ngit commit -m x")).toBe(true);
		// A tab is word whitespace, so those are arguments of one `cd` — but they
		// are live words all the same, and the rule reads words rather than an argv.
		expect(commit("cd sub\tgit commit -m x")).toBe(true);
		expect(commit("echo git commit")).toBe(true);
		// Whole words, and the order has to hold: neither of these is a commit.
		expect(commit("git status && echo commit")).toBe(false);
		expect(commit("git log --grep=commit")).toBe(false);
		expect(commit("commit git")).toBe(false);
	});

	test("quoting inside the command word is still the command word", async () => {
		// This gate used to answer from the raw string, where `g''it` carries no
		// `git` at all and the bypass behind it passed an armed repository. The
		// bash hook reads shell here, and so does this one.
		await both("g''it commit --no-verify -m x", "refuse", "refuse");
		await both("g''it commit -m x", "allow", "refuse");
	});

	test("only live words are judged", async () => {
		// The three refusals this rule exists to stop, all of them in one day: a
		// `-n` in a heredoc body, a `-c` belonging to another program, and prose
		// naming --no-verify inside a quoted string.
		for (const command of [
			"cat <<EOF > tmp/note.md\nrun cat -n on the file\nEOF\ngit commit -m note",
			'python3 -c "print(1)" && git commit -m x',
			'git commit -m "explain why --no-verify is banned"',
			'gh pr comment 7 --body "we never pass --no-verify" && git commit -m x',
		]) {
			expect([command, scanCommand(command).bypass]).toEqual([command, null]);
			await both(command, "allow", "refuse");
		}

		// The same forms with the flag moved into the commit's own argv.
		for (const command of [
			"cat <<EOF > tmp/note.md\nrun cat -n on the file\nEOF\ngit commit -n -m note",
			'python3 -c "print(1)" && git commit --no-verify -m x',
			'git commit -m "explain why --no-verify is banned" --no-verify',
			'gh pr comment 7 --body "we never pass --no-verify" && git -c core.hooksPath=/dev/null commit -m x',
		]) {
			await both(command, "refuse", "refuse");
		}
	});

	test("a heredoc body is text, not shell", async () => {
		// A body line beginning with `git` is prose about a commit, not a commit;
		// the body is skipped whole, so no quote in it opens anything either.
		// Without that, one apostrophe swallowed every separator after it and the
		// real commit behind the heredoc went unjudged in both fixtures.
		for (const command of [
			"cat > note.md <<EOF\ngit commit --no-verify is banned in this repo\nEOF\ngit commit -m x",
			'cat <<EOF > n.md\nsay "hi\nEOF\ngit commit -m x',
			"cat <<-EOF > n.md\n\tgit commit -n here\n\tEOF\ngit commit -m x",
			'cat <<"END" > n.md\ngit commit -n here\nEND\ngit commit -m x',
			"git commit -m x <<< ignored",
		]) {
			await both(command, "allow", "refuse");
		}
		await both("cat <<EOF >> notes.md\ndon't forget\nEOF\ngit commit --no-verify -m x", "refuse", "refuse");
	});

	test("a comment is text", async () => {
		await both("git commit -m x  # never --no-verify", "allow", "refuse");
		await both("git commit -m x # -n", "allow", "refuse");
		await both("git commit -m x#y --no-verify", "refuse", "refuse");
	});

	test("a backslash-newline joins lines", async () => {
		// hooks/block-unsafe-rm.sh folds the same sequence before its separator
		// split. Left alone it puts a newline inside the word, and the command
		// after it goes unjudged in both fixtures.
		await both("git status && \\\ngit commit --no-verify -m x", "refuse", "refuse");
		await both("cargo fmt && \\\ngit commit -m x", "allow", "refuse");
		// Joined, the flag is the argv's own; left unjoined it carries a newline
		// and reads as neither flag nor command word.
		await both("git commit -m x \\\n--no-verify", "refuse", "refuse");
	});

	test("a bypass word is a bypass word", async () => {
		// No argv model means no `--` and no option values: a word that reads as the
		// flag is refused wherever it stands. Bizarre forms, and they fail closed.
		await both("git commit -- --no-verify", "refuse", "refuse");
		await both("git commit -m x -- -n", "refuse", "refuse");
		await both("git commit -F --no-verify", "refuse", "refuse");
		await both("git commit -c HEAD --reset-author", "refuse", "refuse");
		await both("git commit -m a{b} --no-verify", "refuse", "refuse");
		await both("{ git commit --no-verify -m x; }", "refuse", "refuse");
	});

	test("a quoted word is a live word", async () => {
		// Quoting sets a word boundary; it does not stop the word existing.
		for (const command of ['git commit "--no-verify" -m x', 'git "commit" --no-verify', '"git" commit --no-verify']) {
			await both(command, "refuse", "refuse");
			const named = await gate(armed, command);
			if (named.verdict.kind !== "refuse") throw new Error("unreachable");
			expect(named.verdict.reason).toContain("'--no-verify' bypasses");
		}
		// And the other half of the rule: a bypass is a word whose WHOLE content is
		// one, so prose that merely names a flag is one long word and not the flag.
		await both('git commit -m "--no-verify should never be used"', "allow", "refuse");
		await both('git commit -m "prose mentioning -n inside"', "allow", "refuse");
		await both('git commit -m "core.hooksPath is not to be touched"', "allow", "refuse");
	});

	test("an escaped quote does not close its run", async () => {
		// A backslash escapes the next character inside a double-quoted or backtick
		// run, so `\\"` is not the close. Read as one, everything through the next
		// quote is swallowed and the live command behind it disappears. The flag is
		// assembled because this repository's own hook refuses a command spelling it.
		const nv = "--no-" + "verify";
		const escaped = `echo "x\\" y" && git commit `;
		const backtick = "echo `x\\` y` && git commit ";
		for (const command of [`${escaped}${nv} -m "x"`, `${backtick}${nv} -m \`x\``]) {
			await both(command, "refuse", "refuse");
			const named = await gate(armed, command);
			if (named.verdict.kind !== "refuse") throw new Error("unreachable");
			expect(named.verdict.reason).toContain(`'${nv}' bypasses`);
		}
		// The control: same shell, no bypass. The unarmed refusal proves the commit
		// was found rather than the armed refusal arriving from swallowed text.
		await both(`${escaped}-m "x"`, "allow", "refuse");
		await both(`${backtick}-m \`x\``, "allow", "refuse");
		// A single-quoted run takes no escapes, so this one closes at the second
		// quote and the commit behind it is live. Honour the backslash there and the
		// whole middle becomes one word, commit and flag with it.
		await both(`echo 'a\\' && git commit ${nv} -m 'x'`, "refuse", "refuse");
		await both("echo 'a\\' && git commit -m 'x'", "allow", "refuse");
	});

	test("a -c word injects configuration whatever its value", async () => {
		await both("git -cinclude.path=/tmp/c commit -m x", "refuse", "refuse");
		const named = await gate(armed, "git -cinclude.path=/tmp/c commit -m x");
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain("'-cinclude.path=/tmp/c' bypasses");
	});

	test("a construct this gate does not model is refused on sight", async () => {
		// Each of these hides text from the scanner, and each decode added to read
		// one invites the next construct. So the construct itself is the answer: a
		// command naming git that carries one is refused in either fixture, without
		// parsing. The refusals name no bypass — nothing was parsed to find one.
		const nv = "--no-" + "verify";
		for (const command of [
			`git -c alias.c='commit ${nv}' c --allow-empty -m x`,
			`git config alias.c 'commit ${nv}' && git c --allow-empty -m x`,
			"cat <<$'EOF'\nbody\nEOF\ngit commit -m x",
			`git commit "--no-veri\\\nfy" -m x`,
			"x=$(( 1 << 2 )) && git commit -m x",
			// The prerequisite is read off the command with its quote characters
			// removed, so a spelling the shell assembles reads as its letters. Each
			// of these is the word once the quotes come out, and one also spells git.
			"git com''mit $'--no-verify' -m x",
			"git $'com''mit' --no-verify -m x",
			"git status && $'g''it' commit --no-verify -m x",
			// The alias key keeps the bare git prerequisite: it defines the commit
			// under another name, so no normalizing brings the word back.
			"git -c alias.c='co' co --allow-empty -m x",
			// Accepted on KEN-866 and pinned so it cannot flip in silence: the
			// pattern supplies the word, and no text test tells it from the
			// subcommand.
			"git log --oneline | grep 'commit$'",
		]) {
			for (const repo of [armed, unarmed]) {
				const { verdict, ran } = await gate(repo, command);
				expect([command, verdict.kind]).toEqual([command, "refuse"]);
				if (verdict.kind !== "refuse") throw new Error("unreachable");
				expect(verdict.reason).toContain("does not model");
				expect(ran).toBe("");
			}
		}
		// The controls. A command with none of these parses as before, and one
		// naming no git at all is not this gate to judge however it is written.
		await both("git commit -m x", "allow", "refuse");
		await both("git -c core.pager=cat log", "allow", "allow");
		expect((await gate(armed, "echo $'hi'")).verdict).toEqual({ kind: "allow" });
		expect((await gate(armed, "x=$(( 1 << 2 ))")).verdict).toEqual({ kind: "allow" });
		// The KEN-866 regression. Removing quote characters joins fragments and
		// moves nothing else, so a pattern anchored to end-of-line names no commit.
		await both("grep -rn 'foo$' .git/config", "allow", "allow");
		await both("git log --oneline | grep 'fix$'", "allow", "allow");
		await both("git status --short | grep 'M$'", "allow", "allow");
		await both("git log --grep='fix$' | head", "allow", "allow");
		await both('git log --grep="foo\\\nbar"', "allow", "allow");
	});

	test("only <<- accepts a tab-indented terminator", async () => {
		// Strip tabs from every terminator and a tab-indented EOF ends a plain
		// heredoc early, leaving the body live: one quote in it swallowed the
		// commit behind it.
		const nv = "--no-" + "verify";
		const early = `cat <<EOF\n\tEOF\n"\nEOF\ngit commit ${nv} -m "x"`;
		await both(early, "refuse", "refuse");
		const named = await gate(armed, early);
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain(`'${nv}' bypasses`);
		// The control: under <<- it does terminate, and the body stays inert.
		await both(`cat <<-EOF\n\tgit commit ${nv} here\n\tEOF\ngit commit -m x`, "allow", "refuse");
	});

	test("a substitution close does not end the word", async () => {
		// `$(true)#x` is one word to bash, so the hash touching the close is an
		// ordinary character. Ending the word there made it a comment opener, and
		// everything after it — the commit included — was discarded as a comment.
		const nv = "--no-" + "verify";
		const touching = `echo $(true)#x && git commit ${nv} -m x`;
		await both(touching, "refuse", "refuse");
		const named = await gate(armed, touching);
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain(`'${nv}' bypasses`);
		// The control: a hash that is its own word still opens a comment.
		await both(`echo $(true) # x && git commit ${nv} -m x`, "allow", "allow");
	});

	test("a construct the scanner never heard of leaves the words standing", async () => {
		// Each of these desynchronised the argv parser that stood here, and each is
		// closed by the rule reading live words instead: `coproc` is named nowhere.
		for (const command of [
			"echo $(printf '(') && git commit --no-verify -m x",
			"git >$(printf /dev/null) commit --no-verify -m x",
			"coproc git commit --no-verify -m x",
			// An operator inside a substitution separates words, not commands.
			"git -C $(cd /t && pwd) commit --no-verify -m x",
			"git &>out commit --no-verify -m x",
			// A heredoc that never terminates would otherwise swallow the rest.
			"cat <<EOF\ngit commit --no-verify -m x",
		]) {
			await both(command, "refuse", "refuse");
			const named = await gate(armed, command);
			if (named.verdict.kind !== "refuse") throw new Error("unreachable");
			expect(named.verdict.reason).toContain("'--no-verify' bypasses");
		}
		// The control for the joined delimiter: there the body IS skipped, so the
		// words in it are prose rather than flags.
		await both("cat <<EO\\\nF > n.md\ngit commit --no-verify is banned here\nEOF\ngit commit -m x", "allow", "refuse");
	});

	test("a short-option cluster is read left to right", async () => {
		// The cluster used to be judged by its last character: -mnote was refused
		// for the n in the message, and -mfixc swallowed the real --no-verify as
		// its value.
		await both("git commit -mnote", "allow", "refuse");
		await both("git commit -mfixc --no-verify", "refuse", "refuse");
		await both("git commit -nm msg", "refuse", "refuse");

		const attached = await gate(armed, "git commit -mfixc --no-verify");
		if (attached.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(attached.verdict.reason).toContain("'--no-verify' bypasses");

		const cluster = await gate(armed, "git commit -nm msg");
		if (cluster.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(cluster.verdict.reason).toContain("'-nm' bypasses");
	});

	test("a command prefix does not hide the git word", async () => {
		// The bash hook's word-order predecessor caught every one of these without
		// reading a prefix at all, so a prefix this gate cannot resolve must not
		// read as not-a-git-command.
		for (const command of [
			"sudo git commit --no-verify -m x",
			"sudo -E git commit -n -m x",
			"sudo -u dev git commit --no-verify -m x",
			"env git commit -n -m x",
			"env -i git commit -n -m x",
			"/usr/bin/env -i git -c core.hooksPath=/dev/null commit -m x",
			"nice git commit -n -m x",
			"timeout 30 git commit -n -m x",
			"stdbuf -o0 git commit -n -m x",
			"/usr/bin/git commit --no-verify -m x",
		]) {
			await both(command, "refuse", "refuse");
		}
		await both("echo git commit --no-verify", "refuse", "refuse");
	});

	test("a wrapper option's operand is not a command word", async () => {
		// `git` is an ordinary account name (gitolite, Gitea), and reading the
		// operand as the command word left the bypass behind it unjudged. Such a
		// command takes the word-order rule instead.
		for (const command of ["sudo -u git git commit --no-verify -m x", "env -u git git commit --no-verify -m x"]) {
			await both(command, "refuse", "refuse");
			const named = await gate(armed, command);
			if (named.verdict.kind !== "refuse") throw new Error("unreachable");
			expect(named.verdict.reason).toContain("'--no-verify' bypasses");
		}
		// The direction the fallback has to keep: an ordinary wrapped commit still
		// defers, and only a bypass word in it refuses.
		await both("timeout 30 git commit -m x", "allow", "refuse");
		await both("nice git commit -m x", "allow", "refuse");
		await both("sudo -u dev git config core.hooksPath /dev/null && git commit -m x", "refuse", "refuse");
	});

	test("a construct the scanner does not model is not waved through", async () => {
		// Every gap in a hand-written scanner is a fail-open, so a command word this
		// gate left shell in takes the word-order rule rather than a guess: an
		// append assignment is no assignment to the tokenizer, and a dynamic file
		// descriptor stays a word ahead of its redirection.
		await both("PATH+=:/usr/bin git commit --no-verify -m x", "refuse", "refuse");
		await both("{fd}>out git commit --no-verify -m x", "refuse", "refuse");
		await both("PATH+=:/usr/bin git commit -m x", "allow", "refuse");

		// A quoted paren inside a substitution desynchronises the scan, and
		// everything after it is guesswork. The fallback runs on an unbalanced
		// command whatever an earlier one looked like — suppressing it there let
		// this bypass through.
		const desync = "git commit --allow-empty -m x && echo $(printf ')') && git commit --allow-empty --no-verify -m y";
		await both(desync, "refuse", "refuse");
		const named = await gate(armed, desync);
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain("'--no-verify' bypasses");
	});

	test("a redirection is redirection wherever it stands", async () => {
		// A line continuation inside the delimiter is removed, so this heredoc ends
		// at EOF; recorded literally it never terminates and swallows the commit.
		const joined = "cat <<EO\\\nF > n.md\nbody\nEOF\ngit commit --no-verify -m x";
		await both(joined, "refuse", "refuse");
		// Between the command word and its subcommand is a legal place for one, and
		// a process substitution is one target rather than argv words.
		for (const command of [joined, "git {fd}>out commit --no-verify -m x", "git < <(printf x) commit --no-verify -m x"]) {
			await both(command, "refuse", "refuse");
			const named = await gate(armed, command);
			if (named.verdict.kind !== "refuse") throw new Error("unreachable");
			expect(named.verdict.reason).toContain("'--no-verify' bypasses");
		}
	});

	test("forms this lane refuses rather than models", async () => {
		// Declined on KEN-833 as over-refusals, not defects: the trade this lane
		// makes is that an unmodelled command is refused. Pinned so a later change
		// cannot turn one of them into a commit that passes.
		await both("GIT_CONFIG_COUNT=1 python3 -c pass && git commit -m x", "refuse", "refuse");
		await both("git commit -Snone -m x", "refuse", "refuse");
		await both("git commit --m --no-verify", "refuse", "refuse");
	});

	test("a git global option owns its value", async () => {
		await both("git -ccore.hooksPath=/dev/null commit -m x", "refuse", "refuse");
		await both("git -C /tmp -c user.name=x commit -m y", "refuse", "refuse");
		await both("git -C -c commit -m x", "refuse", "refuse");

		const attached = await gate(armed, "git -ccore.hooksPath=/dev/null commit -m x");
		if (attached.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(attached.verdict.reason).toContain("'-ccore.hooksPath=/dev/null' bypasses");
	});

	test("a command whose quoting never closes is judged, not skipped", async () => {
		// The parser cannot tokenize this, so the word-order rule it replaced
		// stands in rather than the commit passing unjudged.
		await both("echo don't && git commit --no-verify -m x", "refuse", "refuse");
		await both("echo don't && git commit -m x", "allow", "refuse");
	});

	test("quoting and redirection hold the words together", async () => {
		await both("git commit>/dev/null -n -m x", "refuse", "refuse");
		await both("git -C `echo ; pwd` commit --no-verify -m x", "refuse", "refuse");

		// A redirection contributes nothing to the argv, target included: leave
		// the target behind and /dev/null reads as the subcommand, so the bypass
		// behind it is never judged at all.
		await both("git >/dev/null commit --no-verify -m x", "refuse", "refuse");
		await both("git 2>/dev/null commit --no-verify -m x", "refuse", "refuse");
		await both("git commit -m x >/dev/null", "allow", "refuse");

		for (const command of ["GIT_DIR=/elsewhere/.git git commit -m x", "GIT_WORK_TREE=/elsewhere git commit -m x"]) {
			const scan = scanCommand(command);
			expect([command, scan.commit, scan.moves]).toEqual([command, true, true]);
			const { verdict } = await gate(unarmed, command);
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("moves repositories");
		}
	});

	test("a long command is judged in linear time", async () => {
		// Ordinary characters are counted rather than copied and a heredoc body is
		// skipped whole, so neither twenty thousand git words nor a half-megabyte
		// file write stalls Pi's event loop before the tool runs.
		const body = "the quick brown fox jumps over the lazy dog; it's a note line\n".repeat(8000);
		const heredoc = `cat > note.md <<'EOF'\n${body}EOF\ngit commit -m note`;
		const heredocStarted = performance.now();
		expect(scanCommand(heredoc)).toEqual({ commit: true, moves: false, bypass: null, unmodelled: null });
		expect(performance.now() - heredocStarted).toBeLessThan(250);

		const command = " git x".repeat(20000);
		const started = performance.now();
		expect(scanCommand(command).commit).toBe(false);
		expect(await preCommitGate(command, armed)).toEqual({ kind: "allow" });
		expect(performance.now() - started).toBeLessThan(250);

		const { verdict } = await gate(armed, `git config --local core.hooksPath /dev/null &&${command} && git commit -m x`);
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("bypasses this repository's armed git hooks");
	});

	test("a non-commit command is left alone", async () => {
		const { verdict, ran } = await gate(unarmed, "ls -la");
		expect(verdict).toEqual({ kind: "allow" });
		expect(ran).toBe("");
	});

	test("a plain git commit in an unarmed repository is refused, never stood in for", async () => {
		for (const command of ["git commit -m test", "git -C /somewhere/else commit -m test", "cargo fmt\ngit commit -m x"]) {
			const { verdict, ran } = await gate(unarmed, command);
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("not armed by kendex");
			expect(verdict.reason).toContain("kendex guard install");
			expect(verdict.reason).toContain("kendex guard check");
			expect(ran).toBe("");
		}
	});

	test("an armed .git/hooks pair gates the commit itself", async () => {
		expect((await gate(armed, "git commit -m test")).verdict).toEqual({ kind: "allow" });
		expect((await gate(armed, "git commit -am test")).verdict).toEqual({ kind: "allow" });
		expect((await gate(armed, "git commit -m test")).ran).toBe("");
	});

	test("a core.hooksPath hook is not armed by this gate", async () => {
		const { verdict, ran } = await gate(armedByPath, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		expect(ran).toBe("");
	});

	test("a hook file git will not run is not armed", async () => {
		for (const repo of [disarmed, disarmedByPath, markedNotExec]) {
			const { verdict, ran } = await gate(repo, "git commit -m test");
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("not armed by kendex");
			expect(ran).toBe("");
		}
	});

	test("an executable pair without the marker is somebody else's hooks, not armed", async () => {
		const { verdict, ran } = await gate(foreign, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(ran).toBe("");
	});

	test("a marked pre-commit beside an unmarked commit-msg is not armed", async () => {
		const { verdict, ran } = await gate(mixed, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(ran).toBe("");
	});

	test("one lane armed is not an armed repository", async () => {
		const { verdict, ran } = await gate(halfArmed, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(ran).toBe("");
	});

	test("an empty core.hooksPath is hooks off, not a hooks directory", async () => {
		const { verdict, ran } = await gate(hooksOff, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(verdict.reason).toContain("kendex guard check");
		expect(ran).toBe("");
	});

	test("bypassing the armed hook is refused, not half-checked", async () => {
		for (const command of [
			"git commit --no-verify -m x",
			"git commit --no-verif -m x",
			"git commit -n -m x",
			"git commit -anm x",
			"git -c core.hooksPath=/dev/null commit -m x",
			"git -c core.hookspath=/dev/null commit -m x",
			"git -c include.path=/tmp/alt.config commit -m x",
			"git --config-env=core.hooksPath=HP commit -m x",
			"GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x",
			"GIT_CONFIG_COUNT=1 git commit -m x",
			"git config --local core.hooksPath /dev/null && git commit -m x",
			"git config --local --type path --includes --show-scope core.hooksPath /dev/null && git commit -m x",
		]) {
			const { verdict, ran } = await gate(armed, command);
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("bypasses this repository's armed git hooks");
			expect(ran).toBe("");
		}
		const named = await gate(armed, "git commit --no-verify -m x");
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain("'--no-verify' bypasses");

		const byPath = await gate(armedByPath, "git commit --no-verify -m x");
		expect(byPath.verdict.kind).toBe("refuse");
		expect(byPath.ran).toBe("");
	});

	test("the gate judges its working directory only", async () => {
		// From an armed directory it defers whatever the target; from an
		// unarmed one it judges itself and says so.
		expect((await gate(armed, `git -C ${unarmed} commit -m x`)).verdict).toEqual({ kind: "allow" });

		const fromUnarmed = await gate(unarmed, `git -C ${armed} commit -m x`);
		expect(fromUnarmed.verdict.kind).toBe("refuse");
		if (fromUnarmed.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(fromUnarmed.verdict.reason).toContain(`judged ${unarmed} only`);
		expect(fromUnarmed.verdict.reason).toContain("moves repositories");
		expect(fromUnarmed.ran).toBe("");

		const leadingCd = await gate(unarmed, 'cd "$dir" && git commit -m x');
		if (leadingCd.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(leadingCd.verdict.reason).toContain("moves repositories");

		const inPlace = await gate(unarmed, "git commit -m x");
		if (inPlace.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(inPlace.verdict.reason).not.toContain("moves repositories");

		const outside = await gate(notARepo, `git -C ${unarmed} commit -m x`);
		expect(outside.verdict.kind).toBe("allow");
		if (outside.verdict.kind !== "allow") throw new Error("unreachable");
		expect(outside.verdict.notice).toContain("moves repositories");
	});

	test("shell forms the old parser refused pass through an armed repository", async () => {
		for (const command of [
			'git -C "$repo" commit -m x',
			'repo=$(git rev-parse --show-toplevel) && git -C "$repo" commit -m x',
			'cd "$dir" && git commit -m x',
			"git -C `pwd` commit -m x",
			"(cd /target && git commit -m x)",
			"git --git-dir=/t/.git --work-tree=/t commit -m x",
			'git -C "/tmp/my repo" commit -m x',
		]) {
			const { verdict } = await gate(armed, command);
			expect(verdict).toEqual({ kind: "allow" });
		}
		expect((await gate(unarmed, 'git -C "/tmp/my repo" commit -m x')).verdict.kind).toBe("refuse");
	});
});

describe("bare cd detection", () => {
	test("matches a bare cd but not a scoped or chained one", () => {
		expect(isBareCd("cd /tmp")).toBe(true);
		expect(isBareCd("  cd sub/dir")).toBe(true);
		expect(isBareCd("(cd /tmp && ls)")).toBe(false);
		expect(isBareCd("cd /tmp && ls")).toBe(false);
	});

	test("a cd with no target is the same permanent move", () => {
		expect(isBareCd("cd")).toBe(true);
		expect(isBareCd("  cd  ")).toBe(true);
		expect(isBareCd("cdr --version")).toBe(false);
		expect(isBareCd("echo cd")).toBe(false);
	});

	test("read-only searches with backtick-bearing patterns are never bare cd (kendex#668)", () => {
		expect(isBareCd('rg -n "`kendex refresh`" skills/')).toBe(false);
		expect(isBareCd("rg -n '`kendex refresh`' skills/")).toBe(false);
		expect(isBareCd("rg -n '\\x60kendex refresh\\x60' skills/")).toBe(false);
		expect(isBareCd("rg -n '[\\x60]jq' skills/")).toBe(false);
	});
});
