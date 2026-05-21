import { expect, test } from "bun:test";
import { renderQolContextUsageMessage, type QolContextUsageMessageDetails } from "../extensions/qol/context-usage.ts";

const stubTheme: any = {
	bold: (text: string) => `<b>${text}</b>`,
	fg: (_color: string, text: string) => text,
	italic: (text: string) => text,
};

function baseDetails(overrides: Partial<QolContextUsageMessageDetails> = {}): QolContextUsageMessageDetails {
	return {
		builtinTools: [],
		categories: [{ color: "accent", icon: "*", key: "messages", label: "Messages", rawTokens: 100, tokens: 100 }],
		compactSummaries: [],
		contextFiles: [],
		customAgents: [],
		extensionTools: [],
		mcpTools: [],
		messageStats: { assistant: 0, bash: 0, branchEntries: 0, compact: 0, contextMessages: 0, custom: 0, toolResult: 0, user: 0 },
		model: { contextWindow: 200_000, id: "m", label: "m", provider: "p" },
		skills: [],
		usage: { contextWindow: 200_000, percent: 50, tokens: 100_000 },
		...overrides,
	};
}

function render(details: QolContextUsageMessageDetails): string {
	const lines = renderQolContextUsageMessage({ details } as any, {} as any, stubTheme as any).render(200);
	return lines.join("\n");
}

test("renderer omits the transcript-risk block when risk is undefined", () => {
	const output = render(baseDetails({ transcriptRisk: undefined }));
	expect(output).not.toContain("Transcript risk");
	expect(output).not.toContain("Transcript payload");
});

test("renderer shows a muted payload line when risk is present but below threshold", () => {
	const output = render(baseDetails({
		transcriptRisk: { chars: 100_000, exceeded: false, messageCount: 50, threshold: 600_000 },
	}));
	expect(output).toContain("Transcript payload");
	expect(output).not.toMatch(/Transcript risk\b/);
});

test("renderer renders the bold transcript-risk warning when exceeded", () => {
	const output = render(baseDetails({
		transcriptRisk: { chars: 700_000, exceeded: true, messageCount: 100, threshold: 600_000 },
	}));
	expect(output).toContain("<b>Transcript risk</b>");
	expect(output).toContain(">= 600,000 char warn budget");
	expect(output).toContain("compact soon or raise");
});

test("renderer reports a sanitized error when transcript-risk calculation failed", () => {
	const output = render(baseDetails({
		transcriptRisk: { chars: 0, error: "TypeError: bad input", exceeded: false, messageCount: 50, threshold: 600_000 },
	}));
	expect(output).toContain("<b>Transcript risk</b>");
	expect(output).toContain("risk calculation failed: TypeError: bad input");
});
