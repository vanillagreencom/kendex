// Preload that stubs @earendil-works/* peer dependencies. Pi provides these
// at runtime; for `bun test ./tests` they would otherwise need `bun install`
// to materialize. The stubs are intentionally minimal — just the surface
// area touched by code under test — so behavioral assertions exercise the
// QOL wiring, not the upstream packages.

import { mock } from "bun:test";

class StubBase {}

mock.module("@earendil-works/pi-coding-agent", () => ({
	AssistantMessageComponent: class extends StubBase {},
	BorderedLoader: class extends StubBase {
		onAbort?: () => void;
		signal?: AbortSignal;
		constructor(_tui?: any, _theme?: any, _label?: string) {
			super();
		}
	},
	CustomEditor: class extends StubBase {},
	SessionManager: class extends StubBase {},
	Theme: class extends StubBase {},
	convertToLlm: (messages: unknown) => (Array.isArray(messages) ? messages : []),
	serializeConversation: (messages: unknown) => {
		if (!Array.isArray(messages)) return "";
		return messages
			.map((m: any) => {
				const role = m?.role ?? "unknown";
				const content = m?.content;
				let text = "";
				if (typeof content === "string") text = content;
				else if (Array.isArray(content)) {
					text = content
						.map((part: any) => {
							if (typeof part?.text === "string") return part.text;
							if (typeof part?.thinking === "string") return part.thinking;
							return "";
						})
						.join("");
				}
				return `${role}: ${text}`;
			})
			.join("\n\n");
	},
}));

mock.module("@earendil-works/pi-ai", () => ({
	complete: async () => ({
		content: [{ text: "stubbed summary text", type: "text" }],
		stopReason: "end_turn",
	}),
}));

mock.module("@earendil-works/pi-tui", () => {
	class StubText extends StubBase {
		text = "";
		setText(text: string): void {
			this.text = text;
		}
	}
	return {
		Text: StubText,
		matchesKey: () => false,
		truncateToWidth: (text: string, width: number, suffix: string = "") => {
			if (typeof text !== "string") return "";
			if (width <= 0) return "";
			if (text.length <= width) return text;
			if (suffix && width > suffix.length) {
				return text.slice(0, Math.max(0, width - suffix.length)) + suffix;
			}
			return text.slice(0, width);
		},
		visibleWidth: (text: string) => (typeof text === "string" ? text.length : 0),
		wrapTextWithAnsi: (text: string) => [text],
	};
});

mock.module("@earendil-works/pi-agent-core", () => ({}));
