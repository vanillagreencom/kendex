// A summary whose generation stopped at the token cap is incomplete even when
// it carries text. Pi's own compaction and branch-summary generators reject
// that response; the QOL summarizer is the common path behind the compaction,
// chunk/reduce and branch consumers, so the rejection lives there.

import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { generateQolSummary } from "../extensions/qol/compaction.ts";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-length-stop-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
});

afterEach(() => {
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	if (originalHome === undefined) delete process.env.HOME;
	else process.env.HOME = originalHome;
	// Restore the preload stub so later files still get a complete summary.
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => ({
			content: [{ text: "stubbed summary text", type: "text" }],
			stopReason: "end_turn",
		}),
	}));
});

function makeCtx(): any {
	const model = { contextWindow: 200_000, id: "test-model", provider: "test" };
	return {
		cwd: workdir,
		hasUI: false,
		model,
		modelRegistry: {
			find: () => model,
			getApiKeyAndHeaders: async () => ({ apiKey: "k", headers: {}, ok: true }),
		},
	};
}

function stubComplete(stopReason: string): void {
	mock.module("@earendil-works/pi-ai", () => ({
		complete: async () => ({
			content: [{ text: "## Goal\nPartial summary that ran out of", type: "text" }],
			stopReason,
		}),
	}));
}

const rows: Array<{ stopReason: string; accepted: boolean }> = [
	{ accepted: false, stopReason: "length" },
	{ accepted: true, stopReason: "stop" },
];

for (const row of rows) {
	test(`generateQolSummary ${row.accepted ? "accepts" : "rejects"} a summary with stopReason ${row.stopReason}`, async () => {
		stubComplete(row.stopReason);
		const run = generateQolSummary(makeCtx(), { conversationText: "user: hello", purpose: "compaction" });
		if (row.accepted) {
			expect((await run).summary).toContain("Partial summary");
		} else {
			await expect(run).rejects.toThrow(/token cap/);
		}
	});
}
