import { mock } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/** Replaces Pi's runtime packages with the few members the extension calls at load. */
export function mockPiModules(): void {
	mock.module("@earendil-works/pi-ai", () => ({
		StringEnum: (values: readonly string[], options: Record<string, unknown> = {}) => ({ ...options, enum: values }),
	}));
	mock.module("@earendil-works/pi-tui", () => ({
		matchesKey: () => false,
		truncateToWidth: (text: string) => text,
		visibleWidth: (text: string) => text.length,
		wrapTextWithAnsi: (text: string) => text.split(/\r?\n/),
	}));
	mock.module("typebox", () => ({
		Type: {
			Array: (item: unknown) => ({ item, type: "array" }),
			Boolean: (options: Record<string, unknown> = {}) => ({ ...options, type: "boolean" }),
			Number: (options: Record<string, unknown> = {}) => ({ ...options, type: "number" }),
			Object: (properties: Record<string, unknown>) => ({ properties, type: "object" }),
			Optional: (value: unknown) => ({ optional: true, value }),
			String: (options: Record<string, unknown> = {}) => ({ ...options, type: "string" }),
		},
	}));
}

/** A Pi extension API that records what the extension registers and appends. */
export function fakePi() {
	return {
		appended: [] as Array<{ customType: string; data: any }>,
		commands: new Map<string, any>(),
		handlers: new Map<string, (event: unknown, ctx: unknown) => unknown>(),
		renderers: new Map<string, any>(),
		shortcuts: new Map<string, any>(),
		tools: new Map<string, any>(),
		appendEntry(customType: string, data: unknown) { this.appended.push({ customType, data }); },
		on(event: string, handler: (event: unknown, ctx: unknown) => unknown) { this.handlers.set(event, handler); },
		registerCommand(name: string, command: any) { this.commands.set(name, command); },
		registerMessageRenderer(name: string, renderer: any) { this.renderers.set(name, renderer); },
		registerShortcut(name: string, shortcut: any) { this.shortcuts.set(name, shortcut); },
		registerTool(tool: any) { this.tools.set(tool.name, tool); },
	};
}

/** A headless session context whose session id names the sidecar directory. */
export function fakeCtx(base: string, sessionId: string, notifications: Array<{ message: string; level: string }> = []) {
	return {
		cwd: base,
		hasUI: false,
		sessionManager: {
			getBranch: () => [],
			getSessionFile: () => join(base, "session.jsonl"),
			getSessionId: () => sessionId,
		},
		ui: {
			notify: (message: string, level: string) => notifications.push({ message, level }),
			setWidget: () => {},
		},
	};
}

/** The task lines `/tasks:export` writes for the panel's current state. */
export async function exportedTasks(base: string, pi: ReturnType<typeof fakePi>, ctx: ReturnType<typeof fakeCtx>): Promise<string[]> {
	const exported = join(base, "exported.md");
	await pi.commands.get("tasks:export").handler(exported, ctx);
	return readFileSync(exported, "utf8").split("\n").filter((line) => line.startsWith("- ")).map((line) => line.slice(2));
}
