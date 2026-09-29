import { mock } from "bun:test";

// A fake of the Pi extension API and context the QOL extension registers on:
// each suite that starts the extension drives its handlers through these.

export interface CompactCall { customInstructions?: string; onComplete?: () => void; onError?: (e: Error) => void }

export interface CapturedHandlers {
	[name: string]: (event: any, ctx: any) => any;
}

export interface FakeApi {
	handlers: CapturedHandlers;
	eventBusHandlers: Record<string, (data: any) => void>;
	commands: Record<string, any>;
	shortcuts: Record<string, any>;
	renderers: Record<string, any>;
	api: any;
}

export function makeFakeApi(): FakeApi {
	const handlers: CapturedHandlers = {};
	const eventBusHandlers: Record<string, (data: any) => void> = {};
	const commands: Record<string, any> = {};
	const shortcuts: Record<string, any> = {};
	const renderers: Record<string, any> = {};
	const api: any = {
		events: {
			on(name: string, handler: (data: any) => void) {
				eventBusHandlers[name] = handler;
			},
		},
		getActiveTools: () => [],
		getAllTools: () => [],
		getCommands: () => [],
		getSessionName: () => undefined,
		getThinkingLevel: () => "off",
		on(name: string, handler: (event: any, ctx: any) => any) {
			handlers[name] = handler;
		},
		registerCommand(name: string, opts: any) {
			commands[name] = opts;
		},
		registerMessageRenderer(type: string, renderer: any) {
			renderers[type] = renderer;
		},
		registerShortcut(key: string, opts: any) {
			shortcuts[key] = opts;
		},
		sendMessage() {},
		setSessionName() {},
	};
	return { api, commands, eventBusHandlers, handlers, renderers, shortcuts };
}

export function makeCtx(overrides: Partial<any> = {}) {
	return {
		abort() {},
		compact: mock((_options: CompactCall) => {}),
		cwd: process.env.PI_CODING_AGENT_DIR ?? "/tmp",
		getContextUsage: () => ({ contextWindow: 200_000, percent: 90, tokens: 180_000 }),
		getSystemPrompt: () => "",
		hasPendingMessages: () => false,
		hasUI: false,
		isIdle: () => true,
		model: undefined,
		modelRegistry: { find: () => undefined, getApiKeyAndHeaders: async () => ({ apiKey: "k", ok: true }) },
		sessionManager: {
			getBranch: () => [],
			getSessionFile: () => undefined,
			getSessionId: () => "test-session",
		},
		shutdown() {},
		signal: undefined,
		ui: {
			notify: mock((_message: string, _level: string) => {}),
			setEditorComponent() {},
			setHeader() {},
			setFooter() {},
			setStatus() {},
			setWidget() {},
		},
		...overrides,
	};
}
