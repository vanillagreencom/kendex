import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const root = new URL(".", import.meta.url).pathname;

function packages() {
	return readdirSync(root, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => ({ dir: entry.name, packagePath: join(root, entry.name, "package.json") }))
		.filter((entry) => existsSync(entry.packagePath))
		.map((entry) => ({ ...entry, pkg: JSON.parse(readFileSync(entry.packagePath, "utf8")) }));
}

const workflowPath = join(root, "..", ".github", "workflows", "skill-tests.yml");

// The shards `strategy.matrix` actually runs, and the `if:` values a
// per-package suite step may carry to run on one. A step conditioned on a name
// the matrix does not carry — a typo, or a shard since renamed — is skipped on
// every run, which looks identical to a step that runs and passes. Deriving
// these rather than pinning one shard's literal is what keeps a shard split
// from silently retiring a suite, and keeps the teeth: an unknown name fails.
function shardNames(workflow) {
	const list = workflow.match(/^ {8}shard: \[(.+)\]$/m)?.[1];
	assert.ok(list, `no "shard: [...]" matrix list in ${workflowPath} — the matrix reader is broken`);
	return list.split(",").map((name) => name.trim());
}

function shardConditions(workflow) {
	return shardNames(workflow).map((name) => `matrix.shard == '${name}'`);
}

// A package's CI entry point is `test:ci` when it declares one and `test`
// otherwise. `test:ci` is how a package whose full `test` script cannot run on
// a runner — pi-claude-bridge's needs API keys and a live provider — states the
// subset CI does prove, so the exclusion is readable here instead of looking
// like an uncovered package.
function ciEntryPoint(pkg) {
	if (pkg.scripts?.["test:ci"]) return "npm run test:ci";
	if (pkg.scripts?.test) return "npm test";
	return undefined;
}

// Steps are list items at a fixed indent, and a block scalar's body is the
// lines indented under it — `#` lines are shell comments, not commands.
function ciSteps(workflow) {
	return workflow.split(/\n(?= {6}- )/).flatMap((block) => {
		const dir = block.match(/^ {8}working-directory: pi-extensions\/([\w.-]+)$/m)?.[1];
		if (dir === undefined) return [];
		const body = block.match(/^ {8}run: \|\n((?: {10}.*\n?)*)/m)?.[1] ?? block.match(/^ {8}run: (.+)$/m)?.[1] ?? "";
		const commands = body.split("\n").map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
		return [{ dir, condition: block.match(/^ {8}if: (.+)$/m)?.[1], commands }];
	});
}

function suiteFiles(dir) {
	return tsFiles(dir, /\.(?:ts|mts|mjs|cjs|js)$/).filter((file) => /(?:^|\/)(?:tests|test|__tests__)\//.test(file.slice(dir.length + 1)));
}

function tsFiles(dir, pattern = /\.ts$/) {
	const out = [];
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === "node_modules" || entry.name === "bundle") continue;
		const path = join(dir, entry.name);
		if (entry.isDirectory()) out.push(...tsFiles(path, pattern));
		else if (entry.isFile() && pattern.test(entry.name)) out.push(path);
	}
	return out;
}

