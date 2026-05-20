import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";

import flightdeck, { dashboardAllowedForStatus, renderStateErrorBanner } from "../extensions/flightdeck.js";
import { dashboardVisibleForSnapshot } from "../extensions/dashboard-visibility.js";
import { resetMiniDashboardRegistryForTests } from "../extensions/stacked-widget.js";
import { buildSnapshotFromInputs, flightdeckSessionStatus, resetTmuxContextCacheForTests } from "../extensions/state.js";

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

type EventHandler = (event: unknown, ctx: MockContext) => void;

const SAVED_ENV: Record<string, string | undefined> = {};
let ENV_HOME = "";
let ENV_PI_DIR = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE", "PATH", "TMUX", "FD_STATE_DIR", "FLIGHTDECK_STATE_DIR", "FLIGHTDECK_CHILD_PANE", "PI_SUBAGENT_CHILD_AGENT"]) {
		SAVED_ENV[key] = process.env[key];
	}
	resetMiniDashboardRegistryForTests();
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-home-"));
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-piconf-"));
	process.env.HOME = ENV_HOME;
	process.env.PI_CODING_AGENT_DIR = ENV_PI_DIR;
	process.env.XDG_CONFIG_HOME = ENV_HOME;
	process.env.USERPROFILE = ENV_HOME;
	delete process.env.FLIGHTDECK_CHILD_PANE;
	delete process.env.PI_SUBAGENT_CHILD_AGENT;
});

