import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { expandLoadedSlashContent, type SlashCommandInfoLike } from "../extensions/session-bridge.ts";
import { p, useSlashFixture } from "./lib/slash-fixture.ts";

useSlashFixture();

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

		for (const row of [
			{ input: "hello", expected: { expanded: false } },
			{ input: "/bridge:ping ok", expected: { expanded: false } },
			{ input: "/tasks:add foo", expected: { expanded: false } },
			{ input: "/skill:worktree status", expected: { expanded: true, kind: "skill", text: [
				`<skill name="worktree" location="${skillPath}">`, `References are relative to ${dirname(skillPath)}.`,
				"", "# Worktree", "Use git worktrees.", "</skill>", "", "status",
			].join("\n") } },
			{ input: '/clear-ai one "two words"', expected: { expanded: true, kind: "prompt", text: "Clear one with all=one two words and rest=two words" } },
		]) {
			expect(expandLoadedSlashContent(row.input, commands)).toMatchObject(row.expected);
		}

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

	for (const row of [
		{ name: "missing", source: "prompt", path: "prompts/missing.md" },
		{ name: "skill:missing", source: "skill", path: "skills/missing/SKILL.md" },
	]) {
		test(`${row.source} read failure`, () => {
			const result = expandLoadedSlashContent(`/${row.name} arg`, [{ name: row.name, source: row.source, sourceInfo: { path: p(row.path) } }]);
			expect(result.expanded).toBe(false);
			expect(result.error?.split("\n")[0]).toBe(`error_code=ENOENT path=${p(row.path)}`);
		});
	}

	test("prompt argument substitution matches Pi prompt-template rules", () => {
		const promptPath = p("template.md");
		writeFileSync(promptPath, "---\ndescription: Demo\n---\n$1|$2|$@|$ARGUMENTS|${@:2}|${@:2:2}|${4:-fallback}|${2:-unused}|${5:-$1}|${@:-all-fallback}|${ARGUMENTS:-arguments-fallback}");
		const commands = [{ name: "template", source: "prompt", sourceInfo: { path: promptPath } }] as SlashCommandInfoLike[];
		for (const row of [
			{ input: '/template alpha "beta gamma" delta', expected: "alpha|beta gamma|alpha beta gamma delta|alpha beta gamma delta|beta gamma delta|beta gamma delta|fallback|beta gamma|$1|alpha beta gamma delta|alpha beta gamma delta" },
			{ input: "/template\nalpha beta", expected: "alpha|beta|alpha beta|alpha beta|beta|beta|fallback|beta|$1|alpha beta|alpha beta" },
			{ input: "/template", expected: "||||||fallback|unused|$1|all-fallback|arguments-fallback" },
		]) {
			const result = expandLoadedSlashContent(row.input, commands);
			expect(result.expanded).toBe(true);
			expect(result.text).toBe(row.expected);
		}

	});

});
