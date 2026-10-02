import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

let listed: unknown[] = [];
mock.module("@earendil-works/pi-coding-agent", () => ({
	SessionManager: {
		list: async () => listed,
		listAll: async () => listed,
		open: () => {
			throw new Error("no session model in this fixture");
		},
	},
}));

const KEYS: Record<string, string> = {
	"alt+d": "\x1bd",
	"alt+n": "\x1bn",
	"alt+r": "\x1br",
	"alt+s": "\x1bs",
	backspace: "\x7f",
	delete: "\x1b[3~",
	down: "\x1b[B",
	end: "\x1b[F",
	enter: "\r",
	escape: "\x1b",
	home: "\x1b[H",
	return: "\r",
	up: "\x1b[A",
};
const BINDINGS: Record<string, string> = {
	"tui.select.cancel": KEYS.escape!,
	"tui.select.confirm": KEYS.enter!,
	"tui.select.down": KEYS.down!,
	"tui.select.up": KEYS.up!,
};

class FakeInput {
	focused = false;
	onSubmit: ((value: string) => void) | undefined;
	private value = "";
	getValue(): string {
		return this.value;
	}
	setValue(value: string): void {
		this.value = value;
	}
	handleInput(data: string): void {
		if (!data.startsWith("\x1b")) this.value += data;
	}
	render(): string[] {
		return [this.value];
	}
	invalidate(): void {}
}

mock.module("@earendil-works/pi-tui", () => ({
	Input: FakeInput,
	matchesKey: (data: string, key: string) => KEYS[key] === data,
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.length,
}));

interface Overlay {
	handleInput(data: string): void;
	dispose(): void;
}

type Notice = [message: string, kind: string];

let saved: Record<string, string | undefined> = {};
beforeEach(() => {
	saved = { PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
});
afterEach(async () => {
	for (const [key, value] of Object.entries(saved)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
	clearPackageConfigCache();
});

// The fixture holds one session per prompt. PATH is an empty bin directory, so a
// delete finds no `trash` and unlinks.
async function openOverlay(prompts: string[]) {
	const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
	const { openManager } = await import("../extensions/overlay.ts");
	const root = sessionFixture();
	const bin = join(root, "bin");
	mkdirSync(bin);
	process.env.PATH = bin;
	process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
	clearPackageConfigCache();
	listed = prompts.map((prompt, index) => {
		const path = join(root, `session-${index}.jsonl`);
		writeFileSync(path, `${JSON.stringify({ type: "message", message: { role: "user", content: prompt } })}\n`);
		return { path, id: `session-${index}`, name: "", firstMessage: prompt, cwd: root, messageCount: 1, modified: new Date(2026, 0, 1 + index) };
	});
	const paths = listed.map((session) => (session as { path: string }).path);

	const notices: Notice[] = [];
	const actions: unknown[] = [];
	let overlay: Overlay | undefined;
	const ctx = {
		cwd: root,
		sessionManager: { getSessionFile: () => undefined },
		ui: {
			notify: (message: string, kind: string) => notices.push([message, kind]),
			custom: (factory: (...args: unknown[]) => Overlay) =>
				new Promise((resolve) => {
					const keybindings = { matches: (data: string, id: string) => BINDINGS[id] === data };
					overlay = factory({ requestRender() {}, terminal: { rows: 40 } }, {}, keybindings, (action: unknown) => {
						actions.push(action);
						resolve(action);
					});
				}),
		},
	};
	void openManager(ctx as never, {} as never);
	const state = () => overlay as unknown as { mode: string; searching: boolean; deleteAllTargets: { path: string }[]; notice: { kind: string; text: string } | undefined };
	await until(() => state().mode === "browse" && !state().searching);
	return { overlay: overlay!, state, notices, actions, paths };
}

// The overlay's load, debounce and delete run on real promises and timers;
// polling them is the one way to see each settle.
async function until(condition: () => boolean): Promise<void> {
	const deadline = performance.now() + 3_000;
	while (!condition()) {
		if (performance.now() > deadline) throw new Error("overlay did not settle within 3 s");
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
}

test("a session action while a typed query is pending is refused until the search settles", async () => {
	const { overlay, state, actions, paths } = await openOverlay(["alpha task", "zap the bug"]);
	for (const char of "zap") overlay.handleInput(char);

	const pending = { kind: "info", text: "Search still running" };
	for (const key of ["alt+d", "delete", "enter", "alt+r"]) {
		overlay.handleInput(KEYS[key]!);
		expect({ key, mode: state().mode, targets: state().deleteAllTargets.length, actions: actions.length, notice: state().notice }).toEqual({
			key,
			mode: "browse",
			targets: 0,
			actions: 0,
			notice: pending,
		});
	}

	await until(() => !state().searching);
	expect(state().notice).toBeUndefined();
	overlay.handleInput(KEYS["alt+d"]!);
	expect(state().mode).toBe("confirm-delete-all");
	expect(state().deleteAllTargets.map((session) => session.path)).toEqual([paths[1]!]);
});

// Each row closes the browser while its first delete is in flight. That delete
// finishes, its outcome goes to Pi, no later delete starts, and no scan refills
// the prompt cache the close released. A delete-all run that stopped short
// reports as an error.
for (const row of [
	{ name: "a single delete", keys: ["delete", "enter"], kind: "info" },
	{ name: "a delete-all run", keys: ["alt+d", "enter"], kind: "error" },
]) {
	test(`${row.name} that outlives the browser reports through Pi and starts no scan`, async () => {
		const { sessionUserMessagesCache } = await import("../extensions/session-data.ts");
		const { overlay, state, notices, paths } = await openOverlay(["zap one", "zap two"]);
		for (const char of "zap") overlay.handleInput(char);
		await until(() => !state().searching);

		for (const key of row.keys) overlay.handleInput(KEYS[key]!);
		expect(state().mode).toBe("deleting");
		overlay.dispose();
		await until(() => notices.length > 0);

		expect(notices.map(([, kind]) => kind)).toEqual([row.kind]);
		expect(paths.filter((path) => !existsSync(path)).length).toBe(1);
		expect(sessionUserMessagesCache.size).toBe(0);
	});
}
