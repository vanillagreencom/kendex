import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { CONFIG_ID } from "../extensions/config.ts";
import nestedAgentsMd, { directoriesBetween, INSTRUCTIONS_FILE } from "../extensions/nested-agents-md.ts";

type Handler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown> | unknown;

/* Unset, the settings reader takes ~/.pi/agent, so the developer's own global
 * settings would answer in every case. An empty root is the one nobody has
 * configured. */
let savedAgentDir: string | undefined;
let emptyAgentDir: string | undefined;
beforeAll(() => {
	savedAgentDir = process.env.PI_CODING_AGENT_DIR;
	emptyAgentDir = mkdtempSync(join(tmpdir(), "pi-nested-agents-md-empty-agent-"));
	process.env.PI_CODING_AGENT_DIR = emptyAgentDir;
});
afterAll(() => {
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	if (emptyAgentDir !== undefined) rmSync(emptyAgentDir, { recursive: true, force: true });
});

/** The extension's handlers, captured off a fake Pi. */
function install(): { toolResult: Handler; sessionStart: Handler } {
	const handlers: Record<string, Handler> = {};
	nestedAgentsMd({ on(event: string, cb: Handler) { handlers[event] = cb; } } as never);
	if (!handlers.tool_result || !handlers.session_start) throw new Error("tool_result and session_start handlers were not both registered");
	return { toolResult: handlers.tool_result, sessionStart: handlers.session_start };
}

/**
 * A project: `.pi/` marks it as one the way kendex's own root walk reads a
 * project, and the tree carries an instructions file at the root, one level
 * down and two levels down, plus a directory holding none. The root is bound
 * canonical at creation, since every assertion below compares paths the
 * extension resolved through `realpath`.
 */
function project(): string {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-nested-agents-md-")));
	mkdirSync(join(root, ".pi"));
	write(root, INSTRUCTIONS_FILE, "# root rules\n");
	write(root, "top.ts", "top");
	write(root, `a/${INSTRUCTIONS_FILE}`, "# a rules\n");
	write(root, "a/shallow.ts", "shallow");
	write(root, "a/other.ts", "other");
	write(root, `a/b/${INSTRUCTIONS_FILE}`, "# b rules\n");
	write(root, "a/b/deep.ts", "deep");
	write(root, "plain/file.ts", "plain");
	return root;
}

function write(root: string, relative: string, content: string): void {
	const path = join(root, relative);
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
}

function writeConfig(root: string, config: Record<string, unknown>): void {
	writeFileSync(join(root, ".pi", "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { [CONFIG_ID]: config } } },
	}));
}

function readEvent(path: string): Record<string, unknown> {
	return { toolName: "read", input: { path }, content: [{ type: "text", text: "the file" }], isError: false };
}

/** A trusted workspace, since project settings are read only in one. */
function ctx(cwd: string): Record<string, unknown> {
	return { cwd, isProjectTrusted: () => true, hasUI: false };
}

/** The text of every block a patched result carries, the original first. */
function texts(result: unknown): string[] {
	const content = (result as { content?: { type: string; text: string }[] } | undefined)?.content;
	if (!Array.isArray(content)) throw new Error(`expected a patched result, got ${JSON.stringify(result)}`);
	return content.map((block) => {
		expect(block.type).toBe("text");
		return block.text;
	});
}

const roots: string[] = [];
function fixture(): string {
	const root = project();
	roots.push(root);
	return root;
}
afterEach(() => {
	for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

// The walk's own bound. Every read the handler makes reaches the root through
// the cwd chain as well, since the root is an ancestor of the cwd, so a walk
// that overran the root would still attach nothing there; this is what holds
// the bound itself, and the refusal that keeps a miscall from walking to the
// filesystem top.
describe("directoriesBetween", () => {
	test("lists the directories below the root, root-most first, the root excluded", () => {
		expect(directoriesBetween("/r/a/b/x.ts", "/r")).toEqual(["/r/a", "/r/a/b"]);
		expect(directoriesBetween("/r/x.ts", "/r")).toEqual([]);
	});

	test("refuses a file outside the root rather than walking to the top", () => {
		expect(() => directoriesBetween("/elsewhere/x.ts", "/r")).toThrow("is not under /r");
	});
});

describe("attaching", () => {
	test("the first read under a directory attaches its AGENTS.md after the file, naming the path", async () => {
		const root = fixture();
		const { toolResult } = install();
		const blocks = texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)));
		expect(blocks).toHaveLength(2);
		expect(blocks[0]).toBe("the file");
		expect(blocks[1]).toBe(`[Directory instructions from ${join(root, "a", INSTRUCTIONS_FILE)}]\n# a rules\n`);
	});

	test("the project root's own AGENTS.md is never attached", async () => {
		const root = fixture();
		const { toolResult } = install();
		expect(await toolResult(readEvent(join(root, "top.ts")), ctx(root))).toBeUndefined();
		const blocks = texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)));
		expect(blocks.join("\n")).not.toContain("# root rules");
	});

	test("a second read under the same directory attaches nothing", async () => {
		const root = fixture();
		const { toolResult } = install();
		texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)));
		expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root))).toBeUndefined();
		expect(await toolResult(readEvent(join(root, "a/other.ts")), ctx(root))).toBeUndefined();
	});

	test("a read two levels deep attaches both intermediate files, root-most first", async () => {
		const root = fixture();
		const { toolResult } = install();
		const blocks = texts(await toolResult(readEvent(join(root, "a/b/deep.ts")), ctx(root)));
		expect(blocks).toHaveLength(3);
		expect(blocks[1]).toContain(join(root, "a", INSTRUCTIONS_FILE));
		expect(blocks[1]).toContain("# a rules");
		expect(blocks[2]).toContain(join(root, "a", "b", INSTRUCTIONS_FILE));
		expect(blocks[2]).toContain("# b rules");
		// The deep read took `a/` with it, so a shallower read has nothing left.
		expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root))).toBeUndefined();
	});

	test("a relative path resolves against the session's cwd", async () => {
		const root = fixture();
		const { toolResult } = install();
		const blocks = texts(await toolResult(readEvent("a/shallow.ts"), ctx(root)));
		expect(blocks[1]).toContain("# a rules");
	});

	test("a directory Pi loaded at startup — the cwd or one above it — is not attached again", async () => {
		const root = fixture();
		const { toolResult } = install();
		const cwd = join(root, "a");
		expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(cwd))).toBeUndefined();
		const blocks = texts(await toolResult(readEvent(join(root, "a/b/deep.ts")), ctx(cwd)));
		expect(blocks).toHaveLength(2);
		expect(blocks[1]).toContain("# b rules");
		expect(blocks[1]).not.toContain("# a rules");
	});

	test("a session start begins the session's record again", async () => {
		const root = fixture();
		const { toolResult, sessionStart } = install();
		texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)));
		expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root))).toBeUndefined();
		await sessionStart({ reason: "new" }, ctx(root));
		expect(texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)))).toHaveLength(2);
	});
});

