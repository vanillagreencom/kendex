import { afterAll, beforeAll, describe, expect, test } from "bun:test";

import { type GateHarness, armGateFixtures } from "./gate-harness.ts";

describe("pre-commit gate: constructs the scanner does not model", () => {
	let h: GateHarness;
	let armed: string;
	let unarmed: string;
	let gate: GateHarness["gate"];
	let both: GateHarness["both"];

	beforeAll(async () => {
		h = await armGateFixtures();
		({ armed, unarmed, gate, both } = h);
	});

	afterAll(() => h.disarm());


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
			"x=$(( 1 << 2 )) && git commit -m x",
			// The prerequisite takes either answer to where the commit is, and each of
			// these has only one of them. The first two have only the assembled word:
			// the alias value spells the commit out of an escape and across a
			// continuation, so no text of the command ever holds it. The third has
			// only the text: the scanner reads the shift as a heredoc opener, and the
			// body it then skips swallows the commit line bash does run, so no live
			// word holds it either.
			`git config alias.c "com\\\nmit -n" && git c --allow-empty -m x`,
			`git config alias.c com\\mit && git c ${nv} -m x`,
			`x=$(( 1 << EOF ))\ngit commit ${nv} -m x\nEOF\ngit status`,
			// The prerequisite is read off the command with its quote characters
			// removed, so a spelling the shell assembles reads as its letters. Each
			// of these is the word once the quotes come out, and one also spells git.
			"git com''mit $'--no-verify' -m x",
			"git $'com''mit' --no-verify -m x",
			"git status && $'g''it' commit --no-verify -m x",
			// An alias key carried inline keeps the bare git prerequisite: it
			// renames the subcommand of this very invocation, so no normalizing
			// brings the word back. It is read off the live words, so a key the
			// shell assembles across a line continuation is that key however the
			// text was written.
			"git -c alias.c='co' co --allow-empty -m x",
			`git -c alias.c\\\n=com\\\nmit c ${nv} -m x`,
			`git -c "ali\\\nas.c=com\\\nmit -n" c --allow-empty -m x`,
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
		// The KEN-870 regression. A trigger fires where the construct can change
		// what the command runs, not wherever its text appears. A key written to
		// the config runs nothing here — it takes effect on later commands, which
		// arrive as their own payloads — so it is judged behind the commit word
		// like any other text, and a body hiding the commit in a script it names
		// is out of model exactly as that script is. A line continuation inside
		// quotes is joined rather than named, so what is judged is the word it
		// assembles: a flag either side of the break is that flag, and a message
		// either side of it is prose.
		await both("git config alias.st status", "allow", "allow");
		await both("git config alias.c 'status' && git c", "allow", "allow");
		await both("cat <<EOF\ngit -c alias.c=co co\nEOF\ngit status", "allow", "allow");
		// Behind a real heredoc that same body is the control: bash runs nothing in
		// it, so the commit the text holds is text and this passes.
		await both(`cat <<EOF\ngit commit ${nv} -m x\nEOF\ngit status`, "allow", "allow");
		await both('git commit "a\\\nb"', "allow", "refuse");
		await both('git commit -m "line one\nline two"', "allow", "refuse");
		const joined = await gate(armed, `git commit "--no-veri\\\nfy" -m x`);
		expect(joined.verdict.kind).toBe("refuse");
		if (joined.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(joined.verdict.reason).toContain(`'${nv}' bypasses`);
	});
});
