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

const renderRows = [
	{
		name: "absent transcript risk",
		risk: undefined,
		observe: (output: string) => ({ risk: output.includes("Transcript risk"), payload: output.includes("Transcript payload") }),
		expected: { risk: false, payload: false },
	},
	{
		name: "payload below the warning budget",
		risk: { chars: 100_000, exceeded: false, messageCount: 50, threshold: 600_000 },
		observe: (output: string) => ({ payload: output.includes("Transcript payload"), risk: /Transcript risk\b/.test(output) }),
		expected: { payload: true, risk: false },
	},
	{
		name: "payload above the warning budget",
		risk: { chars: 700_000, exceeded: true, messageCount: 100, threshold: 600_000 },
		observe: (output: string) => ({
			boldWarning: output.includes("<b>Transcript risk</b>"),
			budget: output.includes(">= 600,000 char warn budget"),
			advice: output.includes("compact soon or raise"),
		}),
		expected: { boldWarning: true, budget: true, advice: true },
	},
	{
		name: "serializer error stays on one line",
		risk: { chars: 0, error: "TypeError:\nbad input", exceeded: false, messageCount: 50, threshold: 600_000 },
		observe: (output: string) => ({
			boldWarning: output.includes("<b>Transcript risk</b>"),
			errorDetail: output.includes("risk calculation failed: TypeError: bad input"),
		}),
		expected: { boldWarning: true, errorDetail: true },
	},
];

if (renderRows.length === 0) throw new Error("Context usage renderer table is empty");

for (const row of renderRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const output = render(baseDetails({ transcriptRisk: row.risk }));
		expect(row.observe(output)).toEqual(row.expected);
	});
}