test("Pi package manifests follow the Pi 0.75 package policy", () => {
	for (const { dir, packagePath, pkg } of packages()) {
		assert.equal(pkg.engines?.node, ">=22.19.0", `${dir}: declare Pi 0.75 Node baseline`);
		assert.ok(pkg.keywords?.includes("pi-package"), `${dir}: keywords include pi-package`);
		for (const name of Object.keys(pkg.peerDependencies ?? {})) {
			if (!name.startsWith("@earendil-works/pi-")) continue;
			// `*` means "whatever Pi the host already provides". A package that genuinely
			// requires a newer Pi API may instead declare an explicit `>=X.Y.Z` floor so npm
			// warns when the host Pi is too old (pi-claude-bridge 2.x needs the native
			// provider API from Pi 0.81). `optional: true` is what actually keeps npm from
			// installing a second Pi core, so it is required either way.
			const range = pkg.peerDependencies[name];
			assert.ok(
				range === "*" || /^>=\d+\.\d+\.\d+$/.test(range),
				`${dir}: Pi peer ${name} is host-provided ("*") or an explicit >=X.Y.Z floor, got ${range}`,
			);
			assert.equal(pkg.peerDependenciesMeta?.[name]?.optional, true, `${dir}: Pi peer ${name} is optional to avoid auto-installing a second Pi core`);
		}
		if (pkg.pi?.appendSystem) {
			assert.equal(pkg.scripts?.postinstall, "node scripts/append-system.mjs install", `${dir}: appendSystem postinstall hook`);
			assert.equal(pkg.scripts?.preuninstall, "node scripts/append-system.mjs remove", `${dir}: appendSystem preuninstall hook`);
			assert.ok(existsSync(join(root, dir, "scripts", "append-system.mjs")), `${dir}: vendored append-system helper exists`);
			const appendSystemPath = pkg.pi.appendSystem.replace(/^\.\//, "");
			assert.ok(existsSync(join(root, dir, appendSystemPath)), `${dir}: appendSystem source file exists`);
			assert.ok(pkg.files?.includes("scripts/"), `${dir}: package files include scripts/`);
			assert.ok(pkg.files?.some((entry) => entry === appendSystemPath || entry === `${appendSystemPath}/`), `${dir}: package files include appendSystem source`);
		}
		assert.ok(packagePath.endsWith("package.json"));
	}
});

test("vendored append-system helpers stay identical", () => {
	const hashes = [];
	for (const { dir } of packages()) {
		const script = join(root, dir, "scripts", "append-system.mjs");
		if (!existsSync(script)) continue;
		hashes.push([dir, createHash("sha256").update(readFileSync(script)).digest("hex")]);
	}
	assert.ok(hashes.length > 0, "expected append-system helper copies");
	assert.equal(new Set(hashes.map(([, hash]) => hash)).size, 1, `append-system helpers differ: ${JSON.stringify(hashes)}`);
});

test("Pi extension TypeScript stays compatible with Node strip-only parsing", () => {
	const violations = [];
	for (const { dir } of packages()) {
		for (const file of tsFiles(join(root, dir))) {
			const source = readFileSync(file, "utf8");
			const relative = file.slice(root.length);
			const checks = [
				[/^\s*(export\s+)?enum\s+/m, "enum requires JavaScript emit"],
				[/^\s*(export\s+)?(namespace|module)\s+/m, "namespace/module requires JavaScript emit"],
				[/constructor\s*\([^)]*\b(private|public|protected|readonly)\s+[A-Za-z_$]/s, "constructor parameter property requires JavaScript emit"],
			];
			for (const [pattern, reason] of checks) {
				if (pattern.test(source)) violations.push(`${relative}: ${reason}`);
			}
		}
	}
	assert.deepEqual(violations, []);
});

// The variable relocates the scope holding the person's own files, which every
// package trusts without asking, so a reader that takes the raw value lets a
// checkout supply that package's settings. `crates/core/src/harness/pi.rs` is
// the rule and the pi-hooks suite proves the carrier's copy against it; this
// holds every other copy. Judged per read, not per file: one anchored reader
// must not vouch for an unanchored one beside it, which is how a bare
// `piAgentDir` survived. Comments are stripped, so leaving the name in one
// satisfies nothing. The `scripts/append-system.mjs` install helpers are
// excluded — they write only into a directory that already exists, at install
// time, and the case above holds them byte-identical.
test("every Pi extension read of PI_CODING_AGENT_DIR is root-anchored", () => {
	const VARIABLE = "process.env.PI_CODING_AGENT_DIR";
	const violations = [];
	let reads = 0;
	for (const { dir } of packages()) {
		for (const file of tsFiles(join(root, dir), /\.(?:ts|mts|mjs|cjs|js)$/)) {
			const relative = file.slice(root.length);
			if (/(?:^|\/)(?:tests|test|__tests__)\//.test(relative) || relative.endsWith("scripts/append-system.mjs")) continue;
			const source = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^[^\n]*?\/\/[^\n]*$/gm, "");
			const occurrences = source.split(VARIABLE).length - 1;
			if (occurrences === 0) continue;
			reads += occurrences;
			// Each read binds a name, and that name is what rootAnchored judges.
			const bound = [...source.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=[^;]*?process\.env\.PI_CODING_AGENT_DIR[^;]*?;/g)].map(([, name]) => name);
			if (bound.length !== occurrences) {
				violations.push(`${relative}: ${occurrences} read(s) of the variable, ${bound.length} bound to a name`);
			} else {
				violations.push(...bound.filter((name) => !source.includes(`rootAnchored(${name},`)).map((name) => `${relative}: ${name} is not judged by rootAnchored`));
			}
		}
	}
	assert.ok(reads >= 20, `expected the sweep to reach every reader, found ${reads}`);
	assert.deepEqual(violations, []);
});

