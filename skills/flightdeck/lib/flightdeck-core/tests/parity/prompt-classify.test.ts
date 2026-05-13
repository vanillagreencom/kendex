// Parity test: prompt-classify (bash) vs prompt-classify (TS).
// For every fixture buffer, both implementations must return the same tag.
// Fails on any unexplained diff.

import { describe, test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ISSUE_ONLY_TAGS } from "../../src/classifier/rules.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(HERE, "../fixtures/prompt-classify");
const BASH_SCRIPT = resolve(HERE, "../../../../scripts/prompt-classify.bash");
const TS_SCRIPT = resolve(HERE, "../../src/bin/prompt-classify.ts");

interface Fixture {
	name: string;
	bufferPath: string;
	expectedTag: string;
	noFooterGate: boolean;
}

function loadFixtures(): Fixture[] {
	return readdirSync(FIXTURES)
		.filter((f) => f.endsWith(".buffer"))
		.sort()
		.map((file) => {
			const base = file.slice(0, -".buffer".length);
			const metaPath = join(FIXTURES, `${base}.meta.json`);
			const meta = JSON.parse(readFileSync(metaPath, "utf8"));
			return {
				bufferPath: join(FIXTURES, file),
				expectedTag: meta.expectedTag,
				name: base,
				noFooterGate: !!meta.noFooterGate,
			};
		});
}

function runBash(fixture: Fixture): string {
	const args = ["--buffer-file", fixture.bufferPath];
	if (fixture.noFooterGate) args.push("--no-footer-gate");
	if (ISSUE_ONLY_TAGS.has(fixture.expectedTag)) args.push("--allow-missing-kind");
	const r = spawnSync(BASH_SCRIPT, args, { encoding: "utf8" });
	if (r.status !== 0) throw new Error(`bash classify exit ${r.status}: ${r.stderr}`);
	return r.stdout.trim();
}

function runTs(fixture: Fixture): string {
	const args = ["run", TS_SCRIPT, "--buffer-file", fixture.bufferPath];
	if (fixture.noFooterGate) args.push("--no-footer-gate");
	if (ISSUE_ONLY_TAGS.has(fixture.expectedTag)) args.push("--allow-missing-kind");
	const r = spawnSync("bun", args, { encoding: "utf8" });
	if (r.status !== 0) throw new Error(`ts classify exit ${r.status}: ${r.stderr}`);
	return r.stdout.trim();
}

describe("prompt-classify parity", () => {
	const fixtures = loadFixtures();
	for (const fixture of fixtures) {
		test(`${fixture.name} → ${fixture.expectedTag}`, () => {
			const bashTag = runBash(fixture);
			const tsTag = runTs(fixture);
			expect(tsTag).toBe(bashTag);
			expect(tsTag).toBe(fixture.expectedTag);
		});
	}
});
