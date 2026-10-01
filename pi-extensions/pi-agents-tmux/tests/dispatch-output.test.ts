import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { spyOn } from "bun:test";
import { formatPreparedParallelSection, parallelResultLimits } from "../extensions/subagent/dispatch.js";
import { prepareSingleResultForReturn } from "../extensions/subagent/runner.js";
import * as runner from "../extensions/subagent/runner.js";
import { assertParallelPreparedOutput, assertProviderProducer, cleanupTempRuntimes } from "./single-agent-fixture.js";
import { importRuntimeCopy } from "./browser-fixture.js";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/subagent/package-config.js";
import { DEFAULT_RESULT_MAX_BYTES, DEFAULT_RESULT_MAX_LINES, type PreparedSingleResult } from "../extensions/subagent/types.js";

function writeProjectSettings(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});
after(cleanupTempRuntimes);

test("parallel output divides total result budgets across returned agents", () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-parallel-limits-"));
	tempDirs.push(cwd);
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	clearPackageConfigCache();
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
		clearPackageConfigCache();
	}
});

test("parallel result preparation writes artifacts and section surfaces them before inline output", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-parallel-artifacts-"));
	tempDirs.push(cwd);
	const runtimeRoot = join(cwd, "runtime");
	writeProjectSettings(cwd, { resultMaxBytes: 128, resultMaxLines: 3, preserveFullOutput: true });
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
	clearPackageConfigCache();
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
		assert.equal(readFileSync(prepared.fullOutputPath, "utf8"), largeOutput);
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
		clearPackageConfigCache();
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

for (const source of ["provider", "stderr", "completed"] as const) {
	test(`parallel preparation preserves ${source} output instead of neighbouring progress or diagnostics`, async () => {
		await assertProviderProducer(runner, source);
		await assertParallelPreparedOutput(source);
	});
	test(`control: wrong preparation precedence loses ${source} output`, async () => {
		const before = 'textOverride ?? (isError ? result.errorMessage || result.stderr || finalOutput : finalOutput)';
		const after = source === "completed"
			? 'textOverride ?? (result.errorMessage || result.stderr || finalOutput)'
			: 'textOverride ?? (finalOutput || (isError ? result.errorMessage || result.stderr : finalOutput))';
		const mutant = await importRuntimeCopy("runner.ts", before, after) as typeof runner;
		await assert.rejects(() => assertProviderProducer(mutant, source), assert.AssertionError);
		const preparation = spyOn(runner, "prepareSingleResultForReturn").mockImplementation(mutant.prepareSingleResultForReturn);
		try { await assert.rejects(() => assertParallelPreparedOutput(source), assert.AssertionError); }
		finally { preparation.mockRestore(); }
	});
}

for (const override of ["", "caller-selected diagnostic"]) {
	test(`explicit preparation override wins: ${JSON.stringify(override)}`, () => assertProviderProducer(runner, "provider", override));
}

test("control: error truncation keeps the head instead of the selected diagnostic tail", async () => {
	const mutant = await importRuntimeCopy("runner.ts", 'const direction = isError ? "tail" : "head";', 'const direction = "head";') as typeof runner;
	await assert.rejects(() => assertProviderProducer(mutant), assert.AssertionError);
});

test("control: synthesized errorMessage hides stderr behind partial output in parallel model text", async () => {
	const mutant = await importRuntimeCopy("runner.ts", 'prepared.errorMessage = output.text;', 'prepared.errorMessage = finalOutput;') as typeof runner;
	const preparation = spyOn(runner, "prepareSingleResultForReturn").mockImplementation(mutant.prepareSingleResultForReturn);
	try { await assert.rejects(() => assertParallelPreparedOutput("stderr"), assert.AssertionError); }
	finally { preparation.mockRestore(); }
});
