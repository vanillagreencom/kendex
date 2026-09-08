import { expect, test } from "bun:test";
import { renderQolContextUsageMessage, type QolContextUsageMessageDetails } from "../extensions/qol/context-usage.ts";

const stubTheme: any = {
	bold: (text: string) => `<b>${text}</b>`,
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

function render(details: QolContextUsageMessageDetails) {
	const styles: Array<{ color: string; text: string }> = [];
	const theme = {
		...stubTheme,
		fg(color: string, text: string): string {
			styles.push({ color, text });
			return text;
		},
	};
	const lines = renderQolContextUsageMessage({ details } as any, {} as any, theme).render(200);
	const output = lines.join("\n");
	return {
		output,
		warningTitles: styles.filter(({ color, text }) => color === "warning" && text.startsWith("<b>") && output.includes(text)).length,
	};
}

const renderRows = [
	{
		name: "absent transcript risk",
		risk: undefined,
		observe: ({ output, warningTitles }: ReturnType<typeof render>) => ({ warningTitles, threshold: output.includes("600,000") }),
		expected: { warningTitles: 0, threshold: false },
	},
	{
		name: "payload below the warning budget",
		risk: { chars: 123_456, exceeded: false, messageCount: 50, threshold: 600_000 },
		observe: ({ output, warningTitles }: ReturnType<typeof render>) => ({
			payloadChars: output.includes("123,456"),
			threshold: output.includes("/ 600,000"),
			warningTitles,
		}),
		expected: { payloadChars: true, threshold: true, warningTitles: 0 },
	},
	{
		name: "payload above the warning budget",
		risk: { chars: 700_000, exceeded: true, messageCount: 100, threshold: 600_000 },
		observe: ({ output, warningTitles }: ReturnType<typeof render>) => ({
			warningTitles,
			payloadChars: output.includes("700,000"),
			threshold: output.includes(">= 600,000"),
			setting: output.includes("compaction.transcriptRiskWarnChars"),
		}),
		expected: { warningTitles: 1, payloadChars: true, threshold: true, setting: true },
	},
	{
		name: "serializer error stays on one line",
		risk: { chars: 0, error: "TypeError:\nbad input", exceeded: false, messageCount: 50, threshold: 600_000 },
		observe: ({ output, warningTitles }: ReturnType<typeof render>) => ({
			warningTitles,
			errorDetail: output.includes("TypeError: bad input"),
			multilineError: output.includes("TypeError:\nbad input"),
		}),
		expected: { warningTitles: 1, errorDetail: true, multilineError: false },
	},
];

for (const row of renderRows) {
	test(row.name, () => {
		const output = render(baseDetails({ transcriptRisk: row.risk }));
		expect(row.observe(output)).toStrictEqual(row.expected);
	});
}