describe("attaching nothing", () => {
	test("a path outside the project root, spelled directly or reached through a symlink", async () => {
		const root = fixture();
		const outside = realpathSync(mkdtempSync(join(tmpdir(), "pi-nested-agents-md-outside-")));
		roots.push(outside);
		write(outside, `${INSTRUCTIONS_FILE}`, "# outside rules\n");
		write(outside, "leaf/file.ts", "x");
		symlinkSync(outside, join(root, "a", "escape"));
		const { toolResult } = install();
		expect(await toolResult(readEvent(join(outside, "leaf/file.ts")), ctx(root))).toBeUndefined();
		// The spelled path sits under `a/`, whose AGENTS.md has not been
		// attached; the file it resolves to does not, so not even that is.
		expect(await toolResult(readEvent(join(root, "a/escape/leaf/file.ts")), ctx(root))).toBeUndefined();
	});

	test("a directory holding no AGENTS.md", async () => {
		const root = fixture();
		const { toolResult } = install();
		expect(await toolResult(readEvent(join(root, "plain/file.ts")), ctx(root))).toBeUndefined();
	});

	test("a cwd in no project", async () => {
		const bare = realpathSync(mkdtempSync(join(tmpdir(), "pi-nested-agents-md-bare-")));
		roots.push(bare);
		write(bare, `a/${INSTRUCTIONS_FILE}`, "# a rules\n");
		write(bare, "a/file.ts", "x");
		const { toolResult } = install();
		expect(await toolResult(readEvent(join(bare, "a/file.ts")), ctx(bare))).toBeUndefined();
	});

	test("a failed read, and a tool other than read", async () => {
		const root = fixture();
		const { toolResult } = install();
		expect(await toolResult({ ...readEvent(join(root, "a/shallow.ts")), isError: true }, ctx(root))).toBeUndefined();
		expect(await toolResult({ ...readEvent(join(root, "a/shallow.ts")), toolName: "bash" }, ctx(root))).toBeUndefined();
		// Neither consumed `a/`: the next real read still attaches it.
		expect(texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)))).toHaveLength(2);
	});

	test("the master toggle off, read from the trusted project's settings", async () => {
		const root = fixture();
		const { toolResult } = install();
		writeConfig(root, { enabled: false });
		expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root))).toBeUndefined();
		// The control for the toggle: the same session, the same read, the
		// setting flipped — so a reader that never found the file is not
		// mistaken for one that read `false`.
		writeConfig(root, { enabled: true });
		expect(texts(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root)))).toHaveLength(2);
	});
});

describe("an unreadable AGENTS.md", () => {
	// Root reads a mode-000 file, so under it the case cannot be planted.
	test.skipIf(process.getuid?.() === 0)("is reported in one line, once, and the read still succeeds", async () => {
		const root = fixture();
		const unreadable = join(root, "a", INSTRUCTIONS_FILE);
		chmodSync(unreadable, 0o000);
		try {
			const { toolResult } = install();
			const blocks = texts(await toolResult(readEvent(join(root, "a/b/deep.ts")), ctx(root)));
			expect(blocks).toHaveLength(3);
			expect(blocks[1]).not.toContain("\n");
			expect(blocks[1]).toContain(unreadable);
			expect(blocks[1]).not.toContain("# a rules");
			expect(blocks[2]).toContain("# b rules");
			expect(await toolResult(readEvent(join(root, "a/shallow.ts")), ctx(root))).toBeUndefined();
		} finally {
			chmodSync(unreadable, 0o644);
		}
	});
});
