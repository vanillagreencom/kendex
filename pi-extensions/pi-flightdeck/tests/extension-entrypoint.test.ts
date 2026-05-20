import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";

import flightdeck from "../extensions/flightdeck.js";

interface RegisteredCommand {
	description?: string;
	handler(args: string, ctx: MockContext): Promise<void> | void;
}

interface RegisteredShortcut {
	description?: string;
	handler(ctx: MockContext): Promise<void> | void;
}

interface MockContext {
	cwd: string;
	hasUI: boolean;
	ui: {
		notify(message: string, level?: string): void;
		setWidget(key: string, factory: unknown, options?: unknown): void;
		openPopup?(): void;
	};
}

const SAVED_ENV: Record<string, string | undefined> = {};
let ENV_HOME = "";
let ENV_PI_DIR = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE"]) {
		SAVED_ENV[key] = process.env[key];
	}
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-home-"));
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-piconf-"));
	process.env.HOME = ENV_HOME;
	process.env.PI_CODING_AGENT_DIR = ENV_PI_DIR;
	process.env.XDG_CONFIG_HOME = ENV_HOME;
	process.env.USERPROFILE = ENV_HOME;
});

afterEach(() => {
	for (const [key, value] of Object.entries(SAVED_ENV)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	if (ENV_HOME) rmSync(ENV_HOME, { force: true, recursive: true });
	if (ENV_PI_DIR) rmSync(ENV_PI_DIR, { force: true, recursive: true });
});

function makeProject(binBody: string): string {
	const project = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-project-"));
	mkdirSync(join(project, ".git"));
	const binDir = join(project, ".agents", "skills", "flightdeck", "scripts");
	mkdirSync(binDir, { recursive: true });
	const bin = join(binDir, "flightdeck-dashboard");
	writeFileSync(bin, `#!/usr/bin/env bash\n${binBody}\n`);
	chmodSync(bin, 0o755);
	return project;
}

function makePi() {
	const commands = new Map<string, RegisteredCommand>();
	const shortcuts = new Map<string, RegisteredShortcut>();
	const pi = {
		events: { on() { /* no-op */ } },
		on() { /* no-op */ },
		registerCommand(name: string, command: RegisteredCommand) { commands.set(name, command); },
		registerShortcut(name: string, shortcut: RegisteredShortcut) { shortcuts.set(name, shortcut); },
	};
	return { commands, pi, shortcuts };
}

function makeContext(cwd: string): MockContext & { notifications: Array<{ message: string; level?: string }>; widgets: Array<{ key: string; factory: unknown; options?: unknown }> } {
	const notifications: Array<{ message: string; level?: string }> = [];
	const widgets: Array<{ key: string; factory: unknown; options?: unknown }> = [];
	return {
		cwd,
		hasUI: true,
		notifications,
		widgets,
		ui: {
			notify(message: string, level?: string) { notifications.push({ message, level }); },
			setWidget(key: string, factory: unknown, options?: unknown) { widgets.push({ key, factory, options }); },
			openPopup() { throw new Error("popup API must not be called by status shell"); },
		},
	};
}

test("extension registers only status-shell commands and toggle shortcut", async () => {
	const project = makeProject("printf '{\"status\":\"blocked\",\"reason\":\"not in tmux\"}\\n'");
	try {
		const { commands, pi, shortcuts } = makePi();
		flightdeck(pi as never);

		assert.deepEqual([...commands.keys()].sort(), ["flightdeck", "flightdeck:toggle"]);
		assert.equal([...commands.keys()].some((name) => /popup|watch|prune/i.test(name)), false);
		assert.deepEqual([...shortcuts.keys()], ["alt+m"]);

		const ctx = makeContext(project);
		await commands.get("flightdeck:toggle")?.handler("", ctx);
		await shortcuts.get("alt+m")?.handler(ctx);
		assert.deepEqual(ctx.notifications.map((note) => note.message), ["Flightdeck dashboard expanded", "Flightdeck dashboard hidden"]);
		assert.equal(ctx.widgets.some((widget) => widget.key.includes("popup")), false);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});

test("/flightdeck reports malformed focus-or-launch JSON as an error", async () => {
	const project = makeProject("echo 'not-json'; exit 0");
	try {
		const { commands, pi } = makePi();
		flightdeck(pi as never);
		const ctx = makeContext(project);

		await commands.get("flightdeck")?.handler("", ctx);

		assert.equal(ctx.notifications.length, 1);
		assert.equal(ctx.notifications[0]?.level, "error");
		assert.match(ctx.notifications[0]?.message ?? "", /malformed JSON/);
		assert.match(ctx.notifications[0]?.message ?? "", /not-json/);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});
