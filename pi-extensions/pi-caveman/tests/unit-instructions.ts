import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

import { bridgeCavemanHookEnabled, configurationSource, instructions, recordProjectTrust, shouldClarityEscape, type Mode } from "../extensions/prompt.ts";

const SNAP_DIR = join(dirname(fileURLToPath(import.meta.url)), "__snapshots__");
const UPDATE = process.env.UPDATE_SNAPSHOTS === "1";
const MODES = ["lite", "full", "ultra", "micro"] as const;
const BOUNDARY_KEYS = ["boundaryNormalForCode", "boundaryNormalForCommits", "boundaryNormalForReviews", "boundaryNormalForExternalWrites"] as const;

let originalPiDir;
let tmpRoot;
let userDir;
let projectDir;

function writeUserConfig(extensionConfig) {
	const settings = { kendex: { extensionManager: { config: { "@vanillagreen/pi-caveman": extensionConfig } } } };
	writeFileSync(join(userDir, "settings.json"), JSON.stringify(settings, null, 2));
}

function snapshotPath(name) { return join(SNAP_DIR, `${name}.txt`); }

function compareSnapshot(name, actual) {
	const path = snapshotPath(name);
	if (UPDATE || !existsSync(path)) {
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, actual);
		return;
	}
	const expected = readFileSync(path, "utf8");
	assert.equal(actual, expected, `snapshot mismatch for ${name}\n--- actual ---\n${actual}\n--- expected ---\n${expected}`);
}

before(() => {
	tmpRoot = mkdtempSync(join(tmpdir(), "pi-caveman-test-"));
	userDir = join(tmpRoot, "agent");
	projectDir = join(tmpRoot, "project");
	mkdirSync(userDir, { recursive: true });
	mkdirSync(join(projectDir, ".pi"), { recursive: true });
	originalPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = userDir;
});