test("every Pi extension carries a consumer-facing CHANGELOG.md", () => {
	for (const { dir } of packages()) {
		const changelogPath = join(root, dir, "CHANGELOG.md");
		assert.ok(existsSync(changelogPath), `${dir}: CHANGELOG.md is the channel for critical developer information to consumers and vendoring repos — create it (AGENTS.md § Rules)`);
		const changelog = readFileSync(changelogPath, "utf8");
		assert.ok(/^## Consumer-impacting changes$/m.test(changelog), `${dir}: CHANGELOG.md leads with a "## Consumer-impacting changes" section`);
		const version = JSON.parse(readFileSync(join(root, dir, "package.json"), "utf8")).version;
		assert.ok(changelog.split("\n").some((line) => line.trimEnd() === `### ${version}`), `${dir}: CHANGELOG.md has a "### ${version}" entry for the current package.json version — record consumer-impacting changes with the version bump that ships them`);
	}
});

function suiteCounts() {
	return packages().map(({ dir }) => [dir, suiteFiles(join(root, dir)).length]);
}

// A package carrying no file `suiteFiles` matches used to drop out of the
// wiring gate before any of its assertions ran: no suite means no entry point
// to demand and nothing for a CI step to invoke, so shipping a package untested
// looked exactly like shipping one covered. Naming them here is what turns that
// state into a declaration a reviewer reads rather than an absence nothing
// reports. That reader takes a `tests/`, `test/` or `__tests__/` directory at
// any depth, so pi-extension-manager's `test/` and pi-questions' and
// pi-tool-renderer's `extensions/__tests__/` all count. What is counted is
// those files, not cases in them: a package whose test directory holds only
// fixtures reads as covered.
//
// pi-prompt-stash: the stash behaviour — filterItems, previewText, loadItems,
// saveItems, stashPrompt, safeFileName — sits unexported inside
// `extensions/prompt-stash.ts`, which exports only its default entry point, so
// a suite cannot reach it behind the editor shortcut and the pi-tui popup. The
// two leaf modules beside it are importable and simply uncovered:
// `extensions/settings.ts` is byte-identical to the copies pi-questions and
// pi-task-panel vendor, and no suite in this tree imports any of the three —
// pi-codex-minimal-tools/tests/settings.test.ts covers its own `src/settings.ts`,
// a different file that happens to export a same-named recordProjectTrust
// (KEN-1016). Nothing reds when that reason expires: direction three below
// fires only once the package gains tests, not when it becomes testable, so
// exporting one of those functions tomorrow leaves the entry standing. It is
// reviewed on this comment, not held by the gate.
const NO_SUITE = ["pi-prompt-stash"];

// Every direction the declaration can drift from the tree, kept separate
// because the remedies differ: add a suite, drop a stale entry, or correct a
// name the tree no longer has. Collapsing the last two — as this reader first
// did — makes a renamed or deleted package report as one that gained tests, a
// claim about a directory that is not there; `crates/core/src/pi_ext/renames.rs`
// records prompt-stash -> pi-prompt-stash, so this repo has walked that path.
// Taking the per-package suite counts as an argument is what lets the control
// below run this exact reader over a mutated tree instead of asserting against
// a second literal.
function suiteDeclarationDrift(counts) {
	const known = counts.map(([dir]) => dir);
	const bare = counts.filter(([, files]) => files === 0).map(([dir]) => dir);
	return [
		...bare.filter((dir) => !NO_SUITE.includes(dir)).map((dir) => `${dir}: carries no test file and is not declared in NO_SUITE`),
		...NO_SUITE.filter((dir) => !known.includes(dir)).map((dir) => `${dir}: declared in NO_SUITE but is not a package directory — the entry is stale`),
		...NO_SUITE.filter((dir) => known.includes(dir) && !bare.includes(dir)).map((dir) => `${dir}: declared in NO_SUITE but carries test files — drop the declaration`),
	];
}

// Packages whose declared CI entry point no enabled step invokes. Taking the
// workflow source as an argument is what lets the control below run this exact
// reader over a mutated copy instead of asserting against a second literal.
function unrunPackages(workflow) {
	const steps = ciSteps(workflow);
	const shards = shardConditions(workflow);
	return packages().flatMap(({ dir, pkg }) => {
		const invocation = ciEntryPoint(pkg);
		if (invocation === undefined) return [];
		const runs = steps.some((step) => step.dir === dir && shards.includes(step.condition) && step.commands.includes(invocation));
		return runs ? [] : [`${dir}: no step on a shard the matrix runs invokes \`${invocation}\``];
	});
}

test("every Pi extension suite runs in CI under the package's own test script", () => {
	const workflow = readFileSync(workflowPath, "utf8");
	const steps = ciSteps(workflow);
	const dirs = packages().map(({ dir }) => dir);
	const counts = suiteCounts();
	const bearing = counts.filter(([, files]) => files > 0).map(([dir]) => dir);
	// Every side is derived from the tree and the workflow, so a reader that
	// matched nothing would pass this case vacuously — which is the gap it
	// exists to close. Floor each reader first; a zero here means the reader is
	// broken, not that the repo is empty. `ciEntryPoint` needs no floor of its
	// own: a reader that found no entry point fails the next assertion.
	assert.ok(steps.length > 0, `no per-package steps found in ${workflowPath} — the workflow reader is broken`);
	assert.ok(bearing.length > 0, "no package carries test files — the suite-file walker is broken");

	assert.deepEqual(
		suiteDeclarationDrift(counts),
		[],
		"a Pi package carries no test file without NO_SUITE declaring it, or a NO_SUITE entry is stale",
	);

	assert.deepEqual(
		packages().filter(({ dir, pkg }) => bearing.includes(dir) && !ciEntryPoint(pkg)).map(({ dir }) => dir),
		[],
		"packages carry test files but declare no `test` script, so CI has nothing to invoke — the suite ships unrun",
	);

	// Naming the working directory only proves a step exists. What proves the
	// suite runs is the step invoking the entry point the package declares: a
	// step that builds, or runs a subset under another script name, satisfies
	// the directory and proves nothing.
	assert.deepEqual(
		unrunPackages(workflow),
		[],
		"packages declare a test entry point that no skill-tests.yml step invokes",
	);

	assert.deepEqual(
		[...new Set(steps.map(({ dir }) => dir))].filter((dir) => !dirs.includes(dir)),
		[],
		"skill-tests.yml steps name a pi-extensions directory that is not a package",
	);
});

// Must-fail control for the derivation above: nothing else in this file ties a
// step's shard name back to the matrix, so without this case the accepted set
// could widen to "any condition at all" and every assertion would stay green.
test("a step conditioned on a shard the matrix does not run is reported, not accepted", () => {
	const workflow = readFileSync(workflowPath, "utf8");
	assert.deepEqual(unrunPackages(workflow), [], "precondition: the real workflow wires every package");
	const typo = workflow.replaceAll("matrix.shard == 'pi-claude-bridge'", "matrix.shard == 'pi-claude-brige'");
	assert.notEqual(typo, workflow, "the mutation matched nothing — this control no longer mutates the step it names");
	assert.deepEqual(unrunPackages(typo), ["pi-claude-bridge: no step on a shard the matrix runs invokes `npm run test:ci`"]);
});

// Must-fail control for the declaration above: with every package in the tree
// either covered or declared, the drift reader returns the same empty list a
// reader that had stopped looking would, so each direction it reports is
// mutated here.
test("a package with no test file is reported unless NO_SUITE declares it", () => {
	const counts = suiteCounts();
	assert.deepEqual(suiteDeclarationDrift(counts), [], "precondition: the real tree matches NO_SUITE");

	const stripped = counts.find(([dir, files]) => files > 0 && !NO_SUITE.includes(dir));
	assert.ok(stripped, "no covered package to strip — this control no longer mutates the tree it reads");
	assert.deepEqual(
		suiteDeclarationDrift(counts.map(([dir, files]) => [dir, dir === stripped[0] ? 0 : files])),
		[`${stripped[0]}: carries no test file and is not declared in NO_SUITE`],
	);

	assert.ok(NO_SUITE.length > 0, "NO_SUITE is empty — the two declaration directions below mutate nothing");
	assert.deepEqual(
		suiteDeclarationDrift(counts.map(([dir, files]) => [dir, NO_SUITE.includes(dir) ? 1 : files])),
		NO_SUITE.map((dir) => `${dir}: declared in NO_SUITE but carries test files — drop the declaration`),
	);
	assert.deepEqual(
		suiteDeclarationDrift(counts.filter(([dir]) => !NO_SUITE.includes(dir))),
		NO_SUITE.map((dir) => `${dir}: declared in NO_SUITE but is not a package directory — the entry is stale`),
	);
});
