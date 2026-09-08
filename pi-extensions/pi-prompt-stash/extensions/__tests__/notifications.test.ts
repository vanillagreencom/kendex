import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

mock.module("@earendil-works/pi-tui", () => ({
	Input: class {},
	matchesKey: () => false,
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.length,
}));

const { default: promptStash } = await import("../prompt-stash.js");

let root = "";
let previousAgentDir: string | undefined;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "pi-prompt-stash-test-"));
	mkdirSync(join(root, "project", ".pi"), { recursive: true });
	mkdirSync(join(root, "agent"));
	previousAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(root, "agent");
});

afterEach(() => {
	if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
	rmSync(root, { recursive: true, force: true });
});

for (const row of [
	{ name: "empty command", editorText: "", expected: "prompt_stash_items=0" },
	{ name: "saved shortcut", editorText: "draft", expected: "prompt_stash_items=1" },
]) {
	test(row.name, async () => {
		let command: { handler: (args: string, ctx: any) => Promise<void> } | undefined;
		let shortcut: { handler: (ctx: any) => Promise<void> } | undefined;
		const notices: Array<{ message: string; level: string }> = [];
		let editorText = row.editorText;
		const pi = {
			on() {},
			registerCommand(_name: string, definition: typeof command) { command = definition; },
			registerShortcut(_key: string, definition: typeof shortcut) { shortcut = definition; },
		};
		promptStash(pi as never);
		const ctx = {
			cwd: join(root, "project"),
			hasUI: true,
			sessionManager: {
				getSessionFile: () => undefined,
				getSessionId: () => "session-1",
			},
			ui: {
				getEditorText: () => editorText,
				notify: (message: string, level: string) => notices.push({ message, level }),
				setEditorText: (value: string) => { editorText = value; },
			},
		};
		if (row.editorText) await shortcut!.handler(ctx);
		else await command!.handler("", ctx);
		expect(notices).toHaveLength(1);
		expect(notices[0]!.message.split("\n")[0]).toBe(row.expected);
		expect(notices[0]!.level).toBe("info");
		if (row.editorText) {
			const stored = JSON.parse(readFileSync(join(root, "agent", "kendex", "sessions", "session-1", "prompt-stash", "prompt-stash.json"), "utf8"));
			expect(stored.items).toHaveLength(1);
			expect(editorText).toBe("");
		}
	});
}
