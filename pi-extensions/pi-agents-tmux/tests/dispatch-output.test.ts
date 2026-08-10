import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { formatPreparedParallelSection, parallelResultLimits } from "../extensions/subagent/dispatch.js";
import { prepareSingleResultForReturn } from "../extensions/subagent/runner.js";
import { recordProjectTrust } from "../extensions/subagent/settings.js";
import { DEFAULT_RESULT_MAX_BYTES, DEFAULT_RESULT_MAX_LINES, type PreparedSingleResult } from "../extensions/subagent/types.js";

function writeProjectSettings(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
}

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

test("parallel output divides total result budgets across returned agents", () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-parallel-limits-"));
	tempDirs.push(cwd);
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	try {
		assert.deepEqual(parallelResultLimits(cwd, 8), {
			maxBytes: Math.floor(DEFAULT_RESULT_MAX_BYTES / 8),
			maxLines: Math.floor(DEFAULT_RESULT_MAX_LINES / 8),
		});

		writeProjectSettings(cwd, { resultMaxBytes: 4096, resultMaxLines: 80 });
		assert.deepEqual(parallelResultLimits(cwd, 8), { maxBytes: 1024, maxLines: 40 });
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
	}
});

test("parallel result preparation writes artifacts and section surfaces them before inline output", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-parallel-artifacts-"));
	tempDirs.push(cwd);
	const runtimeRoot = join(cwd, "runtime");
	writeProjectSettings(cwd, { resultMaxBytes: 128, resultMaxLines: 3, preserveFullOutput: true });
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	try {
		const largeOutput = Array.from({ length: 80 }, (_, index) => `line-${index}-${"x".repeat(40)}`).join("\n");
		const prepared = await prepareSingleResultForReturn({
			agent: "reviewer-test",
			agentSource: "project",
			exitCode: 0,
			messages: [{ role: "assistant", content: [{ type: "text", text: largeOutput }] } as any],
			stderr: "",
			task: "review",
			taskId: "reviewer-test-1",
			transcriptPath: "/runtime/transcripts/reviewer.jsonl",
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		}, runtimeRoot, cwd, "parallel-1-reviewer-test", undefined, parallelResultLimits(cwd, 2));

		assert.ok(prepared.truncation?.truncated);
		assert.ok(prepared.fullOutputPath, "full output path is recorded");
		assert.ok(existsSync(prepared.fullOutputPath), "full output artifact is written");
		assert.equal(prepared.result.fullOutputPath, prepared.fullOutputPath);
		assert.equal(prepared.result.truncation, prepared.truncation);

		const section = formatPreparedParallelSection(prepared);
		const transcriptIndex = section.indexOf("Transcript: /runtime/transcripts/reviewer.jsonl");
		const fullOutputIndex = section.indexOf(`Full output: ${prepared.fullOutputPath}`);
		const inlineIndex = section.indexOf("line-0");
		assert.ok(transcriptIndex > 0);
		assert.ok(fullOutputIndex > transcriptIndex);
		assert.ok(inlineIndex > fullOutputIndex);
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
	}
});

test("parallel sections surface artifacts before inline output", () => {
	const prepared: PreparedSingleResult = {
		fullOutputPath: "/runtime/outputs/reviewer/full.txt",
		text: "short verdict",
		truncation: {
			content: "short verdict",
			outputBytes: 12,
			outputLines: 1,
			totalBytes: 60000,
			totalLines: 900,
			truncated: true,
		},
		result: {
			agent: "reviewer-test",
			agentSource: "project",
			exitCode: 0,
			fullOutputPath: "/runtime/outputs/reviewer/full.txt",
			messages: [],
			stderr: "",
			task: "review",
			taskId: "reviewer-test-1",
			transcriptPath: "/runtime/transcripts/reviewer.jsonl",
			truncation: {
				content: "short verdict",
				outputBytes: 12,
				outputLines: 1,
				totalBytes: 60000,
				totalLines: 900,
				truncated: true,
			},
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		},
	};

	const section = formatPreparedParallelSection(prepared);
	assert.match(section, /^## reviewer-test \(completed\)\nTask: reviewer-test-1\nTranscript: \/runtime\/transcripts\/reviewer\.jsonl\nFull output: \/runtime\/outputs\/reviewer\/full\.txt\nInline output: truncated;/);
	assert.ok(section.endsWith("short verdict"));
});
