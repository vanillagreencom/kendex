import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = new URL("../scripts/deep-research", import.meta.url).pathname;

function diagnostic(result) {
  assert.equal(result.status, 1);
  const parsed = JSON.parse(result.stderr.trim().split(/\r?\n/, 1)[0]);
  assert.equal(parsed.ok, false);
  assert.equal(typeof parsed.error, "string");
  assert.notEqual(parsed.error.length, 0);
  return parsed;
}

function hasProblem(result, level, key, value) {
  const problems = result.problems.filter((problem) => problem.level === level);
  const legacy = result[`${level}s`];
  assert.equal(Array.isArray(legacy), true);
  assert.equal(legacy.length, problems.length);
  assert.equal(legacy.every((message) => typeof message === "string" && message.length > 0), true);
  return problems.some((problem) => problem.key === key && problem.value === value);
}

function completeReport() {
  return [
    "# Findings: q",
    "## Research Question", "q",
    "## Executive Summary", "Summary",
    "## Key Findings", "Finding",
    "## Evidence and Sources", "- [1] Source — https://example.com",
    "## Tradeoffs / Alternatives", "Tradeoff",
    "## Recommendation / Decision Criteria", "Recommendation",
    "## Risks / Unknowns", "Risk",
    "## Revisit Conditions", "Condition",
    "## Research Metadata", "- Mode: lite",
  ].join("\n\n");
}

test("doctor reports runtime status", () => {
  const result = spawnSync(process.execPath, [script, "doctor"], { encoding: "utf8" });
  assert.equal(result.status, 0);
  const json = JSON.parse(result.stdout);
  assert.equal(json.ok, true);
  assert.equal(json.fetch, true);
});

test("help documents modes, context args, and sidecar behavior", () => {
  const result = spawnSync(process.execPath, [script, "help"], { encoding: "utf8" });
  assert.equal(result.status, 0);
  const json = JSON.parse(result.stdout);
  assert.equal(json.ok, true);
  assert.match(json.usage, /report\|json\|validate\|doctor/);
  assert.equal(json.modes.full.numResults, 100);
  assert.equal(json.modes.standard.textMaxCharacters, 10000);
  assert.ok(json.flags.includes("--query-file <path>"));
  assert.ok(json.flags.includes("--context-glob <glob>"));
  assert.match(json.sidecar, /not embedded in findings\.md/);
  assert.match(json.validate, /deterministic post-run checks/);
});

test("out-of-range num-results and text-max-characters fail with Exa limits", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-limits-"));
  const mock = join(dir, "mock.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [] }));
  const env = { ...process.env, EXA_MOCK_RESPONSE_FILE: mock };
  const tooMany = spawnSync(process.execPath, [script, "report", "q", "--num-results", "150"], { encoding: "utf8", env });
  assert.notEqual(tooMany.status, 0);
  assert.equal(diagnostic(tooMany).key, "num-results-invalid");
  assert.equal(diagnostic(tooMany).value, "150");
  const tooLong = spawnSync(process.execPath, [script, "report", "q", "--text-max-characters", "16000"], { encoding: "utf8", env });
  assert.notEqual(tooLong.status, 0);
  assert.equal(diagnostic(tooLong).key, "text-max-characters-invalid");
  assert.equal(diagnostic(tooLong).value, "16000");
});

// The template and the validator's required-section list must not drift apart:
// a report written from the template has to pass validate unmodified.
test("findings template carries every section validate requires", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-template-"));
  const template = readFileSync(new URL("../templates/findings.md", import.meta.url), "utf8");
  assert.doesNotMatch(template, /## Raw Exa Metadata|\{\{raw_json\}\}|```json/);
  const filled = template.replace(/\{\{[a-z_]+\}\}/g, "placeholder");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(raw, JSON.stringify({
    metadata: { researchMode: "standard", queryCount: 1, additionalQueries: [], additionalQueriesApplied: "none", synthesis: true },
    raw: { answer: "Answer", results: [{ url: "https://example.com" }] },
  }));

  const report = join(dir, "findings.md");
  writeFileSync(report, filled);
  const ok = spawnSync(process.execPath, [script, "validate", report, raw], { encoding: "utf8" });
  assert.deepEqual(JSON.parse(ok.stdout).errors, []);

  // Teeth: dropping a section the template supplies must be reported.
  const gutted = join(dir, "gutted.md");
  writeFileSync(gutted, filled.replace("## Risks / Unknowns", "## Unrelated Heading"));
  const caught = spawnSync(process.execPath, [script, "validate", gutted, raw], { encoding: "utf8" });
  assert.notEqual(caught.status, 0);
  assert.equal(hasProblem(JSON.parse(caught.stdout), "error", "report-section-missing", "Risks / Unknowns"), true);
});