after(() => {
	if (originalPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalPiDir;
	if (tmpRoot && existsSync(tmpRoot)) rmSync(tmpRoot, { recursive: true, force: true });
});

describe("instructions() snapshot matrix", () => {
	for (const mode of MODES) {
		for (const clarity of [false, true]) {
			for (const boundariesOn of [true, false]) {
				const name = `${mode}-${clarity ? "clarity" : "clean"}-boundaries-${boundariesOn ? "on" : "off"}`;
				it(`renders ${name}`, () => {
					const config = { mode };
					for (const key of BOUNDARY_KEYS) config[key] = boundariesOn;
					writeUserConfig(config);
					const rendered = instructions(mode, projectDir, clarity);
					compareSnapshot(name, rendered);
				});
			}
		}
	}

	it("returns empty string when mode is off", () => {
		writeUserConfig({ mode: "off" });
		assert.equal(instructions("off", projectDir, false), "");
		assert.equal(instructions("off", projectDir, true), "");
	});

	it("clarity-escape branch double-anchors imperative directives (opener + closer)", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, true);
			const mustHits = rendered.match(/\bYou MUST\b/g) ?? [];
			assert.ok(mustHits.length >= 2, `${mode} clarity needs >=2 'You MUST' directives (opener + closer); found ${mustHits.length}`);
		}
	});

	it("clarity-escape branch never emits a 'Caveman resume' sentinel (labeling-leak fix)", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, true);
			assert.doesNotMatch(rendered, /Caveman resume/, `${mode} clarity must not teach the 'Caveman resume' sentinel — it leaked back as 'Caveman ask:' / 'Caveman question:' labels in live output.`);
		}
	});

	it("no clean-mode prompt teaches a 'Caveman <verb>' labeling pattern", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, false);
			assert.doesNotMatch(rendered, /Caveman resume/, `${mode} clean must not mention 'Caveman resume'`);
		}
	});

	it("lite directive includes explicit filler/hedge/article guidance", () => {
		writeUserConfig({ mode: "lite", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		const rendered = instructions("lite", projectDir, false);
		assert.match(rendered, /article/i, "lite must explicitly call out article handling");
		assert.match(rendered, /(filler|basically|essentially)/i, "lite must explicitly call out filler words");
		assert.match(rendered, /(hedge|hedging|might|i think)/i, "lite must explicitly call out hedges");
		assert.match(rendered, /complete sentence/i, "lite must keep complete sentences (distinguishes from full's fragments)");
	});

	it("every clean mode includes a Bad/Good few-shot pair", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, false);
			// lite labels its bad examples with a discriminator ('Bad (caveman shorthand...)') so plain /^Bad: / is too narrow.
			assert.match(rendered, /^Bad[ :(]/m, `${mode} clean missing Bad: example`);
			assert.match(rendered, /^Good[ :]/m, `${mode} clean missing Good: example`);
		}
	});

	it("every clean mode includes an identity-framing line", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, false);
			if (mode === "lite") {
				assert.match(rendered, /You ARE a tight professional engineer/, `lite clean must use prose-anchored identity framing (not caveman identity)`);
			} else {
				assert.match(rendered, /You ARE a smart caveman engineer/, `${mode} clean must use caveman identity framing`);
			}
		}
	});

	it("lite mode never teaches caveman shorthand patterns (=/→/fragments OK)", () => {
		writeUserConfig({ mode: "lite", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		const rendered = instructions("lite", projectDir, false);
		// Lite must not push the model toward fragments / `=` shorthand / arrows
		// the way full/ultra do — live testing showed lite leaking into bullet-
		// list fragments because it inherited caveman identity framing.
		assert.match(rendered, /complete sentences?/i, "lite must enforce complete sentences");
		assert.match(rendered, /NOT (caveman|compressed)/i, "lite must explicitly distinguish itself from caveman shorthand");
		assert.match(rendered, /NO 'X = Y'|equation shorthand/i, "lite must explicitly forbid '=' shorthand");
	});

	it("every clean mode includes the anti-markdown-header rule with concrete forbidden tokens", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const rendered = instructions(mode, projectDir, false);
			assert.match(rendered, /No markdown headers/i, `${mode} clean must include the anti-markdown rule`);
			assert.match(rendered, /`\*\*Bold\*\*`/, `${mode} clean must name **Bold** as forbidden`);
			assert.match(rendered, /`## Heading`/, `${mode} clean must name ## Heading as forbidden`);
		}
	});

	it("no rendered prompt contains a blank-line block split (bridge anchor relies on single block)", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			for (const clarity of [false, true]) {
				const rendered = instructions(mode, projectDir, clarity);
				assert.doesNotMatch(rendered, /\n\s*\n/, `${mode}${clarity ? " clarity" : ""} must be single \\n-separated block (no \\n\\n) so claude-bridge extractBlockByMarkers sees one block`);
			}
		}
	});

	it("respects customPromptSuffix when set", () => {
		writeUserConfig({ mode: "full", customPromptSuffix: "PROJECT-SUFFIX-SENTINEL" });
		const rendered = instructions("full", projectDir, false);
		assert.match(rendered, /PROJECT-SUFFIX-SENTINEL/);
	});

	it("every active mode renders imperative MUST directives in clean and clarity", () => {
		writeUserConfig({ mode: "full", boundaryNormalForCode: true, boundaryNormalForCommits: true, boundaryNormalForReviews: true, boundaryNormalForExternalWrites: true });
		for (const mode of MODES) {
			const clean = instructions(mode, projectDir, false);
			assert.match(clean, /\bMUST\b/, `${mode} clean missing MUST directive`);
			const clarity = instructions(mode, projectDir, true);
			assert.match(clarity, /\bMUST\b/, `${mode} clarity missing MUST directive`);
		}
	});

	it("every rendered prompt opens with the canonical 'You MUST respond in caveman' anchor", () => {
		writeUserConfig({ mode: "full" });
		for (const mode of MODES) {
			for (const clarity of [false, true]) {
				const rendered = instructions(mode, projectDir, clarity);
				assert.match(rendered, /^You MUST respond in caveman /, `${mode}${clarity ? " clarity" : ""} opener mismatch`);
			}
		}
	});
});

