import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import {
	expandLoadedSlashContent,
	parseCommandArgs,
	pasteAndSubmitToPane,
	resolveOwnTmuxPaneByParentChain,
	type ExecLike,
	type SlashCommandInfoLike,
} from "../extensions/session-bridge.ts";

let dir = "";
let oldTmux: string | undefined;
function p(name: string): string { return join(dir, name); }

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-slash-"));
	oldTmux = process.env.TMUX;
});

afterEach(() => {
	if (oldTmux === undefined) delete process.env.TMUX;
	else process.env.TMUX = oldTmux;
	if (dir) rmSync(dir, { recursive: true, force: true });
});

describe("slash expansion", () => {
	test("bridge dispatch matrix matches Pi editor outcomes", () => {
		const skillPath = p("skills/worktree/SKILL.md");
		const promptPath = p("prompts/clear-ai.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		mkdirSync(dirname(promptPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: worktree\ndescription: Worktree ops\n---\n# Worktree\nUse git worktrees.\n");
		writeFileSync(promptPath, "---\ndescription: Clear AI\n---\nClear $1 with all=$@ and rest=${@:2}\n");

		const commands: SlashCommandInfoLike[] = [
			{ name: "bridge:ping", source: "extension", sourceInfo: { path: p("bridge.ts") } },
			{ name: "tasks:add", source: "extension", sourceInfo: { path: p("tasks.ts") } },
			{ name: "skill:worktree", source: "skill", sourceInfo: { path: skillPath } },
			{ name: "clear-ai", source: "prompt", sourceInfo: { path: promptPath } },
		];

		const plain = expandLoadedSlashContent("hello", commands);
		expect(plain.expanded).toBe(false);

		const ping = expandLoadedSlashContent("/bridge:ping ok", commands);
		expect(ping.expanded).toBe(false); // Route 2: own tmux pane, editor executes extension command.

		const tasks = expandLoadedSlashContent("/tasks:add foo", commands);
		expect(tasks.expanded).toBe(false); // Route 2: own tmux pane, editor executes extension command.

		const skill = expandLoadedSlashContent("/skill:worktree status", commands);
		expect(skill.expanded).toBe(true);
		expect(skill.kind).toBe("skill");
		expect(skill.text).toBe([
			`<skill name="worktree" location="${skillPath}">`,
			`References are relative to ${dirname(skillPath)}.`,
			"",
			"# Worktree",
			"Use git worktrees.",
			"</skill>",
			"",
			"status",
		].join("\n"));

		const prompt = expandLoadedSlashContent('/clear-ai one "two words"', commands);
		expect(prompt.expanded).toBe(true);
		expect(prompt.kind).toBe("prompt");
		expect(prompt.text).toBe("Clear one with all=one two words and rest=two words");
	});

	test("extension command wins name collisions, matching Pi prompt() precedence", () => {
		const promptPath = p("prompts/dupe.md");
		mkdirSync(dirname(promptPath), { recursive: true });
		writeFileSync(promptPath, "Prompt body");
		const result = expandLoadedSlashContent("/dupe args", [
			{ name: "dupe", source: "prompt", sourceInfo: { path: promptPath } },
			{ name: "dupe", source: "extension", sourceInfo: { path: p("extension.ts") } },
		]);
		expect(result.expanded).toBe(false);
	});

	test("prompt and skill read failures are surfaced as expansion errors", () => {
		const prompt = expandLoadedSlashContent("/missing arg", [
			{ name: "missing", source: "prompt", sourceInfo: { path: p("prompts/missing.md") } },
		]);
		expect(prompt.expanded).toBe(false);
		expect(prompt.error).toContain("ENOENT");
		const skill = expandLoadedSlashContent("/skill:missing arg", [
			{ name: "skill:missing", source: "skill", sourceInfo: { path: p("skills/missing/SKILL.md") } },
		]);
		expect(skill.expanded).toBe(false);
		expect(skill.error).toContain("ENOENT");
	});

	test("prompt argument substitution matches Pi prompt-template rules", () => {
		expect(parseCommandArgs("one 'two words' \"three words\" four")).toEqual(["one", "two words", "three words", "four"]);
		expect(parseCommandArgs("one\ntwo 'three\nfour'\tfive")).toEqual(["one", "two", "three\nfour", "five"]);
		const promptPath = p("template.md");
		writeFileSync(promptPath, "---\ndescription: Demo\n---\n$1|$2|$@|$ARGUMENTS|${@:2}|${@:2:2}");
		const commands = [{ name: "template", source: "prompt", sourceInfo: { path: promptPath } }] as SlashCommandInfoLike[];
		const result = expandLoadedSlashContent('/template alpha "beta gamma" delta', commands);
		expect(result.text).toBe("alpha|beta gamma|alpha beta gamma delta|alpha beta gamma delta|beta gamma delta|beta gamma delta");
		const multiline = expandLoadedSlashContent("/template\nalpha beta", commands);
		expect(multiline.expanded).toBe(true);
		expect(multiline.text).toBe("alpha|beta|alpha beta|alpha beta|beta|beta");
	});

	test("dedups repeated skill expansion within the same session", () => {
		const skillPath = p("skills/flightdeck/SKILL.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: flightdeck\n---\n# Flightdeck\nWatch sessions.\n");
		const commands = [{ name: "skill:flightdeck", source: "skill", sourceInfo: { path: skillPath } }] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();

		const first = expandLoadedSlashContent("/skill:flightdeck watch --from-daemon", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(first.expanded).toBe(true);
		expect(first.text).toContain(`<skill name="flightdeck" location="${skillPath}">`);
		expect(first.text).toContain("# Flightdeck");

		const second = expandLoadedSlashContent("/skill:flightdeck watch --from-daemon", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(second.expanded).toBe(true);
		expect(second.kind).toBe("skill");
		expect(second.text).toBe("Skill flightdeck (previously loaded). Invocation: watch --from-daemon");
		expect(second.text).not.toContain("<skill");
		expect(second.text).not.toContain("# Flightdeck");

		const otherSession = expandLoadedSlashContent("/skill:flightdeck watch --from-daemon", commands, readFileSync, {
			sessionId: "session-b",
			skillExpansionCache: cache,
		});
		expect(otherSession.text).toContain(`<skill name="flightdeck" location="${skillPath}">`);
	});

	test("re-expands skill after SKILL.md content changes", () => {
		const skillPath = p("skills/orchestration/SKILL.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: orchestration\n---\n# Orchestration v1\n");
		const commands = [{ name: "skill:orchestration", source: "skill", sourceInfo: { path: skillPath } }] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();

		const first = expandLoadedSlashContent("/skill:orchestration run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(first.text).toContain("# Orchestration v1");

		const deduped = expandLoadedSlashContent("/skill:orchestration run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(deduped.text).toBe("Skill orchestration (previously loaded). Invocation: run");

		writeFileSync(skillPath, "---\nname: orchestration\n---\n# Orchestration v2\n");
		const changed = expandLoadedSlashContent("/skill:orchestration run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(changed.text).toContain(`<skill name="orchestration" location="${skillPath}">`);
		expect(changed.text).toContain("# Orchestration v2");
		expect(changed.text).not.toContain("# Orchestration v1");

		const dedupedAgain = expandLoadedSlashContent("/skill:orchestration run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(dedupedAgain.text).toBe("Skill orchestration (previously loaded). Invocation: run");
	});

	test("dedup is independent per skill within a session (pins Map<sessionId, Map<skillName, hash>>)", () => {
		const alphaPath = p("skills/alpha/SKILL.md");
		const betaPath = p("skills/beta/SKILL.md");
		mkdirSync(dirname(alphaPath), { recursive: true });
		mkdirSync(dirname(betaPath), { recursive: true });
		writeFileSync(alphaPath, "---\nname: alpha\n---\n# Alpha Skill\nA body.\n");
		writeFileSync(betaPath, "---\nname: beta\n---\n# Beta Skill\nB body.\n");
		const commands = [
			{ name: "skill:alpha", source: "skill", sourceInfo: { path: alphaPath } },
			{ name: "skill:beta", source: "skill", sourceInfo: { path: betaPath } },
		] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();
		const options = { sessionId: "session-a", skillExpansionCache: cache };

		const firstAlpha = expandLoadedSlashContent("/skill:alpha run-a", commands, readFileSync, options);
		expect(firstAlpha.text).toContain(`<skill name="alpha" location="${alphaPath}">`);
		expect(firstAlpha.text).toContain("# Alpha Skill");

		// Skill B in the same session must still get the FULL body, not the dedup reminder.
		const firstBeta = expandLoadedSlashContent("/skill:beta run-b", commands, readFileSync, options);
		expect(firstBeta.text).toContain(`<skill name="beta" location="${betaPath}">`);
		expect(firstBeta.text).toContain("# Beta Skill");
		expect(firstBeta.text).not.toContain("previously loaded");

		// Re-expanding each skill independently now hits the short reminder for each.
		const secondAlpha = expandLoadedSlashContent("/skill:alpha run-a", commands, readFileSync, options);
		expect(secondAlpha.text).toBe("Skill alpha (previously loaded). Invocation: run-a");

		const secondBeta = expandLoadedSlashContent("/skill:beta run-b", commands, readFileSync, options);
		expect(secondBeta.text).toBe("Skill beta (previously loaded). Invocation: run-b");
	});
});

describe("tmux pane dispatch", () => {
	test("resolves own pane by parent chain, not active tmux client state", async () => {
		process.env.TMUX = "/tmp/tmux-1000/default,123,0";
		const calls: Array<[string, string[]]> = [];
		const exec: ExecLike = async (command, args) => {
			calls.push([command, args]);
			if (command === "tmux") return { code: 0, stdout: "100 %1\n250 %2\n" };
			const pid = args.at(-1);
			if (pid === "303") return { code: 0, stdout: "202\n" };
			if (pid === "202") return { code: 0, stdout: "100\n" };
			if (pid === "100") return { code: 0, stdout: "1\n" };
			return { code: 1, stderr: "missing pid" };
		};

		await expect(resolveOwnTmuxPaneByParentChain(exec, 303)).resolves.toBe("%1");
		expect(calls[0]).toEqual(["tmux", ["list-panes", "-a", "-F", "#{pane_pid} #{pane_id}"]]);
		expect(calls.some(([command, args]) => command === "tmux" && args[0] === "display-message")).toBe(false);
	});

	test("pastes slash text literally and submits Enter", async () => {
		const calls: Array<[string, string[]]> = [];
		const exec: ExecLike = async (command, args) => {
			calls.push([command, args]);
			return { code: 0, stdout: "" };
		};
		await pasteAndSubmitToPane(exec, "%7", "/tasks:add foo");
		expect(calls).toEqual([
			["tmux", ["send-keys", "-t", "%7", "-l", "/tasks:add foo"]],
			["tmux", ["send-keys", "-t", "%7", "Enter"]],
		]);
	});
});
