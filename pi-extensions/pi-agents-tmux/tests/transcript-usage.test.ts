// Usage read off a transcript for each wire shape the bridge emits, and
// the reasoning-token column through the formatters and the sum.

import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { formatUsageStats, formatUsageStatsForDashboard, parseTranscriptUsage } from "../extensions/subagent/format.js";
import { usageSum } from "../extensions/subagent/task-records.js";
import { normalizeUsageStats } from "../extensions/subagent/tasks.js";
import { ICONS } from "../extensions/subagent/types.js";
import { ABSENT, cleanupTempRuntimes, record, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const bridge = JSON.stringify({ ts: "2026-05-14T05:00:00.000Z", event: { type: "event", event: "message_end", data: { message: { role: "assistant", content: [{ type: "text", text: "Bridge summary" }], usage: { input: 2, output: 3, reasoning: 5, cacheRead: 4, cacheWrite: 5, totalTokens: 9 }, model: "bridge-model" } } } });
const nested = JSON.stringify({ ts: "2026-05-14T05:01:00.000Z", event: { event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Nested summary" }], usage: { input: 7, output: 11, reasoning_tokens: 7, cacheRead: 13, cacheWrite: 17, totalTokens: 31 }, model: "nested-model" } } } });
const rawBridge = JSON.stringify({ ts: "2026-05-14T05:02:00.000Z", type: "event", event: "message_end", data: { message: { role: "assistant", content: [{ type: "text", text: "Raw bridge summary" }], usage: { input: 19, output: 23, output_tokens_details: { reasoning_tokens: 11 }, cacheRead: 29, cacheWrite: 31, totalTokens: 102 }, model: "raw-bridge-model" } } });
const agentStart = JSON.stringify({ ts: "2026-05-14T05:00:00.000Z", event: { type: "agent_start", agent: "reviewer-test", model: "openai-codex/gpt-6-astra:xhigh" } });
const modelless = JSON.stringify({ ts: "2026-05-14T05:01:00.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Done" }], usage: { input: 2, output: 3, cacheRead: 4, cacheWrite: 5, totalTokens: 14 } } } });
const snakeCase = JSON.stringify({ event: { type: "message_end", message: { role: "assistant", content: [], usage: { input_tokens: 1, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4, cost: { input: 0.5, output: 0.25 } } } } });
const partial = (input: number, output: number) => JSON.stringify({ event: { type: "message_update", message: { role: "assistant", content: [], usage: { input, output } } } });

function compact(result: Awaited<ReturnType<typeof parseTranscriptUsage>>): string {
	if (!result) return ABSENT;
	const u = result.usage;
	return `model=${result.model ?? ABSENT} in=${u.input} out=${u.output} reasoning=${u.reasoning} read=${u.cacheRead} write=${u.cacheWrite} cost=${u.cost} turns=${u.turns}`;
}

// label | transcript lines | expect
const usageRows: Array<[string, string[], string]> = [
	["bridge envelope, camelCase reasoning", [bridge], "model=bridge-model in=2 out=3 reasoning=5 read=4 write=5 cost=0 turns=1"],
	["nested event, reasoning_tokens", [nested], "model=nested-model in=7 out=11 reasoning=7 read=13 write=17 cost=0 turns=1"],
	["raw bridge record, output_tokens_details", [rawBridge], "model=raw-bridge-model in=19 out=23 reasoning=11 read=29 write=31 cost=0 turns=1"],
	["snake_case tokens and a cost object", [snakeCase], `model=${ABSENT} in=1 out=2 reasoning=0 read=3 write=4 cost=0.75 turns=1`],
	["three shapes sum; the first model wins", [bridge, nested, rawBridge], "model=bridge-model in=28 out=37 reasoning=23 read=46 write=53 cost=0 turns=3"],
	["agent_start supplies the model the usage events omit", [agentStart, modelless], "model=openai-codex/gpt-6-astra:xhigh in=2 out=3 reasoning=0 read=4 write=5 cost=0 turns=1"],
	["only partial updates: the largest counts as one turn", [partial(3, 1), partial(5, 2), partial(4, 9)], `model=${ABSENT} in=5 out=9 reasoning=0 read=0 write=0 cost=0 turns=1`],
	["a malformed line is skipped", ["{not json", bridge], "model=bridge-model in=2 out=3 reasoning=5 read=4 write=5 cost=0 turns=1"],
	["no usage anywhere", [agentStart], ABSENT],
	["empty transcript", [], ABSENT],
];

test("usage parsed from a transcript", async () => {
	const cwd = tempRuntime();
	for (const [index, [label, lines, expect]] of usageRows.entries()) {
		const transcriptPath = join(cwd, `usage-${index}.jsonl`);
		writeFileSync(transcriptPath, lines.join("\n"));
		assert.equal(compact(await parseTranscriptUsage(transcriptPath)), expect, label);
	}
});

test("a missing transcript path reads as no usage", async () => {
	assert.equal(compact(await parseTranscriptUsage(undefined)), ABSENT);
});

const usage = { input: 1000, output: 2000, reasoning: 1500, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 1 };

// label | observe | expect
const reasoningRows: Array<[string, () => string, string]> = [
	["formatUsageStats prints the T column", () => formatUsageStats(usage), "1 turn ↑1.0k ↓2.0k T1.5k"],
	["the dashboard parts carry the T column", () => formatUsageStatsForDashboard(usage).join("|"), `${ICONS.refresh} 1|↑1.0k ↓2.0k T1.5k`],
	["normalizeUsageStats keeps reasoning", () => String(normalizeUsageStats({ reasoning: 750 })?.reasoning ?? ABSENT), "750"],
	["normalizeUsageStats with nothing set is absent", () => String(normalizeUsageStats({ input: "x" }) ?? ABSENT), ABSENT],
	["usageSum adds reasoning across records", () => String(usageSum([
		record("scout", "usage-1", "2026-05-14T05:00:00.000Z", { usage: { ...usage, reasoning: 750 } }),
		record("scout", "usage-2", "2026-05-14T05:01:00.000Z", { usage: { ...usage, reasoning: 1250 } }),
	])?.reasoning ?? ABSENT), "2000"],
];

test("reasoning tokens through the formatters and the sum", () => {
	for (const [label, observe, expect] of reasoningRows) {
		assert.equal(observe(), expect, label);
	}
});
