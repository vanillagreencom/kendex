// The incremental transcript reader: each read folds only the bytes
// appended since the last one, an unterminated line counts once, and a
// replaced or truncated file starts over.

import assert from "node:assert/strict";
import { appendFileSync, closeSync, openSync, renameSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { TranscriptTailCache, type TranscriptSnapshot } from "../extensions/subagent/transcript-tail.js";
import { ABSENT, cleanupTempRuntimes, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const usageLine = (input: number) => JSON.stringify({ event: { type: "message_end", message: { role: "assistant", usage: { input, output: 1 } } } });
const toolLine = (name: string) => JSON.stringify({ event: { type: "tool_execution_start", toolName: name } });

function observe(snapshot: TranscriptSnapshot | undefined): string {
	if (!snapshot) return ABSENT;
	const usage = snapshot.usage ? `in=${snapshot.usage.usage.input} turns=${snapshot.usage.usage.turns}` : "usage=none";
	return `${usage} activity=${snapshot.activity ?? ABSENT}`;
}

// Overwrites bytes at the start of the file in place: same inode, and the
// size does not change until the caller appends.
function overwriteHead(filePath: string, text: string): void {
	const fd = openSync(filePath, "r+");
	try {
		writeSync(fd, text, 0);
	} finally {
		closeSync(fd);
	}
}

type Step = (filePath: string) => void;

// label | steps, each followed by one read | expected observation after each read
const tailRows: Array<[string, Step[], string[]]> = [
	[
		"an in-place edit of already-read bytes is not re-read; only the appended line counts",
		[
			(p) => writeFileSync(p, `${usageLine(2)}\n`),
			(p) => {
				overwriteHead(p, usageLine(9));
				appendFileSync(p, `${usageLine(5)}\n`);
			},
		],
		[`in=2 turns=1 activity=${ABSENT}`, `in=7 turns=2 activity=${ABSENT}`],
	],
	[
		"an unterminated last line counts now and once its newline lands",
		[
			(p) => writeFileSync(p, usageLine(2)),
			(p) => appendFileSync(p, `\n${usageLine(5)}`),
			(p) => appendFileSync(p, "\n"),
		],
		[`in=2 turns=1 activity=${ABSENT}`, `in=7 turns=2 activity=${ABSENT}`, `in=7 turns=2 activity=${ABSENT}`],
	],
	[
		"a line split across two writes counts when it completes, and its first half is not shown",
		[
			(p) => writeFileSync(p, usageLine(3).slice(0, 20)),
			(p) => appendFileSync(p, `${usageLine(3).slice(20)}\n`),
		],
		[`usage=none activity=${ABSENT}`, `in=3 turns=1 activity=${ABSENT}`],
	],
	[
		"a truncated file starts over",
		[
			(p) => writeFileSync(p, `${usageLine(5)}\n${usageLine(5)}\n`),
			(p) => writeFileSync(p, `${usageLine(1)}\n`),
		],
		[`in=10 turns=2 activity=${ABSENT}`, `in=1 turns=1 activity=${ABSENT}`],
	],
	[
		"a file replaced by rename starts over even when it grew",
		[
			(p) => writeFileSync(p, `${usageLine(5)}\n`),
			(p) => {
				writeFileSync(`${p}.next`, `${usageLine(1)}\n${usageLine(1)}\n`);
				renameSync(`${p}.next`, p);
			},
		],
		[`in=5 turns=1 activity=${ABSENT}`, `in=2 turns=2 activity=${ABSENT}`],
	],
	[
		"the latest action wins across reads",
		[
			(p) => writeFileSync(p, `${toolLine("Bash")}\n`),
			(p) => appendFileSync(p, `${toolLine("Read")}\n`),
		],
		["usage=none activity=tool: Bash", "usage=none activity=tool: Read"],
	],
	[
		"a missing file reads as no snapshot",
		[() => undefined],
		[ABSENT],
	],
];

test("transcript tail reads", async () => {
	const dir = tempRuntime();
	for (const [index, [label, steps, expected]] of tailRows.entries()) {
		const filePath = join(dir, `tail-${index}.jsonl`);
		const tails = new TranscriptTailCache();
		const observed: string[] = [];
		for (const step of steps) {
			step(filePath);
			observed.push(observe(await tails.read(filePath)));
		}
		assert.deepEqual(observed, expected, label);
	}
});

test("concurrent reads of one transcript fold its appended bytes once", async () => {
	const filePath = join(tempRuntime(), "concurrent.jsonl");
	const tails = new TranscriptTailCache();
	writeFileSync(filePath, `${usageLine(2)}\n`);
	await tails.read(filePath);
	appendFileSync(filePath, `${usageLine(5)}\n`);
	const reads = await Promise.all([tails.read(filePath), tails.read(filePath)]);
	assert.deepEqual(reads.map(observe), [`in=7 turns=2 activity=${ABSENT}`, `in=7 turns=2 activity=${ABSENT}`]);
});

test("lines that cross the read-chunk boundary all count", async () => {
	const filePath = join(tempRuntime(), "large.jsonl");
	// Each line is padded so lines straddle the reader's 1 MiB chunk edges.
	const padded = (input: number) => JSON.stringify({ pad: "x".repeat(4093), event: { type: "message_end", message: { usage: { input, output: 1 } } } });
	const lineCount = 700;
	writeFileSync(filePath, `${Array.from({ length: lineCount }, () => padded(1)).join("\n")}\n`);
	assert.equal(observe(await new TranscriptTailCache().read(filePath)), `in=${lineCount} turns=${lineCount} activity=${ABSENT}`);
});
