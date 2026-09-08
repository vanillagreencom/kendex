#!/usr/bin/env node
/**
 * Fork context-isolation test.
 *
 * A fork must not inherit its parent's Claude session.
 *
 * createBranchedSession copies persisted claude-bridge-session markers from the
 * parent into the fork pi.jsonl. The session_start handler must reject them.
 * The fork's first turn calls the SDK with
 * --resume parentClaudeId, which (same cwd) opened the parent's full Claude jsonl
 * on disk and exposed conversation past the fork point.
 *
 * The test establishes three secret words across three turns, forks at the
 * second user message (so fork inherits only word_A), and asks the fork what
 * words it knows. word_A must appear; word_B and word_C must NOT.
 *
 * Run with:
 *   FORK_TEST_MODEL=pi-claude/claude-haiku-4-5 node --import tsx --test tests/int-fork.mjs
 *   FORK_TEST_MODEL=openai-codex/gpt-6-astra:medium    node --import tsx --test tests/int-fork.mjs
 */

import { createRpcHarness } from "./lib/rpc-harness.mjs";

const MODEL = process.env.FORK_TEST_MODEL || "pi-claude/claude-haiku-4-5";
const [PROVIDER, MODEL_ID] = MODEL.split("/");
if (!PROVIDER || !MODEL_ID) {
	console.error(`invalid_model=${MODEL}\nUse provider/modelId[:thinking].`);
	process.exit(1);
}

const TIMEOUT = 240_000;

// Random per-run so the model can't memorize across runs and tests don't
// collide if multiple instances run concurrently.
const SUFFIX = Math.random().toString(36).slice(2, 6);
const WORD_A = `alpha${SUFFIX}`;
const WORD_B = `beta${SUFFIX}`;
const WORD_C = `gamma${SUFFIX}`;

const PROMPT_1 = `Remember: word_A=${WORD_A}. Reply only "ok".`;
const PROMPT_2 = `Remember: word_B=${WORD_B}. Reply only "ok".`;
const PROMPT_3 = `Remember: word_C=${WORD_C}. Reply only "ok".`;
const FORK_PROBE = `List every secret word I have asked you to remember in this conversation, separated by commas. Just the values, no labels.`;

function logStep(n, msg) {
	console.log(`step=${n}\n${msg}`);
}

function fail(msg) {
	throw new Error(msg);
}

async function main() {
	const harness = createRpcHarness({
		name: `fork-${PROVIDER.replace(/[^a-z0-9]/gi, "-")}-${MODEL_ID.replace(/[^a-z0-9]/gi, "-")}`,
		args: ["--model", MODEL],
		defaultTimeout: TIMEOUT,
	});
	const { send, promptAndWait } = harness;

	console.log(`test=int-fork\nmodel=${MODEL}`);
	console.log(`words=${JSON.stringify([WORD_A, WORD_B, WORD_C])}`);

	try {
	harness.start();
	await new Promise((r) => setTimeout(r, 2000));

	// --- Establish parent ---
	logStep(1, "Parent turn 1 (introduce word_A)");
	const t1 = await promptAndWait(PROMPT_1);
	console.log(`response=${JSON.stringify(t1.slice(0, 80))}`);

	logStep(2, "Parent turn 2 (introduce word_B)");
	const t2 = await promptAndWait(PROMPT_2);
	console.log(`response=${JSON.stringify(t2.slice(0, 80))}`);

	logStep(3, "Parent turn 3 (introduce word_C)");
	const t3 = await promptAndWait(PROMPT_3);
	console.log(`response=${JSON.stringify(t3.slice(0, 80))}`);

	// --- Fork before turn 2 ---
	logStep(4, "Listing fork-eligible user messages");
	const forkList = await send({ type: "get_fork_messages" });
	console.log(`fork_messages=${forkList.messages.length}`);
	for (const m of forkList.messages) console.log(`entry_id=${m.entryId}\n${m.text.slice(0, 60)}`);

	const targetMsg = forkList.messages.find((m) => m.text.includes(WORD_B));
	if (!targetMsg) fail(`missing_fork_word=${WORD_B}`);

	logStep(5, `Forking at message containing word_B (entryId=${targetMsg.entryId})`);
	const forkResult = await send({ type: "fork", entryId: targetMsg.entryId });
	if (forkResult.cancelled) fail("fork_cancelled=true");
	console.log(`fork_cancelled=false\n${(forkResult.text ?? "").slice(0, 60)}`);

	// --- Probe fork: must see word_A only ---
	logStep(6, "Fork probe: ask what words I taught it");
	const tFork = await promptAndWait(FORK_PROBE);
	console.log(`response=${JSON.stringify(tFork.slice(0, 200))}`);
	const lower = tFork.toLowerCase();
	const sawA = lower.includes(WORD_A);
	const sawB = lower.includes(WORD_B);
	const sawC = lower.includes(WORD_C);

	console.log(`fork_words=${JSON.stringify({ word_A: sawA, word_B: sawB, word_C: sawC })}`);

	for (const [word, seen, expected] of [[WORD_A, sawA, true], [WORD_B, sawB, false], [WORD_C, sawC, false]]) {
		if (seen !== expected) fail(`fork_word=${word} expected=${expected} actual=${seen}\n${tFork}`);
	}

	console.log(`test_exit=0\nThe fork inherited ${WORD_A} and excluded ${WORD_B} and ${WORD_C}.`);
	} finally {
		await harness.stop();
	}
}

main().catch((e) => {
	console.error(`test_exit=1\n${e.message}`);
	console.error(e.stack);
	process.exitCode = 1;
});
