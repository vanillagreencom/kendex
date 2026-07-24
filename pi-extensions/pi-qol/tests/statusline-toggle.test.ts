import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import qolDefault from "../extensions/qol.ts";

interface FakeApi {
	handlers: Record<string, (event: any, ctx: any) => any>;
	api: any;
}

function makeFakeApi(): FakeApi {
	const handlers: Record<string, (event: any, ctx: any) => any> = {};
	const api: any = {
		events: { on() {}, emit() {} },
		exec: mock(async () => ({ code: 1, stdout: "", stderr: "" })),
		getActiveTools: () => [],
		getAllTools: () => [],
		getCommands: () => [],
		getSessionName: () => undefined,
		getThinkingLevel: () => "off",
		on(name: string, handler: (event: any, ctx: any) => any) {
			handlers[name] = handler;
		},
		registerCommand() {},
		registerMessageRenderer() {},
		registerShortcut() {},
		sendMessage() {},
		setSessionName() {},
	};
	return { api, handlers };
}

function makeTheme() {
	return {
		bg: (_token: string, text: string) => text,
		bold: (text: string) => text,
		fg: (_token: string, text: string) => text,
		italic: (text: string) => text,
	};
}

function makeCtx() {
	return {
		abort() {},
		compact: mock(() => {}),
		cwd: workdir,
		getContextUsage: () => ({ contextWindow: 200_000, percent: 20, tokens: 40_000 }),
		getSystemPrompt: () => "",
		hasPendingMessages: () => false,
		hasUI: true,
		isIdle: () => true,
		model: undefined,
		modelRegistry: { find: () => undefined, getApiKeyAndHeaders: async () => ({ apiKey: "k", ok: true }) },
		sessionManager: {
			getBranch: () => [],
			getSessionFile: () => undefined,
			getSessionId: () => "statusline-toggle-test",
		},
		shutdown() {},
		signal: undefined,
		ui: {
			addAutocompleteProvider: mock(() => {}),
			notify: mock(() => {}),
			setEditorComponent: mock(() => {}),
			setFooter: mock(() => {}),
			setHeader: mock(() => {}),
			setHiddenThinkingLabel: mock(() => {}),
			setStatus: mock(() => {}),
			setWidget: mock(() => {}),
			setWorkingIndicator: mock(() => {}),
			setWorkingVisible: mock(() => {}),
			theme: makeTheme(),
		},
	};
}

function writeQolConfig(values: Record<string, unknown>): void {
	writeFileSync(
		join(workdir, "settings.json"),
		`${JSON.stringify({ vstack: { extensionManager: { config: { "@vanillagreen/pi-qol": values } } } }, null, 2)}\n`,
		"utf8",
	);
}

function setWidgetNames(ctx: any): string[] {
	return ctx.ui.setWidget.mock.calls.map((call: any[]) => call[0]);
}

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;
const originalTmux = process.env.TMUX;
const originalTmuxPane = process.env.TMUX_PANE;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-statusline-toggle-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
	delete process.env.TMUX;
	delete process.env.TMUX_PANE;
});

afterEach(() => {
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	if (originalTmux === undefined) delete process.env.TMUX;
	else process.env.TMUX = originalTmux;
	if (originalTmuxPane === undefined) delete process.env.TMUX_PANE;
	else process.env.TMUX_PANE = originalTmuxPane;
});

test("session_start installs the QOL statusline by default", async () => {
	writeQolConfig({ "sessionSearch.enabled": false, "sessionAutoRename.enabled": false });
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctx = makeCtx();

	fake.handlers.session_start?.({ reason: "startup" }, ctx);
	await new Promise((resolve) => setTimeout(resolve, 5));

	expect(setWidgetNames(ctx)).toContain("statusline");
	expect(ctx.ui.setFooter.mock.calls.length).toBe(1);
	expect(ctx.ui.setEditorComponent.mock.calls.length).toBe(1);
	fake.handlers.session_shutdown?.({ reason: "quit" }, ctx);
});

test("statusline.enabled=false keeps QOL editor helpers but skips statusline/footer replacement", async () => {
	writeQolConfig({ "enableScheduleCommand": false, "statusline.enabled": false, "sessionSearch.enabled": false, "sessionAutoRename.enabled": false });
	const fake = makeFakeApi();
	qolDefault(fake.api);
	const ctx = makeCtx();

	fake.handlers.session_start?.({ reason: "startup" }, ctx);
	await new Promise((resolve) => setTimeout(resolve, 5));

	expect(setWidgetNames(ctx)).not.toContain("statusline");
	expect(ctx.ui.setFooter.mock.calls.length).toBe(0);
	expect(ctx.ui.setEditorComponent.mock.calls.length).toBe(1);
	expect(fake.api.exec.mock.calls.length).toBe(0);
	fake.handlers.session_shutdown?.({ reason: "quit" }, ctx);
});

test("session_info_changed syncs the session title without waiting for the poll", async () => {
	writeQolConfig({ "sessionSearch.enabled": false, "sessionAutoRename.enabled": false });
	let sessionName: string | undefined;
	const fake = makeFakeApi();
	fake.api.getSessionName = () => sessionName;
	qolDefault(fake.api);
	const ctx = makeCtx();

	fake.handlers.session_start?.({ reason: "startup" }, ctx);
	const requestRender = mock(() => {});
	const editorFactory = ctx.ui.setEditorComponent.mock.calls.at(-1)?.[0];
	editorFactory?.({ requestRender }, makeTheme(), {});
	requestRender.mockClear();
	const statusCallsBefore = ctx.ui.setStatus.mock.calls.length;

	sessionName = "Renamed session";
	fake.handlers.session_info_changed?.({ name: sessionName }, ctx);

	// syncSessionTitle re-renders on a changed name and always reasserts the
	// session-manager status slot, so both prove the handler ran the sync.
	expect(requestRender.mock.calls.length).toBeGreaterThan(0);
	expect(ctx.ui.setStatus.mock.calls.length).toBeGreaterThan(statusCallsBefore);
	expect(ctx.ui.setStatus.mock.calls.at(-1)?.[0]).toBe("session-manager");
	fake.handlers.session_shutdown?.({ reason: "quit" }, ctx);
});

test("session_info_changed is a no-op without a UI", async () => {
	writeQolConfig({ "sessionSearch.enabled": false, "sessionAutoRename.enabled": false });
	const fake = makeFakeApi();
	fake.api.getSessionName = () => "Headless rename";
	qolDefault(fake.api);
	const ctx = makeCtx();
	ctx.hasUI = false;

	fake.handlers.session_info_changed?.({ name: "Headless rename" }, ctx);

	expect(ctx.ui.setStatus.mock.calls.length).toBe(0);
});
