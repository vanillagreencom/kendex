import { describe, expect, test } from "bun:test";

import { Markdown } from "@earendil-works/pi-tui";

import {
	__test,
	installAssistantMessageRenderer,
	installCompactionSummaryRenderer,
	installMarkdownCodeBlockRenderer,
	installSkillInvocationRenderer,
	installUserMessageRenderer,
} from "../tool-renderer/messages.js";

function staleCtx(): any {
	return Object.defineProperties({}, {
		cwd: {
			get() {
				throw new Error("ExtensionContext is inactive");
			},
		},
		hasUI: {
			get() {
				throw new Error("ExtensionContext is inactive");
			},
		},
		ui: {
			get() {
				throw new Error("ExtensionContext is inactive");
			},
		},
	});
}

function createPi() {
	const handlers = new Map<string, Array<(...args: any[]) => void>>();
	return {
		api: {
			on(event: string, handler: (...args: any[]) => void) {
				const eventHandlers = handlers.get(event) ?? [];
				eventHandlers.push(handler);
				handlers.set(event, eventHandlers);
			},
		},
		emit(event: string, ...args: any[]) {
			for (const handler of handlers.get(event) ?? []) handler(...args);
		},
	};
}

const markdownTheme = {
	bg(_token: string, text: string) {
		return `\x1b[48;5;236m${text}\x1b[49m`;
	},
	codeBlock(text: string) {
		return text;
	},
	fg(_token: string, text: string) {
		return text;
	},
	highlightCode(code: string) {
		return code.split("\n");
	},
};

describe("stale ExtensionContext fallbacks", () => {
	test("safe context helpers fall back when Pi context getters throw", () => {
		const ctx = staleCtx();

		expect(__test.safeCtxCwd(ctx)).toBe(process.cwd());
		expect(__test.safeCtxHasUI(ctx)).toBe(false);
		expect(__test.safeCtxTheme(ctx).fg("text", "ok")).toBe("ok");
	});

	test("message component patches survive a stale active context", () => {
		const userPi = createPi();
		class UserMessageComponent {
			contentBox = {
				paddingY: 1,
				invalidateCache() {},
				setBgFn(_fn?: unknown) {},
			};
			render(width: number) {
				return [`user ${width}`];
			}
		}
		installUserMessageRenderer(userPi.api as any, UserMessageComponent);
		userPi.emit("session_start", {}, staleCtx());
		expect(() => new UserMessageComponent().render(20)).not.toThrow();
		userPi.emit("session_shutdown");

		const assistantPi = createPi();
		class AssistantMessageComponent {
			contentContainer = { children: [] };
			hasToolCalls = false;
			lastMessage: any;
			render(_width: number) {
				return ["assistant"];
			}
			updateContent(message: any) {
				this.lastMessage = message;
			}
		}
		installAssistantMessageRenderer(assistantPi.api as any, AssistantMessageComponent);
		assistantPi.emit("session_start", {}, staleCtx());
		expect(() => new AssistantMessageComponent().updateContent({ content: [{ text: "hi", type: "text" }] })).not.toThrow();
		assistantPi.emit("session_shutdown");

		const compactionPi = createPi();
		class CompactionSummaryComponent {
			children: any[] = [];
			expanded = false;
			markdownTheme = markdownTheme;
			message = { summary: "Kept the important details.", tokensBefore: 1234 };
			paddingX = 1;
			paddingY = 1;
			addChild(child: any) {
				this.children.push(child);
			}
			clear() {
				this.children = [];
			}
			setBgFn(_fn?: unknown) {}
			updateDisplay() {}
		}
		installCompactionSummaryRenderer(compactionPi.api as any, CompactionSummaryComponent);
		compactionPi.emit("session_start", {}, staleCtx());
		expect(() => new CompactionSummaryComponent().updateDisplay()).not.toThrow();
		compactionPi.emit("session_shutdown");

		const skillPi = createPi();
		class SkillInvocationComponent {
			children: any[] = [];
			expanded = false;
			markdownTheme = markdownTheme;
			paddingX = 1;
			paddingY = 1;
			skillBlock = { content: "Read the instructions.", name: "dev" };
			addChild(child: any) {
				this.children.push(child);
			}
			clear() {
				this.children = [];
			}
			setBgFn(_fn?: unknown) {}
			updateDisplay() {}
		}
		installSkillInvocationRenderer(skillPi.api as any, SkillInvocationComponent);
		skillPi.emit("session_start", {}, staleCtx());
		expect(() => new SkillInvocationComponent().updateDisplay()).not.toThrow();
		skillPi.emit("session_shutdown");
	});

	test("styled markdown code blocks survive a stale active context", () => {
		const rendered = __test.renderStyledCodeBlock({ lang: "ts", text: "const ok = true;", type: "code" }, 24, markdownTheme, staleCtx());
		expect(rendered.join("\n")).toContain("const ok = true;");

		const pi = createPi();
		installMarkdownCodeBlockRenderer(pi.api as any);
		pi.emit("session_start", {}, staleCtx());
		try {
			const markdown = new Markdown("", 0, 0, markdownTheme) as any;
			expect(() => markdown.renderToken({ lang: "ts", text: "const ok = true;", type: "code" }, 24)).not.toThrow();
		} finally {
			pi.emit("session_shutdown");
		}
	});
});