test("invalid --timeout names the flag rather than aborting the request", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-timeout-"));
  const mock = join(dir, "mock.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [] }));
  const env = { ...process.env, EXA_MOCK_RESPONSE_FILE: mock };
  for (const bad of ["abc", "0", "1.5"]) {
    const result = spawnSync(process.execPath, [script, "report", "q", "--timeout", bad], { encoding: "utf8", env });
    assert.notEqual(result.status, 0);
    assert.equal(diagnostic(result).key, "timeout-invalid");
    assert.equal(diagnostic(result).value, bad);
  }
});

test("missing key fails with setup instructions", () => {
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  const cwd = mkdtempSync(join(tmpdir(), "deep-research-no-env-"));
  const result = spawnSync(process.execPath, [script, "report", "question"], { encoding: "utf8", env, cwd });
  assert.notEqual(result.status, 0);
  assert.equal(diagnostic(result).key, "credential-missing");
  assert.equal(diagnostic(result).value, "EXA_API_KEY");
});

test("mocked report writes findings and raw output", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  const result = spawnSync(process.execPath, [script, "report", "question", "--output", output, "--raw-output", raw], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(output, "utf8"), /## Evidence and Sources/);
  assert.match(readFileSync(output, "utf8"), /https:\/\/example\.com/);
  assert.doesNotMatch(readFileSync(output, "utf8"), /Raw Exa Metadata|```json/);
  assert.match(readFileSync(raw, "utf8"), /Answer/);
});

test("mocked report defaults raw metadata to adjacent sidecar", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-sidecar-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  const result = spawnSync(process.execPath, [script, "report", "question", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  const stdout = JSON.parse(result.stdout);
  assert.equal(stdout.rawOutput, raw);
  assert.equal(stdout.mode, "standard");
  assert.equal(existsSync(raw), true);
  assert.match(readFileSync(output, "utf8"), /Raw metadata sidecar:/);
  assert.match(readFileSync(raw, "utf8"), /"researchMode": "standard"/);
});

test("mode mapping and explicit overrides are recorded in sidecar metadata", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-mode-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [] }));
  const result = spawnSync(process.execPath, [script, "report", "question", "--mode", "lite", "--type", "deep", "--num-results", "7", "--text-max-characters", "88", "--output", output, "--raw-output", raw], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  const sidecar = JSON.parse(readFileSync(raw, "utf8"));
  assert.equal(sidecar.metadata.researchMode, "lite");
  assert.equal(sidecar.metadata.type, "deep");
  assert.equal(sidecar.metadata.numResults, 7);
  assert.equal(sidecar.metadata.textMaxCharacters, 88);
});

test("query-file @path and context-glob are accepted", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-context-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  writeFileSync(join(dir, "prompt.txt"), "Question from prompt file");
  writeFileSync(join(dir, "context-b.md"), "B context");
  writeFileSync(join(dir, "context-a.md"), "A context");
  const result = spawnSync(process.execPath, [script, "report", "--query-file", "@prompt.txt", "--context-glob", "context-*.md", "--output", output], { encoding: "utf8", cwd: dir, env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(output, "utf8"), /Question from prompt file/);
});

test("invalid mode fails clearly", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-bad-mode-"));
  const mock = join(dir, "mock.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [] }));
  const result = spawnSync(process.execPath, [script, "report", "question", "--mode", "slow"], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.notEqual(result.status, 0);
  assert.equal(diagnostic(result).key, "mode-invalid");
  assert.equal(diagnostic(result).value, "slow");
});

test("large refusal JSON is complete before exit", () => {
  const command = "x".repeat(96 * 1024);
  const result = spawnSync(process.execPath, [script, command], { encoding: "utf8" });
  const parsed = diagnostic(result);
  assert.equal(parsed.key, "command-unknown");
  assert.equal(parsed.value, command);
});

test("every command refusal keeps its stable key and value", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-refusals-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "op"), "#!/usr/bin/env bash\nexit 1\n");
  chmodSync(join(bin, "op"), 0o755);
  for (let index = 0; index < 26; index += 1) writeFileSync(join(dir, `context-${index}.md`), "context");

  const noSecrets = { ...process.env };
  delete noSecrets.EXA_API_KEY;
  delete noSecrets.EXA_MOCK_RESPONSE_FILE;

  const noFetch = join(dir, "no-fetch.mjs");
  writeFileSync(noFetch, "globalThis.fetch = undefined;\n");
  const failedFetch = join(dir, "failed-fetch.mjs");
  writeFileSync(failedFetch, "globalThis.fetch = async () => ({ ok: false, status: 503, statusText: 'unavailable', text: async () => 'unavailable' });\n");
  const invalidMock = join(dir, "invalid.json");
  writeFileSync(invalidMock, "{");

  const additionalQueries = Array.from({ length: 11 }, () => ["--additional-query", "variant"]).flat();
  const cases = [
    { args: ["report", "q", "--output"], key: "argument-value-missing", value: "--output" },
    { args: ["report", "q", "--unknown"], key: "argument-unknown", value: "--unknown" },
    { args: ["report", "q", "--context-glob", "a*b*c"], key: "context-glob-invalid", value: "a*b*c", cwd: dir },
    { args: ["report", "q", "--context-glob", "context-*.md"], key: "context-glob-limit", value: 26, cwd: dir },
    { args: ["report", "q", "--type", "unknown"], key: "type-invalid", value: "unknown" },
    { args: ["report", "q", "--format", "unknown"], key: "format-invalid", value: "unknown" },
    { args: ["report", "q", ...additionalQueries], key: "additional-query-limit", value: 11 },
    { args: ["report"], key: "query-missing", value: "query-or-file" },
    { args: ["validate"], key: "argument-missing", value: "report+raw" },
    { args: ["report", "q"], key: "secret-reference-unresolved", value: "EXA_API_KEY", env: { ...noSecrets, EXA_API_KEY: "op://vault/exa/key", PATH: `${bin}:${process.env.PATH}` } },
    { args: ["report", "q"], key: "runtime-fetch-missing", value: process.version, env: { ...noSecrets, NODE_OPTIONS: `--import=${noFetch}` } },
    { args: ["report", "q"], key: "exa-request-failed", value: 503, env: { ...noSecrets, EXA_API_KEY: "key", NODE_OPTIONS: `--import=${failedFetch}` } },
    { args: ["report", "q"], key: "unexpected-error", value: "SyntaxError", env: { ...noSecrets, EXA_MOCK_RESPONSE_FILE: invalidMock } },
  ];

  for (const row of cases) {
    const result = spawnSync(process.execPath, [script, ...row.args], { encoding: "utf8", cwd: row.cwd, env: row.env ?? noSecrets });
    const parsed = diagnostic(result);
    assert.equal(parsed.key, row.key, row.key);
    assert.equal(parsed.value, row.value, row.key);
  }
});

test("full mode aggregates multiple mock responses and dedupes URLs", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-full-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "raw.json");
  writeFileSync(mock, JSON.stringify([
    { answer: "First", results: [{ title: "A", url: "https://example.com/a" }, { title: "Dup", url: "https://example.com/dup" }] },
    { answer: "Second", results: [{ title: "Dup 2", url: "https://example.com/dup" }, { title: "B", url: "https://example.com/b" }] },
  ]));
  const result = spawnSync(process.execPath, [script, "report", "main", "--mode", "full", "--additional-query", "second", "--output", output, "--raw-output", raw], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  const stdout = JSON.parse(result.stdout);
  assert.equal(stdout.queryCount, 2);
  assert.equal(stdout.uniqueSources, 3);
  const sidecar = JSON.parse(readFileSync(raw, "utf8"));
  assert.equal(sidecar.metadata.sourceCount, 4);
  assert.equal(sidecar.metadata.uniqueSourceCount, 3);
  assert.equal(sidecar.metadata.requestCount, 2);
  assert.deepEqual(sidecar.metadata.additionalQueries, ["second"]);
  assert.equal(sidecar.metadata.additionalQueriesApplied, "local-fan-out");
  const report = readFileSync(output, "utf8");
  assert.match(report, /Mode: full/);
  assert.match(report, /Queries: 2 \(1 primary \+ 1 additional, applied via local per-query fan-out\)/);
  assert.match(report, /Additional query: second/);
  assert.doesNotMatch(report, /Dup 2/);
});

test("standard mode records additional queries as provider additionalQueries", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-addq-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  const result = spawnSync(process.execPath, [script, "report", "main", "--additional-query", "alt one", "--additional-query", "alt two", "--output", output, "--raw-output", raw], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  const stdout = JSON.parse(result.stdout);
  assert.equal(stdout.queryCount, 3);
  const sidecar = JSON.parse(readFileSync(raw, "utf8"));
  assert.equal(sidecar.metadata.queryCount, 3);
  assert.equal(sidecar.metadata.requestCount, 1);
  assert.deepEqual(sidecar.metadata.additionalQueries, ["alt one", "alt two"]);
  assert.equal(sidecar.metadata.additionalQueriesApplied, "provider-additional-queries");
  assert.match(readFileSync(output, "utf8"), /Queries: 3 \(1 primary \+ 2 additional, applied via Exa additionalQueries\)/);
});

test("structured output renders distinct summary, findings, and recommendation", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-structured-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  writeFileSync(mock, JSON.stringify({
    output: { content: { executiveSummary: "Summary text.", keyFindings: ["Finding one.", "Finding two."], recommendation: "Adopt option A." } },
    results: [{ title: "Source", url: "https://example.com" }],
  }));
  const result = spawnSync(process.execPath, [script, "report", "question", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(result.status, 0, result.stderr);
  const report = readFileSync(output, "utf8");
  assert.match(report, /## Executive Summary\n\nSummary text\./);
  assert.match(report, /## Key Findings\n\n- Finding one\.\n- Finding two\./);
  assert.match(report, /## Recommendation \/ Decision Criteria\n\nAdopt option A\./);
  assert.match(report, /Synthesis: present/);
});

test("validate passes on freshly generated report and sidecar", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-validate-ok-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "A well-supported synthesized answer.", results: [{ title: "Source", url: "https://example.com", text: "Detailed source text." }] }));
  const generate = spawnSync(process.execPath, [script, "report", "question", "--additional-query", "variant", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(generate.status, 0, generate.stderr);
  const result = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const json = JSON.parse(result.stdout);
  assert.equal(json.ok, true);
  assert.deepEqual(json.errors, []);
  assert.equal(json.synthesis, true);
  assert.equal(json.queryCount, 2);
});

test("validate ignores Markdown backticks around a report-referenced sidecar path (kendex#628)", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-validate-backtick-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "A well-supported synthesized answer.", results: [{ title: "Source", url: "https://example.com", text: "Detailed source text." }] }));
  const generate = spawnSync(process.execPath, [script, "report", "question", "--additional-query", "variant", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(generate.status, 0, generate.stderr);

  // A hand-authored report references the sidecar as Markdown inline code.
  writeFileSync(output, readFileSync(output, "utf8").replace(/- Raw metadata sidecar: .*/, "- Raw metadata sidecar: `" + raw + "`"));
  const okJson = JSON.parse(spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" }).stdout);
  assert.equal(okJson.ok, true);
  assert.equal(okJson.problems.some((problem) => problem.key === "sidecar-reference-mismatch"), false);

  // A genuinely-different (still backticked) path must still warn — the fix must not over-suppress.
  writeFileSync(output, readFileSync(output, "utf8").replace(/- Raw metadata sidecar: .*/, "- Raw metadata sidecar: `" + join(dir, "other.raw.json") + "`"));
  const mismatchJson = JSON.parse(spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" }).stdout);
  assert.equal(hasProblem(mismatchJson, "warning", "sidecar-reference-mismatch", join(dir, "other.raw.json")), true);
});

test("validate errors when standard mode lacks synthesis and flags evidence-brief lite", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-validate-synth-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(mock, JSON.stringify({ results: [{ title: "Source", url: "https://example.com", text: "Evidence only." }] }));
  const standard = spawnSync(process.execPath, [script, "report", "question", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(standard.status, 0, standard.stderr);
  const standardValidate = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(standardValidate.status, 1);
  const standardJson = JSON.parse(standardValidate.stdout);
  assert.equal(standardJson.ok, false);
  assert.equal(hasProblem(standardJson, "error", "synthesis-missing", "standard"), true);
  const lite = spawnSync(process.execPath, [script, "report", "question", "--mode", "lite", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(lite.status, 0, lite.stderr);
  const liteValidate = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(liteValidate.status, 0, liteValidate.stderr);
  const liteJson = JSON.parse(liteValidate.stdout);
  assert.equal(liteJson.ok, true);
  assert.equal(hasProblem(liteJson, "warning", "synthesis-missing", "lite"), true);
  const unknownModeSidecar = JSON.parse(readFileSync(raw, "utf8"));
  delete unknownModeSidecar.metadata.researchMode;
  writeFileSync(raw, JSON.stringify(unknownModeSidecar));
  const unknownModeValidate = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(unknownModeValidate.status, 0, unknownModeValidate.stderr);
  assert.equal(hasProblem(JSON.parse(unknownModeValidate.stdout), "warning", "synthesis-missing", null), true);
});

test("validate errors on queryCount mismatch and missing files", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-validate-bad-"));
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  const generate = spawnSync(process.execPath, [script, "report", "question", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(generate.status, 0, generate.stderr);
  const sidecar = JSON.parse(readFileSync(raw, "utf8"));
  sidecar.metadata.queryCount = 5;
  writeFileSync(raw, JSON.stringify(sidecar));
  const mismatch = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(mismatch.status, 1);
  assert.equal(hasProblem(JSON.parse(mismatch.stdout), "error", "query-count-mismatch", 5), true);
  delete sidecar.metadata.queryCount;
  delete sidecar.metadata.additionalQueriesApplied;
  writeFileSync(raw, JSON.stringify(sidecar));
  const omitted = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(omitted.status, 1);
  const omittedJson = JSON.parse(omitted.stdout);
  assert.equal(hasProblem(omittedJson, "error", "query-count-mismatch", null), true);
  assert.equal(hasProblem(omittedJson, "error", "additional-queries-applied-invalid", null), true);
  const missing = spawnSync(process.execPath, [script, "validate", join(dir, "nope.md"), join(dir, "nope.json")], { encoding: "utf8" });
  assert.equal(missing.status, 1);
  const missingJson = JSON.parse(missing.stdout);
  assert.equal(hasProblem(missingJson, "error", "report-not-found", join(dir, "nope.md")), true);
  assert.equal(hasProblem(missingJson, "error", "raw-sidecar-not-found", join(dir, "nope.json")), true);
});

test("validate warns when Key Findings duplicates the Executive Summary", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-validate-dup-"));
  const report = join(dir, "findings.md");
  const raw = join(dir, "findings.raw.json");
  const duplicated = "The same long synthesized answer repeated verbatim across sections, which indicates the report generator collapsed distinct sections into one blob of text and the reader gains nothing from the second copy of it.";
  const sections = ["# Findings: q", "## Research Question", "q", "## Executive Summary", duplicated, "## Key Findings", duplicated, "## Evidence and Sources", "- [1] Source — https://example.com", "## Tradeoffs / Alternatives", "- t", "## Recommendation / Decision Criteria", "r", "## Risks / Unknowns", "- r", "## Revisit Conditions", "- r", "## Research Metadata", "- Mode: standard"].join("\n\n");
  writeFileSync(report, sections);
  writeFileSync(raw, JSON.stringify({ metadata: { researchMode: "standard", queryCount: 1, additionalQueries: [], additionalQueriesApplied: "none", synthesis: true }, raw: { answer: duplicated, results: [{ url: "https://example.com" }] } }));
  const result = spawnSync(process.execPath, [script, "validate", report, raw], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const json = JSON.parse(result.stdout);
  assert.equal(hasProblem(json, "warning", "report-sections-duplicate", "Executive Summary+Key Findings"), true);
});

test("every validation problem keeps its stable key and value", () => {
  const validSidecar = {
    metadata: { researchMode: "lite", queryCount: 1, additionalQueries: [], additionalQueriesApplied: "none", synthesis: true },
    raw: { answer: "Answer", results: [{ url: "https://example.com" }] },
  };
  const cases = [
    { key: "report-empty", level: "error", status: 1, value: "report", report: "" },
    { key: "raw-sidecar-invalid-json", level: "error", status: 1, value: "raw", rawText: "{" },
    { key: "raw-sidecar-metadata-missing", level: "error", status: 1, value: "raw", sidecar: { raw: validSidecar.raw } },
    { key: "raw-sidecar-payload-missing", level: "error", status: 1, value: "raw", sidecar: { metadata: validSidecar.metadata } },
    { key: "additional-queries-applied-conflict", level: "error", status: 1, value: "none", sidecar: { ...validSidecar, metadata: { ...validSidecar.metadata, queryCount: 2, additionalQueries: ["variant"] } } },
    { key: "additional-queries-metadata-missing", level: "warning", status: 0, value: "raw", sidecar: { ...validSidecar, metadata: { researchMode: "lite", queryCount: 1, additionalQueriesApplied: "none", synthesis: true } } },
    { key: "synthesis-metadata-mismatch", level: "warning", status: 0, value: false, sidecar: { ...validSidecar, metadata: { ...validSidecar.metadata, synthesis: false } } },
    { key: "sources-empty", level: "warning", status: 0, value: 0, sidecar: { ...validSidecar, raw: { answer: "Answer", results: [] } } },
  ];

  for (const row of cases) {
    const dir = mkdtempSync(join(tmpdir(), `deep-research-${row.key}-`));
    const report = join(dir, "findings.md");
    const raw = join(dir, "findings.raw.json");
    writeFileSync(report, row.report ?? completeReport());
    writeFileSync(raw, row.rawText ?? JSON.stringify(row.sidecar ?? validSidecar));
    const result = spawnSync(process.execPath, [script, "validate", report, raw], { encoding: "utf8" });
    assert.equal(result.status, row.status, row.key);
    const expectedValue = row.value === "report" ? report : row.value === "raw" ? raw : row.value;
    assert.equal(hasProblem(JSON.parse(result.stdout), row.level, row.key, expectedValue), true, row.key);
  }
});

// The loader reads .env.local only — the .env fallback is removed — and an
// explicit process value beats a file value per key. The mock-file path is
// itself an env key read after loadEnv, so WHICH mock answered shows whose
// value won at value level, not just presence.
test("a key present only in .env is ignored; .env.local and process env keep their precedence", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-dotenv-"));
  const localMock = join(dir, "local-mock.json");
  const processMock = join(dir, "process-mock.json");
  const dotenvMock = join(dir, "dotenv-mock.json");
  for (const [path, answer] of [[localMock, "FromEnvLocal"], [processMock, "FromProcess"], [dotenvMock, "FromDotenv"]]) {
    writeFileSync(path, JSON.stringify({ answer, results: [{ title: "Source", url: "https://example.com" }] }));
  }
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;

  // .env alone supplies both a mock and a key: read, the run would succeed
  // against that mock; ignored, it stops at the missing EXA_API_KEY with no
  // network touched in either direction.
  writeFileSync(join(dir, ".env"), `EXA_MOCK_RESPONSE_FILE=${dotenvMock}\nEXA_API_KEY=from-dotenv\n`);
  const ignored = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
  assert.notEqual(ignored.status, 0);
  assert.equal(diagnostic(ignored).key, "credential-missing");
  assert.equal(diagnostic(ignored).value, "EXA_API_KEY");

  // .env.local supplies the value when the process does not carry the key.
  const localOut = join(dir, "local.md");
  writeFileSync(join(dir, ".env.local"), `EXA_MOCK_RESPONSE_FILE=${localMock}\n`);
  const fromLocal = spawnSync(process.execPath, [script, "report", "q", "--output", localOut], { encoding: "utf8", env, cwd: dir });
  assert.equal(fromLocal.status, 0, fromLocal.stderr);
  assert.match(readFileSync(localOut, "utf8"), /FromEnvLocal/);

  // An explicit process value beats the .env.local assignment for the same key.
  const processOut = join(dir, "process.md");
  const fromProcess = spawnSync(process.execPath, [script, "report", "q", "--output", processOut], {
    encoding: "utf8",
    env: { ...env, EXA_MOCK_RESPONSE_FILE: processMock },
    cwd: dir,
  });
  assert.equal(fromProcess.status, 0, fromProcess.stderr);
  assert.match(readFileSync(processOut, "utf8"), /FromProcess/);

  // A SET-but-EMPTY process value is a real assignment and still wins:
  // the emptied mock path disables the mock entirely, so the run stops at
  // the missing EXA_API_KEY instead of reading the .env.local mock.
  const emptied = spawnSync(process.execPath, [script, "report", "q"], {
    encoding: "utf8",
    env: { ...env, EXA_MOCK_RESPONSE_FILE: "" },
    cwd: dir,
  });
  assert.notEqual(emptied.status, 0);
  assert.equal(diagnostic(emptied).key, "credential-missing");
  assert.equal(diagnostic(emptied).value, "EXA_API_KEY");

  // Within the file itself, dotenv last-wins: a repeated key's LATER line
  // replaces the earlier one — the first assignment must not block its own
  // reassignment the way a pre-existing process value does.
  const repeatedOut = join(dir, "repeated.md");
  writeFileSync(join(dir, ".env.local"), `EXA_MOCK_RESPONSE_FILE=${dotenvMock}\nEXA_MOCK_RESPONSE_FILE=${localMock}\n`);
  const repeated = spawnSync(process.execPath, [script, "report", "q", "--output", repeatedOut], { encoding: "utf8", env, cwd: dir });
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.match(readFileSync(repeatedOut, "utf8"), /FromEnvLocal/);
});

// KENDEX_ENV_FILE is the one key this loader reads out of
// kendex.settings.toml, and it decides WHICH private file is read. The app
// writes that key when a person names a private file, so the two sides
// meet here: a value the app wrote, single-quoted, has to come back out
// byte for byte, and a path that could reach outside the project has to
// stop the run rather than be opened.
test("KENDEX_ENV_FILE names the private env file, and a quoted value reads back literally", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-envfile-"));
  const chosenMock = join(dir, "chosen-mock.json");
  const localMock = join(dir, "local-mock.json");
  for (const [path, answer] of [[chosenMock, "FromChosen"], [localMock, "FromEnvLocal"]]) {
    writeFileSync(path, JSON.stringify({ answer, results: [{ title: "Source", url: "https://example.com" }] }));
  }
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;

  // The default file is still the default: a project naming nothing reads
  // .env.local exactly as it always has.
  writeFileSync(join(dir, ".env.local"), `EXA_MOCK_RESPONSE_FILE=${localMock}\nEXA_API_KEY='k'\n`);
  const local = join(dir, "local.md");
  const byDefault = spawnSync(process.execPath, [script, "report", "q", "--output", local], { encoding: "utf8", env, cwd: dir });
  assert.equal(byDefault.status, 0, byDefault.stderr);
  assert.match(readFileSync(local, "utf8"), /FromEnvLocal/);

  // Named, the chosen file answers instead — and the single-quoted value
  // the app writes is stripped of exactly its quotes and nothing else.
  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = ".env.secrets"\n');
  writeFileSync(join(dir, ".env.secrets"), `EXA_MOCK_RESPONSE_FILE='${chosenMock}'\nEXA_API_KEY='k'\n`);
  const chosen = join(dir, "chosen.md");
  const byName = spawnSync(process.execPath, [script, "report", "q", "--output", chosen], { encoding: "utf8", env, cwd: dir });
  assert.equal(byName.status, 0, byName.stderr);
  assert.match(readFileSync(chosen, "utf8"), /FromChosen/);
});

// The shared shell loader resolves KENDEX_ENV_FILE from the process
// environment, then .kendex/settings.toml, then kendex.settings.toml. This
// package has to agree, or it sources a different private file from every
// other package in the same project.
test("KENDEX_ENV_FILE keeps the same precedence the shell loader gives it", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-envlayers-"));
  mkdirSync(join(dir, ".kendex"), { recursive: true });
  const mock = (name, answer) => {
    const path = join(dir, `${name}.json`);
    writeFileSync(path, JSON.stringify({ answer, results: [{ title: "Source", url: "https://example.com" }] }));
    return path;
  };
  const rootMock = mock("root", "FromRoot");
  const nestedMock = mock("nested", "FromNested");
  const processMock = mock("process", "FromProcess");
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  delete env.KENDEX_ENV_FILE;

  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = ".env.root"\n');
  writeFileSync(join(dir, ".env.root"), `EXA_MOCK_RESPONSE_FILE='${rootMock}'\nEXA_API_KEY='k'\n`);
  writeFileSync(join(dir, ".env.nested"), `EXA_MOCK_RESPONSE_FILE='${nestedMock}'\nEXA_API_KEY='k'\n`);
  writeFileSync(join(dir, ".env.chosen"), `EXA_MOCK_RESPONSE_FILE='${processMock}'\nEXA_API_KEY='k'\n`);

  const ran = (name, over = {}) => {
    const out = join(dir, `${name}.md`);
    const result = spawnSync(process.execPath, [script, "report", "q", "--output", out], {
      encoding: "utf8",
      env: { ...env, ...over },
      cwd: dir,
    });
    assert.equal(result.status, 0, result.stderr);
    return readFileSync(out, "utf8");
  };

  // The root file alone answers.
  assert.match(ran("root"), /FromRoot/);
  // .kendex/settings.toml is read after it and wins.
  writeFileSync(join(dir, ".kendex/settings.toml"), '[env]\nKENDEX_ENV_FILE = ".env.nested"\n');
  assert.match(ran("nested"), /FromNested/);
  // And the process environment outranks both.
  assert.match(ran("process", { KENDEX_ENV_FILE: ".env.chosen" }), /FromProcess/);
});

test("a settings file the shell loader would refuse stops the run", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-envdup-"));
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  delete env.KENDEX_ENV_FILE;
  // Every shape the shared shell loader refuses the whole file over. A
  // reader that took its own row out of a file the other packages reject
  // would run this package on configuration nothing else accepted.
  const rows = [
    ['[env]\nKENDEX_ENV_FILE = ".env.a"\nKENDEX_ENV_FILE = ".env.b"\n', "settings-duplicate-key"],
    // A duplicate of an UNRELATED key refuses the file just the same.
    ['[env]\nKENDEX_ENV_FILE = ".env.a"\nOTHER = "1"\nOTHER = "2"\n', "settings-duplicate-key"],
    ['[env] # the table\nKENDEX_ENV_FILE = ".env.a"\n', "settings-table-header"],
    ['[[env]]\nKENDEX_ENV_FILE = ".env.a"\n', "settings-table-header"],
    // An unrelated value outside the contract refuses it too.
    ['[env]\nKENDEX_ENV_FILE = ".env.a"\nOTHER = 900\n', "settings-value-syntax"],
    ['\ufeff[env]\nKENDEX_ENV_FILE = ".env.a"\n', "settings-byte-order-mark"],
  ];
  for (const [body, key] of rows) {
    writeFileSync(join(dir, "kendex.settings.toml"), body);
    const result = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
    assert.equal(diagnostic(result).key, key, body);
  }
  // The control: the same file without the defect is read, and the run
  // gets as far as the missing credential rather than a settings refusal.
  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = ".env.a"\nOTHER = "1"\n');
  const clean = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
  assert.equal(diagnostic(clean).key, "credential-missing");
});

test("a KENDEX_ENV_FILE that could reach outside the project stops the run", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-envpath-"));
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  for (const named of ["/etc/passwd", "../outside.env", "a/../../outside.env", "C:keys.env"]) {
    writeFileSync(join(dir, "kendex.settings.toml"), `[env]\nKENDEX_ENV_FILE = "${named}"\n`);
    const result = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
    const parsed = diagnostic(result);
    assert.equal(parsed.key, "private-env-path", named);
    assert.equal(parsed.value, "KENDEX_ENV_FILE", named);
  }
  // A value outside the settings contract is refused rather than read
  // past: the shell loader fails the whole file over one, so reading past
  // it here would have this package answer from .env.local while every
  // other package refuses to start.
  for (const line of ['KENDEX_ENV_FILE = "keys\\local.env"', "KENDEX_ENV_FILE = '.env.secrets'", "KENDEX_ENV_FILE = .env.secrets"]) {
    writeFileSync(join(dir, "kendex.settings.toml"), `[env]\n${line}\n`);
    const result = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
    assert.equal(diagnostic(result).key, "settings-value-syntax", line);
  }
});

// Spelling is only half the guarantee. A name carrying no `..` still
// reads a file anywhere at all when a directory on the way out is a link,
// and the credentials this loader is after are the whole point of the
// containment claim.
test("a KENDEX_ENV_FILE that escapes through a link stops the run", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-envlink-"));
  const outside = mkdtempSync(join(tmpdir(), "deep-research-outside-"));
  const stolen = join(outside, "stolen.env");
  const outsideMock = join(outside, "mock.json");
  writeFileSync(outsideMock, JSON.stringify({ answer: "FromOutside", results: [{ title: "S", url: "https://example.com" }] }));
  writeFileSync(stolen, `EXA_MOCK_RESPONSE_FILE=${outsideMock}\nEXA_API_KEY='k'\n`);
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;

  // A directory on the way out is a link: the name says nothing about it.
  symlinkSync(outside, join(dir, "linked"));
  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = "linked/stolen.env"\n');
  const through = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
  assert.equal(diagnostic(through).key, "private-env-outside");

  // The file ITSELF being a link is the project's own layout and still
  // loads: a git worktree links .env.local back to its main checkout so
  // every worktree shares one credential file, and refusing that would
  // stop every package in every worktree.
  const shared = join(outside, "shared.env");
  writeFileSync(shared, `EXA_MOCK_RESPONSE_FILE=${outsideMock}\nEXA_API_KEY='k'\n`);
  symlinkSync(shared, join(dir, "linked.env"));
  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = "linked.env"\n');
  const directOut = join(dir, "direct.md");
  const direct = spawnSync(process.execPath, [script, "report", "q", "--output", directOut], { encoding: "utf8", env, cwd: dir });
  assert.equal(direct.status, 0, direct.stderr);
  assert.match(readFileSync(directOut, "utf8"), /FromOutside/);

  // The default is held to the same rule rather than to a rule about
  // configured names.
  const plain = mkdtempSync(join(tmpdir(), "deep-research-envlink-default-"));
  symlinkSync(shared, join(plain, ".env.local"));
  const plainOut = join(plain, "plain.md");
  const byDefault = spawnSync(process.execPath, [script, "report", "q", "--output", plainOut], { encoding: "utf8", env, cwd: plain });
  assert.equal(byDefault.status, 0, byDefault.stderr);
  assert.match(readFileSync(plainOut, "utf8"), /FromOutside/);

  // A subdirectory is not a way out: the check refuses an escape, not
  // nesting.
  const inside = mkdtempSync(join(tmpdir(), "deep-research-envlink-inside-"));
  const insideMock = join(inside, "mock.json");
  writeFileSync(insideMock, JSON.stringify({ answer: "FromNested", results: [{ title: "S", url: "https://example.com" }] }));
  mkdirSync(join(inside, "keys"));
  writeFileSync(join(inside, "keys/private.env"), `EXA_MOCK_RESPONSE_FILE=${insideMock}\nEXA_API_KEY='k'\n`);
  writeFileSync(join(inside, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = "keys/private.env"\n');
  const nestedOut = join(inside, "nested.md");
  const nested = spawnSync(process.execPath, [script, "report", "q", "--output", nestedOut], { encoding: "utf8", env, cwd: inside });
  assert.equal(nested.status, 0, nested.stderr);
  assert.match(readFileSync(nestedOut, "utf8"), /FromNested/);
});

// A component that exists as a regular file blocks the path. Climbing
// past it would call the path contained and then read as absent, so the
// credential would silently never load and nothing would say why.
test("a KENDEX_ENV_FILE blocked by a file in its path stops the run", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-blocked-"));
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  writeFileSync(join(dir, "config"), "X=1\n");
  writeFileSync(join(dir, "kendex.settings.toml"), '[env]\nKENDEX_ENV_FILE = "config/private.env"\n');
  const result = spawnSync(process.execPath, [script, "report", "q"], { encoding: "utf8", env, cwd: dir });
  assert.equal(diagnostic(result).key, "private-env-blocked");
});

test("resolves EXA_API_KEY op:// references with op CLI", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-op-"));
  const bin = join(dir, "bin");
  const mock = join(dir, "mock.json");
  const output = join(dir, "findings.md");
  mkdirSync(bin, { recursive: true });
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [{ title: "Source", url: "https://example.com" }] }));
  writeFileSync(join(bin, "op"), "#!/usr/bin/env bash\n[ \"$1\" = read ] && [ \"$2\" = 'op://vault/exa/key' ] && { printf resolved-exa; exit 0; }\nexit 1\n");
  chmodSync(join(bin, "op"), 0o755);
  const result = spawnSync(process.execPath, [script, "report", "question", "--output", output], {
    encoding: "utf8",
    env: { ...process.env, EXA_API_KEY: "op://vault/exa/key", EXA_MOCK_RESPONSE_FILE: mock, PATH: `${bin}:${process.env.PATH}` },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(output, "utf8"), /Answer/);
});