describe("configurationSource() and bridgeCavemanHookEnabled()", () => {
	it("returns source='default' when no settings file declares mode", () => {
		writeFileSync(join(userDir, "settings.json"), "{}");
		const src = configurationSource(projectDir);
		assert.equal(src.source, "default");
		assert.equal(src.path, undefined);
	});

	it("returns source='user' when only user settings declares mode", () => {
		writeUserConfig({ mode: "full" });
		const src = configurationSource(projectDir);
		assert.equal(src.source, "user");
		assert.equal(src.path, join(userDir, "settings.json"));
	});

	it("returns source='project' when project overrides user", () => {
		writeUserConfig({ mode: "full" });
		const projectSettings = { kendex: { extensionManager: { config: { "@vanillagreen/pi-caveman": { mode: "lite" } } } } };
		writeFileSync(join(projectDir, ".pi", "settings.json"), JSON.stringify(projectSettings));
		recordProjectTrust({ cwd: projectDir, isProjectTrusted: () => true });
		const src = configurationSource(projectDir);
		assert.equal(src.source, "project");
		assert.equal(src.path, join(projectDir, ".pi", "settings.json"));
	});

	it("reads bridge includeCavemanHook from manager config", () => {
		const settings = {
			kendex: {
				extensionManager: {
					config: {
						"@vanillagreen/pi-caveman": { mode: "full" },
						"@vanillagreen/pi-claude-bridge": { includeCavemanHook: true },
					},
				},
			},
		};
		writeFileSync(join(userDir, "settings.json"), JSON.stringify(settings));
		assert.equal(bridgeCavemanHookEnabled(projectDir), true);
	});

	it("returns undefined when bridge config is absent", () => {
		writeUserConfig({ mode: "full" });
		assert.equal(bridgeCavemanHookEnabled(projectDir), undefined);
	});

	// Reset between describe blocks so the clarity-escape phrase tests below
	// do not see this block's last writeUserConfig.
	after(() => {
		writeFileSync(join(userDir, "settings.json"), "{}");
		writeFileSync(join(projectDir, ".pi", "settings.json"), "{}");
	});
});

describe("shouldClarityEscape() — narrowed to irreversible destructive ops only", () => {
	// Hard escape fires only for explicit destructive shell/SQL/git patterns +
	// the literal words `destructive` / `irreversible`. Soft signals
	// (security/confused/clarify/ambiguous) used to live here and produced
	// false escapes on routine technical turns; they are now handled by the
	// inline auto-clarity rule (model judgment), not by hard prompt injection.
	const shouldMatch = [
		"this would force-push and rewrite history",
		"DROP TABLE users",
		"rm -rf the build dir",
		"git reset --hard origin/main",
		"git push --force origin main",
		"that's a destructive operation",
		"this is an irreversible migration",
	];
	// Verbatim user prompts from the live session that previously tripped the
	// regex; regression-tested so they stay quiet.
	const shouldNotMatch = [
		"refactor the parser to use the new API",
		"add a unit test for the queue",
		"format the table output",
		"please confirm the version bumped",
		"delete the old log entries",
		"please review for security vulnerabilities",
		"is this a credential exposure?",
		"can you clarify the trade-off",
		"I'm confused about the data flow",
		"the spec is ambiguous",
		"Can you explain to me more about what 507 is about? We dont need to measure performance on non consumer surfaces (dev dashboard, etc.) so i'm confused by 1) what this issue is and 2) what the questions are about",
		"I want to audit our code, benchmarking, performance checks, etc. for anything that is unneccisarily measuring non consumer surfaces specifically.",
		"What is --secondary-window about? At some point we will have real secondary windows that are consumer surfaces (for example a chart extracted into its own window) - so does that framing change anything?",
		"Yes.",
	];
	for (const phrase of shouldMatch) {
		it(`MATCHES: ${phrase}`, () => {
			assert.equal(shouldClarityEscape(phrase), true);
		});
	}
	for (const phrase of shouldNotMatch) {
		it(`SKIPS: ${phrase}`, () => {
			assert.equal(shouldClarityEscape(phrase), false);
		});
	}
});
