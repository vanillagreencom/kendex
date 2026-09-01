import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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

// The workflow's own `shard names agree with the matrix` step, lifted out and
// run over a copy of the tree. Nothing here restates what that script checks:
// it is the single implementation of the shard-name rule and these cases are
// its control, so a rule change is made there and lands here as a red case.
function shardGuardScript(workflow) {
	const block = workflow.split(/\n(?= {6}- )/).find((b) => /^ {6}- name: shard names agree with the matrix$/m.test(b));
	assert.ok(block, "the unconditional shard guard step is gone from the workflow");
	assert.ok(!/^ {8}if: /m.test(block), "the shard guard grew an `if:`, so the drift it reports can now switch it off");
	const body = block.match(/^ {8}run: \|\n((?: {10}.*\n?)*)/m)?.[1];
	assert.ok(body, "could not read the shard guard's script — the reader is broken");
	return body.replace(/^ {10}/gm, "");
}

// Reading the script happens OUTSIDE the try: an assertion in the reader is a
// broken harness, not a guard verdict, and must not come back as an exit code.
// A spawn failure is rethrown for the same reason.
function runShardGuard(workflow, shard) {
	const script = shardGuardScript(workflow);
	const dir = mkdtempSync(join(tmpdir(), "shard-guard-"));
	try {
		mkdirSync(join(dir, ".github", "workflows"), { recursive: true });
		writeFileSync(join(dir, ".github", "workflows", "skill-tests.yml"), workflow);
		execFileSync("bash", ["-c", script], { cwd: dir, env: { ...process.env, SHARD: shard }, stdio: "pipe" });
		return 0;
	} catch (error) {
		if (typeof error.status !== "number") throw error;
		return error.status;
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
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
	const bearing = packages().filter(({ dir }) => suiteFiles(join(root, dir)).length > 0).map(({ dir }) => dir);
	// Every side is derived from the tree and the workflow, so a reader that
	// matched nothing would pass this case vacuously — which is the gap it
	// exists to close. Floor each reader first; a zero here means the reader is
	// broken, not that the repo is empty. `ciEntryPoint` needs no floor of its
	// own: a reader that found no entry point fails the next assertion.
	assert.ok(steps.length > 0, `no per-package steps found in ${workflowPath} — the workflow reader is broken`);
	assert.ok(bearing.length > 0, "no package carries test files — the suite-file walker is broken");

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

// The shard-name rule itself is the workflow's `shard names agree with the
// matrix` step: it carries no `if:`, so no drift can switch it off, which a
// suite gated on one shard cannot promise. These two cases run THAT script
// against mutated copies. Delete them only alongside the step, never instead
// of it, and change the rule there rather than here.
test("the workflow's shard guard accepts every shard the matrix declares and no other", () => {
	const workflow = readFileSync(workflowPath, "utf8");
	const shards = shardNames(workflow);
	assert.ok(shards.length > 0, "no shards read from the matrix — the reader is broken");
	for (const shard of shards) {
		assert.equal(runShardGuard(workflow, shard), 0, `the guard rejected ${shard}, which the matrix declares`);
	}
	assert.notEqual(runShardGuard(workflow, "ghost"), 0, "the guard accepted a leg the matrix does not declare");
});

// Must-fail controls, one per direction the rule closes. Each asserts its
// mutation actually changed the file, so a case that stopped matching fails
// loud rather than proving nothing against an unmutated copy.
test("the workflow's shard guard reds on every direction of shard-name drift", () => {
	const workflow = readFileSync(workflowPath, "utf8");
	const cases = [
		["a step names a shard the matrix dropped", workflow.replaceAll("matrix.shard == 'rest'", "matrix.shard == 'rst'")],
		["the matrix declares a shard no step names", workflow.replace(/^( {8}shard: \[.+)\]$/m, "$1, ghost]")],
		// A control mutating the FIRST clause of a compound condition passes
		// under a reader that stops after one comparison, so it would prove
		// nothing; this one mutates the second.
		[
			"a later clause of a compound condition is typo'd",
			workflow.replace("matrix.shard == 'node' || matrix.shard == 'pi-claude-bridge'", "matrix.shard == 'node' || matrix.shard == 'pi-claude-brige'"),
		],
		["the matrix list cannot be read at all", workflow.replace(/^ {8}shard: \[.+\]$/m, "        shard: unreadable")],
		// Every case above mutates a step condition, so all of them pass under
		// a reader that takes any occurrence in the file. This one names the
		// new shard ONLY in a comment: the shard is declared, no step runs it,
		// and the leg would be green and empty unless the reader keeps `if:`
		// keys alone. The comment goes directly above the guard because that
		// is where a later author would write such an example.
		[
			"a matrix shard is named only by a comment",
			workflow
				.replace(/^( {8}shard: \[.+)\]$/m, "$1, ghost]")
				.replace("      - name: shard names agree with the matrix\n", "      # e.g. matrix.shard == 'ghost'\n      - name: shard names agree with the matrix\n"),
		],
	];
	for (const [drift, mutated] of cases) {
		assert.notEqual(mutated, workflow, `the mutation for "${drift}" matched nothing`);
		assert.notEqual(runShardGuard(mutated, "rest"), 0, `the guard stayed green when ${drift}`);
	}
});
