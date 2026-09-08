import { expect, test } from "bun:test";
import {
	computeBudgetTrigger,
	isBudgetGuardCompaction,
	type BudgetTriggerInput,
} from "../extensions/qol/budget-guard.ts";

interface TriggerObservation {
	defined: boolean;
	key: string | undefined;
}

type TriggerCase = { name: string; input: BudgetTriggerInput } & (
	{ expected: TriggerObservation } | { expectedPercent: number }
);

const triggerCases: TriggerCase[] = [
	{
		name: "disabled above the percent threshold",
		input: { contextWindow: 200_000, enabled: false, percentLimit: 85, tokenLimit: -1, tokens: 195_000 },
		expected: { defined: false, key: undefined },
	},
	{
		name: "percent threshold",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 180_000 },
		expected: { defined: true, key: "percent:85:1" },
	},
	{
		name: "percent threshold numeric closeness",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 180_000 },
		expectedPercent: 90,
	},
	{
		name: "token threshold without a context window",
		input: { enabled: true, percentLimit: -1, tokenLimit: 150_000, tokens: 160_000 },
		expected: { defined: true, key: "tokens:150000:1" },
	},
	{
		name: "same bucket at 172000 tokens",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 172_000 },
		expected: { defined: true, key: "percent:85:1" },
	},
	{
		name: "same bucket at 175000 tokens",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 175_000 },
		expected: { defined: true, key: "percent:85:1" },
	},
	{
		name: "first bucket at 120000 tokens",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 50, tokenLimit: -1, tokens: 120_000 },
		expected: { defined: true, key: "percent:50:1" },
	},
	{
		name: "second bucket at 220000 tokens",
		input: { contextWindow: 200_000, enabled: true, percentLimit: 50, tokenLimit: -1, tokens: 220_000 },
		expected: { defined: true, key: "percent:50:2" },
	},
	{
		name: "zero token count",
		input: { enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 0 },
		expected: { defined: false, key: undefined },
	},
	{
		name: "non-finite token count",
		input: { enabled: true, percentLimit: 85, tokenLimit: -1, tokens: Number.NaN },
		expected: { defined: false, key: undefined },
	},
];

if (triggerCases.length === 0) throw new Error("budget trigger table is empty");

for (const row of triggerCases) {
	test(`computeBudgetTrigger: ${row.name}`, () => {
		const trigger = computeBudgetTrigger(row.input);
		if ("expectedPercent" in row) {
			expect(trigger?.percent).toBeCloseTo(row.expectedPercent, 0);
		} else {
			const observed = {
				defined: trigger !== undefined,
				key: trigger?.key,
			};
			expect(observed).toStrictEqual(row.expected);
		}
	});
}

const sentinelCases: { name: string; input: string | undefined; expected: boolean }[] = [
	{ name: "budget guard marker", input: "[QOL_BUDGET_GUARD] fired", expected: true },
	{ name: "user request", input: "user requested compaction", expected: false },
	{ name: "absent instructions", input: undefined, expected: false },
];

if (sentinelCases.length === 0) throw new Error("budget sentinel table is empty");

for (const row of sentinelCases) {
	test(`isBudgetGuardCompaction: ${row.name}`, () => {
		expect(isBudgetGuardCompaction(row.input)).toBe(row.expected);
	});
}
