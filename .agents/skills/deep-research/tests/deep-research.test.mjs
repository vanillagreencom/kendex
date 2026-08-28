import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = new URL("../scripts/deep-research", import.meta.url).pathname;

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
  assert.match(tooMany.stderr, /Invalid --num-results 150.*1-100/);
  const tooLong = spawnSync(process.execPath, [script, "report", "q", "--text-max-characters", "16000"], { encoding: "utf8", env });
  assert.notEqual(tooLong.status, 0);
  assert.match(tooLong.stderr, /Invalid --text-max-characters 16000.*1-10000/);
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
  assert.ok(JSON.parse(caught.stdout).errors.some((e) => /Risks \/ Unknowns/.test(e)));
});

test("invalid --timeout names the flag rather than aborting the request", () => {
  const dir = mkdtempSync(join(tmpdir(), "deep-research-timeout-"));
  const mock = join(dir, "mock.json");
  writeFileSync(mock, JSON.stringify({ answer: "Answer", results: [] }));
  const env = { ...process.env, EXA_MOCK_RESPONSE_FILE: mock };
  for (const bad of ["abc", "0", "1.5"]) {
    const result = spawnSync(process.execPath, [script, "report", "q", "--timeout", bad], { encoding: "utf8", env });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Invalid --timeout/);
  }
});

test("missing key fails with setup instructions", () => {
  const env = { ...process.env };
  delete env.EXA_API_KEY;
  delete env.EXA_MOCK_RESPONSE_FILE;
  const cwd = mkdtempSync(join(tmpdir(), "deep-research-no-env-"));
  const result = spawnSync(process.execPath, [script, "report", "question"], { encoding: "utf8", env, cwd });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /EXA_API_KEY/);
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
  assert.match(result.stderr, /Invalid --mode slow/);
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
  assert.ok(!okJson.warnings.some((w) => w.startsWith("Report references sidecar")), `unexpected sidecar warning: ${JSON.stringify(okJson.warnings)}`);

  // A genuinely-different (still backticked) path must still warn — the fix must not over-suppress.
  writeFileSync(output, readFileSync(output, "utf8").replace(/- Raw metadata sidecar: .*/, "- Raw metadata sidecar: `" + join(dir, "other.raw.json") + "`"));
  const mismatchJson = JSON.parse(spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" }).stdout);
  assert.ok(mismatchJson.warnings.some((w) => w.startsWith("Report references sidecar")), `expected a sidecar mismatch warning: ${JSON.stringify(mismatchJson.warnings)}`);
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
  assert.ok(standardJson.errors.some((e) => /Mode standard requests server-side synthesis/.test(e)));
  const lite = spawnSync(process.execPath, [script, "report", "question", "--mode", "lite", "--output", output], { encoding: "utf8", env: { ...process.env, EXA_MOCK_RESPONSE_FILE: mock } });
  assert.equal(lite.status, 0, lite.stderr);
  const liteValidate = spawnSync(process.execPath, [script, "validate", output, raw], { encoding: "utf8" });
  assert.equal(liteValidate.status, 0, liteValidate.stderr);
  const liteJson = JSON.parse(liteValidate.stdout);
  assert.equal(liteJson.ok, true);
  assert.ok(liteJson.warnings.some((w) => /evidence brief/.test(w)));
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
  assert.ok(JSON.parse(mismatch.stdout).errors.some((e) => /queryCount is 5/.test(e)));
  const missing = spawnSync(process.execPath, [script, "validate", join(dir, "nope.md"), join(dir, "nope.json")], { encoding: "utf8" });
  assert.equal(missing.status, 1);
  const missingJson = JSON.parse(missing.stdout);
  assert.ok(missingJson.errors.some((e) => /Report not found/.test(e)));
  assert.ok(missingJson.errors.some((e) => /Raw sidecar not found/.test(e)));
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
  assert.ok(json.warnings.some((w) => /duplicates the Executive Summary/.test(w)));
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
  assert.match(ignored.stderr, /EXA_API_KEY is required/);

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
  assert.match(emptied.stderr, /EXA_API_KEY is required/);

  // Within the file itself, dotenv last-wins: a repeated key's LATER line
  // replaces the earlier one — the first assignment must not block its own
  // reassignment the way a pre-existing process value does.
  const repeatedOut = join(dir, "repeated.md");
  writeFileSync(join(dir, ".env.local"), `EXA_MOCK_RESPONSE_FILE=${dotenvMock}\nEXA_MOCK_RESPONSE_FILE=${localMock}\n`);
  const repeated = spawnSync(process.execPath, [script, "report", "q", "--output", repeatedOut], { encoding: "utf8", env, cwd: dir });
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.match(readFileSync(repeatedOut, "utf8"), /FromEnvLocal/);
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