afterEach(() => {
	for (const [key, value] of Object.entries(SAVED_ENV)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	resetTmuxContextCacheForTests();
	resetMiniDashboardRegistryForTests();
	if (ENV_HOME) rmSync(ENV_HOME, { force: true, recursive: true });
	if (ENV_PI_DIR) rmSync(ENV_PI_DIR, { force: true, recursive: true });
});

function makeProject(binBody: string): string {
	const project = mkdtempSync(join(tmpdir(), "pi-flightdeck-entry-project-"));
	mkdirSync(join(project, ".git"));
	const binDir = join(project, ".agents", "skills", "flightdeck", "scripts");
	mkdirSync(binDir, { recursive: true });
	const bin = join(binDir, "flightdeck-dashboard");
	const argvFile = join(project, "dashboard-argv.txt");
	const cwdFile = join(project, "dashboard-cwd.txt");
	writeFileSync(bin, `#!/usr/bin/env bash
printf '%s\n' "$PWD" > ${JSON.stringify(cwdFile)}
: > ${JSON.stringify(argvFile)}
for arg in "$@"; do printf '%s\n' "$arg" >> ${JSON.stringify(argvFile)}; done
${binBody}
`);
	chmodSync(bin, 0o755);
	return project;
}

function dashboardArgv(project: string): string[] {
	const text = readFileSync(join(project, "dashboard-argv.txt"), "utf8");
	return text.trim().length > 0 ? text.trimEnd().split("\n") : [];
}

function assertDashboardInvocation(project: string, expectedArgs: string[]): void {
	assert.deepEqual(dashboardArgv(project), expectedArgs);
	assert.equal(readFileSync(join(project, "dashboard-cwd.txt"), "utf8").trim(), project);
}

function makePi() {
	const commands = new Map<string, RegisteredCommand>();
	const shortcuts = new Map<string, RegisteredShortcut>();
	const events = new Map<string, EventHandler>();
	const pi = {
		events: { on(_name: string, _handler: unknown) { /* settings events unused here */ } },
		on(name: string, handler: EventHandler) { events.set(name, handler); },
		registerCommand(name: string, command: RegisteredCommand) { commands.set(name, command); },
		registerShortcut(name: string, shortcut: RegisteredShortcut) { shortcuts.set(name, shortcut); },
	};
	return { commands, events, pi, shortcuts };
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

function makeTheme() {
	return {
		bold(text: string) { return text; },
		fg(_name: string, text: string) { return text; },
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

test("/flightdeck reports focus-or-launch success", async () => {
	const project = makeProject("printf '{\"status\":\"focused\",\"reason\":\"existing dashboard\",\"pane\":\"%%9\",\"window\":\"@9\"}\n'");
	try {
		const { commands, pi } = makePi();
		flightdeck(pi as never);
		const ctx = makeContext(project);

		await commands.get("flightdeck")?.handler("", ctx);

		assertDashboardInvocation(project, ["focus-or-launch", "--json"]);
		assert.deepEqual(ctx.notifications, [{ message: "Flightdeck app focused (window @9 · pane %9)", level: "info" }]);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});

test("/flightdeck reports focus-or-launch blocked", async () => {
	const project = makeProject("printf '{\"status\":\"blocked\",\"reason\":\"not in tmux\"}\n'; exit 1");
	try {
		const { commands, pi } = makePi();
		flightdeck(pi as never);
		const ctx = makeContext(project);

		await commands.get("flightdeck")?.handler("", ctx);

		assertDashboardInvocation(project, ["focus-or-launch", "--json"]);
		assert.deepEqual(ctx.notifications, [{ message: "Flightdeck app blocked: not in tmux", level: "warning" }]);
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

		assertDashboardInvocation(project, ["focus-or-launch", "--json"]);
		assert.equal(ctx.notifications.length, 1);
		assert.equal(ctx.notifications[0]?.level, "error");
		assert.match(ctx.notifications[0]?.message ?? "", /malformed JSON/);
		assert.match(ctx.notifications[0]?.message ?? "", /not-json/);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});

test("/flightdeck filters duplicate user --json", async () => {
	const project = makeProject("printf '{\"status\":\"launched\",\"reason\":\"new dashboard\"}\n'");
	try {
		const { commands, pi } = makePi();
		flightdeck(pi as never);
		const ctx = makeContext(project);

		await commands.get("flightdeck")?.handler("--json", ctx);

		assertDashboardInvocation(project, ["focus-or-launch", "--json"]);
		assert.deepEqual(ctx.notifications, [{ message: "Flightdeck app launched", level: "info" }]);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});

test("/flightdeck forwards extra user args after status-shell entrypoint", async () => {
	const project = makeProject("printf '{\"status\":\"focused\",\"reason\":\"with args\"}\n'");
	try {
		const { commands, pi } = makePi();
		flightdeck(pi as never);
		const ctx = makeContext(project);

		await commands.get("flightdeck")?.handler("--session test-fd --no-daemon --json --window-name FD", ctx);

		assertDashboardInvocation(project, ["focus-or-launch", "--json", "--session", "test-fd", "--no-daemon", "--window-name", "FD"]);
		assert.deepEqual(ctx.notifications, [{ message: "Flightdeck app focused", level: "info" }]);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});

test("malformed live state renders error banner despite owner-only visibility", () => {
	const project = makeProject("printf '{\"status\":\"focused\"}\n'");
	try {
		mkdirSync(join(project, "tmp"), { recursive: true });
		writeFileSync(join(project, "tmp", "flightdeck-state-test-fd.json"), "{not-json");
		const snapshot = buildSnapshotFromInputs({
			projectRoot: project,
			stateDir: join(project, "runtime"),
			tmux: { paneId: "%11", sessionId: "$42", sessionKey: "s42", sessionName: "test-fd" },
		}, { flightdeckStateDir: "tmp" });
		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		const ownerPaneAllowed = dashboardVisibleForSnapshot(snapshot, "owner");
		assert.equal(ownerPaneAllowed, false);
		assert.equal(dashboardAllowedForStatus(ownerPaneAllowed, "state-error"), true);
		const rendered = renderStateErrorBanner(snapshot!, makeTheme() as never, 160).join("\n");

		assert.match(rendered, /FLIGHTDECK STATE ERROR/);
		assert.match(rendered, /Expected property name|Unexpected token|JSON/);
		assert.match(rendered, /flightdeck-state-test-fd\.json/);
	} finally {
		rmSync(project, { force: true, recursive: true });
	}
});
