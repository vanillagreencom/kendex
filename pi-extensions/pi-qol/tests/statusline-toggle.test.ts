import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
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
		`${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": values } } } }, null, 2)}\n`,
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
const nativeTimeout = globalThis.setTimeout;
let timerSpy: ReturnType<typeof spyOn> | undefined;
let zeroDelayCallbacks: Array<() => void> = [];
let activeWorld: { fake: FakeApi; ctx: ReturnType<typeof makeCtx> } | undefined;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-statusline-toggle-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
	delete process.env.TMUX;
	delete process.env.TMUX_PANE;
	zeroDelayCallbacks = [];
	timerSpy = spyOn(globalThis, "setTimeout").mockImplementation(((callback: (...args: unknown[]) => void, delay?: number, ...args: unknown[]) => {
		if (delay !== 0) return nativeTimeout(callback, delay, ...args);
		zeroDelayCallbacks.push(() => callback(...args));
		return { unref() {} } as ReturnType<typeof setTimeout>;
	}) as typeof setTimeout);
});

afterEach(() => {
	try {
		if (activeWorld) activeWorld.fake.handlers.session_shutdown({ reason: "quit" }, activeWorld.ctx);
	} finally {
		activeWorld = undefined;
		zeroDelayCallbacks = [];
		timerSpy?.mockRestore();
		if (workdir) rmSync(workdir, { force: true, recursive: true });
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
		if (originalHome === undefined) delete process.env.HOME;
		else process.env.HOME = originalHome;
		if (originalTmux === undefined) delete process.env.TMUX;
		else process.env.TMUX = originalTmux;
		if (originalTmuxPane === undefined) delete process.env.TMUX_PANE;
		else process.env.TMUX_PANE = originalTmuxPane;
	}
});

function world(settings: Record<string, unknown> = {}) {
	writeQolConfig({ "sessionSearch.enabled": false, "sessionAutoRename.enabled": false, ...settings });
	const fake = makeFakeApi();
	const ctx = makeCtx();
	activeWorld = { fake, ctx };
	qolDefault(fake.api);
	return activeWorld;
}

function install(fake: FakeApi, ctx: ReturnType<typeof makeCtx>) {
	fake.handlers.session_start({ reason: "startup" }, ctx);
	for (const callback of zeroDelayCallbacks.splice(0)) callback();
}

const installationRows = [
	{
		name: "default statusline installation",
		settings: {},
		expected: { statusline: true, footers: 1, editors: 1 },
	},
	{
		name: "disabled statusline retains editor helpers",
		settings: { "enableScheduleCommand": false, "statusline.enabled": false },
		expected: { statusline: false, footers: 0, editors: 1, execs: 0 },
	},
];

if (installationRows.length === 0) throw new Error("Statusline installation table is empty");

for (const row of installationRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const { fake, ctx } = world(row.settings);
		install(fake, ctx);
		expect({
			statusline: setWidgetNames(ctx).includes("statusline"),
			footers: ctx.ui.setFooter.mock.calls.length,
			editors: ctx.ui.setEditorComponent.mock.calls.length,
			...("execs" in row.expected ? { execs: fake.api.exec.mock.calls.length } : {}),
		}).toEqual(row.expected);
	});
}

const titleRows = [
	{
		name: "session_info_changed refreshes the UI title",
		hasUI: true,
		expected: { rendered: true, statusIncreased: true, finalStatusKey: "session-manager" },
	},
	{
		name: "session_info_changed is inert without a UI",
		hasUI: false,
		expected: { statusCalls: 0 },
	},
];

if (titleRows.length === 0) throw new Error("Session title event table is empty");

for (const row of titleRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const { fake, ctx } = world();
		let sessionName: string | undefined;
		fake.api.getSessionName = () => sessionName;
		ctx.hasUI = row.hasUI;
		const requestRender = mock(() => {});
		if (row.hasUI) {
			install(fake, ctx);
			const editorFactory = ctx.ui.setEditorComponent.mock.calls.at(-1)?.[0];
			editorFactory?.({ requestRender }, makeTheme(), {});
			requestRender.mockClear();
		}
		const before = ctx.ui.setStatus.mock.calls.length;
		sessionName = row.hasUI ? "Renamed session" : "Headless rename";
		fake.handlers.session_info_changed({ name: sessionName }, ctx);
		expect(row.hasUI ? {
			rendered: requestRender.mock.calls.length > 0,
			statusIncreased: ctx.ui.setStatus.mock.calls.length > before,
			finalStatusKey: ctx.ui.setStatus.mock.calls.at(-1)?.[0],
		} : { statusCalls: ctx.ui.setStatus.mock.calls.length }).toEqual(row.expected);
	});
}
