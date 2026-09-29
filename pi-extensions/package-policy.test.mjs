import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
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
// The matrix key expands the shards a diff selects; its literal is the whole
// roster, which it runs where nothing was selected.
function shardNames(workflow) {
	const list = workflow.match(/^ {8}shard: .*'(\[.+\])'/m)?.[1];
	assert.ok(list, `no "shard:" roster literal in ${workflowPath} — the matrix reader is broken`);
	return JSON.parse(list);
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

function compareVersions(a, b) {
	const [x, y] = [a, b].map((version) => version.split(".").map(Number));
	return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
}

// The highest Pi release a Pi peer floor may name is the one
// pi-update.audit.md clears (pi-extensions/AGENTS.md): its
// `Marker` line names the marker the audit started from and the newest release
// it read, and its `Verdict:` line says `roll` or `hold`. A `roll` clears the
// new marker; a `hold` clears only the old one, and pi-update.state.json stays
// there so the next audit reads the held release again. A record that clears a
// release other than the state marker's is a missing record. A `roll` also
// names, in its `## Verdict` section, the release it tested in the target-line
// form .agents/skills/pi-update/SKILL.md § Audit record writes (version, the npm
// package at that same version, its integrity, the upstream source commit) and
// the full extension commit the run proved; a roll without them clears nothing.
// Taking the manifests, marker and record as arguments is what lets the
// controls below plant each defect.
function auditRecord(audit) {
	const [, previous, release] = audit.match(/^Marker `(\d+\.\d+\.\d+)` → `(\d+\.\d+\.\d+)`/m) ?? [];
	const verdictSection = audit.match(/^## Verdict\n([\s\S]*?)(?=^## |(?![\s\S]))/m)?.[1] ?? "";
	const verdict = verdictSection.match(/^Verdict: `(roll|hold)`/m)?.[1];
	const target = verdictSection.match(/^- Target release: `(\d+\.\d+\.\d+)`, npm `@earendil-works\/pi-coding-agent@\1` integrity `sha512-[A-Za-z0-9+/]+={0,2}`, upstream source commit `[0-9a-f]{40}`(?: \([^)\n]*\))?\.$/m)?.[1];
	const tested = verdictSection.match(/^- Tested extension commit: `([0-9a-f]{40})`/m)?.[1];
	return { previous, release, verdict, target, tested, cleared: verdict === "roll" ? release : previous };
}

function rollRefusals({ release, verdict, target, tested }) {
	if (verdict !== "roll") return [];
	const refusals = [];
	if (target !== release) refusals.push(`pi-update.audit.md: the \`roll\` for ${release} names no target release ${release} with the npm package @earendil-works/pi-coding-agent@${release}, its integrity and upstream source commit in § Verdict (found ${target ?? "none"})`);
	if (tested === undefined) refusals.push(`pi-update.audit.md: the \`roll\` for ${release} names no full tested extension commit in § Verdict`);
	return refusals;
}

// The Pi peer floors the audit gates: `>=X.Y.Z` ranges on `@earendil-works/pi-*`
// peers only. Other peers, such as pi-extension-manager's `@oh-my-pi/*` floors,
// are not Pi releases the audit reads.
function piFloors(pkgs) {
	return pkgs.flatMap(({ dir, pkg }) =>
		Object.entries(pkg.peerDependencies ?? {}).flatMap(([name, range]) => {
			const floor = name.startsWith("@earendil-works/pi-") ? range.match(/^>=(\d+\.\d+\.\d+)$/)?.[1] : undefined;
			return floor === undefined ? [] : [{ dir, name, floor }];
		}),
	);
}

function floorRefusals(pkgs, marker, audit) {
	const record = auditRecord(audit);
	const { release, verdict, cleared } = record;
	if (verdict === undefined) return [`pi-update.audit.md: the record names no verdict, \`roll\` or \`hold\``];
	const incomplete = rollRefusals(record);
	if (incomplete.length > 0) return incomplete;
	if (cleared !== marker.lastVersion) return [`pi-update.audit.md: no audit record clears ${marker.lastVersion}, the release pi-update.state.json marks audited (verdict ${verdict} for ${release} clears ${cleared})`];
	return piFloors(pkgs)
		.filter(({ floor }) => compareVersions(floor, cleared) > 0)
		.map(({ dir, name, floor }) => `${dir}: Pi peer ${name} floor ${floor} is above ${cleared}, the last release pi-update.audit.md clears (verdict ${verdict} for ${release})`);
}

const auditPath = join(root, "pi-update.audit.md");
const markerPath = join(root, "pi-update.state.json");

test("no Pi peer floor rises above the release the Pi update audit clears", () => {
	const pkgs = packages();
	assert.ok(piFloors(pkgs).length > 0, "no package declares a >=X.Y.Z @earendil-works/pi-* peer floor: the manifest reader is broken");
	assert.deepEqual(floorRefusals(pkgs, JSON.parse(readFileSync(markerPath, "utf8")), readFileSync(auditPath, "utf8")), []);
});

// One row per rule floorRefusals holds, over records built here in the shape
// .agents/skills/pi-update/SKILL.md § Audit record has the audit write, so a correct
// live record under either verdict leaves these rows standing. An accept row
// expects no refusal; a refuse row expects one naming its defect.
test("the audit record gates Pi peer floors under both verdicts", () => {
	const integrity = "sha512-m8ArJUtVcQMSe1lLE/Ei7vX/JV7O39sWmWBsXV2NOU70F0qCp8GubA24pT3LnwTmM6LL2xV80/h6sQg85n69ew==";
	// The target line's fields in § Audit record order; a row drops one, or
	// plants a wrong value in one, to plant each defect.
	const targetFields = (version, { npmVersion = version, integrityValue = integrity, commit = "f".repeat(40) } = {}) => [
		["version", `\`${version}\``],
		["npm package", `, npm \`@earendil-works/pi-coding-agent@${npmVersion}\``],
		["integrity", ` integrity \`${integrityValue}\``],
		["upstream source commit", `, upstream source commit \`${commit}\``],
	];
	const targetLine = (version, { drop, ...values } = {}) =>
		`- Target release: ${targetFields(version, values).filter(([field]) => field !== drop).map(([, text]) => text).join("")}.`;
	const testedLine = `- Tested extension commit: \`${"a".repeat(40)}\`.`;
	const fullSummary = [targetLine("0.87.1"), testedLine].join("\n");
	const record = (verdict, summary = fullSummary, trailing = "") => `# Pi package update audit\n\nMarker \`0.85.1\` → \`0.87.1\`. Sources fetched: every changelog.\n\n## Verdict\n\n${verdict}\n\n${summary}\n\n## Counts\n\n- Tested extension commit: \`${"b".repeat(40)}\`.\n${trailing}\n`;
	const pkgAt = (floor, otherPeers) => [{ dir: "planted", pkg: { peerDependencies: { "@earendil-works/pi-coding-agent": `>=${floor}`, ...otherPeers } } }];
	const floor = (version) => `planted: Pi peer @earendil-works/pi-coding-agent floor ${version} is above`;
	const rows = [
		{ name: "roll: floor at the new marker", verdict: "Verdict: `roll`.", lastVersion: "0.87.1", floor: "0.87.1", refused: undefined },
		{ name: "roll: floor above the new marker", verdict: "Verdict: `roll`.", lastVersion: "0.87.1", floor: "0.87.2", refused: `${floor("0.87.2")} 0.87.1` },
		{ name: "roll: a non-Pi peer floor is not gated", verdict: "Verdict: `roll`.", lastVersion: "0.87.1", floor: "0.87.1", otherPeers: { "@oh-my-pi/pi-coding-agent": ">=18.1.11" }, refused: undefined },
		{ name: "roll: state marker not advanced", verdict: "Verdict: `roll`.", lastVersion: "0.85.1", floor: "0.85.1", refused: "no audit record clears 0.85.1" },
		{ name: "hold: floor at the cleared old marker", verdict: "Verdict: `hold`.", lastVersion: "0.85.1", floor: "0.85.1", refused: undefined },
		{ name: "hold: floor at the held release", verdict: "Verdict: `hold`.", lastVersion: "0.85.1", floor: "0.87.1", refused: `${floor("0.87.1")} 0.85.1` },
		{ name: "hold: state marker advanced past the held release", verdict: "Verdict: `hold`.", lastVersion: "0.87.1", floor: "0.85.1", refused: "no audit record clears 0.87.1" },
		{ name: "record without a verdict", verdict: "Verdict: pending", lastVersion: "0.87.1", floor: "0.87.1", refused: "names no verdict" },
		{ name: "roll: verdict line only outside § Verdict", verdict: "", trailing: "Verdict: `roll`.", lastVersion: "0.87.1", floor: "0.87.1", refused: "names no verdict" },
		{ name: "roll: no target release", verdict: "Verdict: `roll`.", summary: testedLine, lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" },
		{ name: "roll: target release is not the marker's new release", verdict: "Verdict: `roll`.", summary: [targetLine("0.87.0"), testedLine].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "(found 0.87.0)" },
		{ name: "roll: target release only outside § Verdict", verdict: "Verdict: `roll`.", summary: testedLine, trailing: targetLine("0.87.1"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" },
		...targetFields("0.87.1").map(([field]) => ({ name: `roll: target release without its ${field}`, verdict: "Verdict: `roll`.", summary: [targetLine("0.87.1", { drop: field }), testedLine].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" })),
		{ name: "roll: target release whose npm package names another release", verdict: "Verdict: `roll`.", summary: [targetLine("0.87.1", { npmVersion: "0.87.0" }), testedLine].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" },
		{ name: "roll: target release whose integrity is not a sha512 value", verdict: "Verdict: `roll`.", summary: [targetLine("0.87.1", { integrityValue: "pending" }), testedLine].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" },
		{ name: "roll: target release with an abbreviated upstream source commit", verdict: "Verdict: `roll`.", summary: [targetLine("0.87.1", { commit: "fffffff" }), testedLine].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no target release 0.87.1" },
		{ name: "roll: no tested extension commit, one outside § Verdict ignored", verdict: "Verdict: `roll`.", summary: targetLine("0.87.1"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no full tested extension commit" },
		{ name: "roll: abbreviated tested extension commit", verdict: "Verdict: `roll`.", summary: [targetLine("0.87.1"), "- Tested extension commit: `aaaaaaaa`."].join("\n"), lastVersion: "0.87.1", floor: "0.87.1", refused: "names no full tested extension commit" },
		{ name: "hold: needs no target release or tested commit", verdict: "Verdict: `hold`.", summary: "", lastVersion: "0.85.1", floor: "0.85.1", refused: undefined },
	];
	for (const row of rows) {
		const refusals = floorRefusals(pkgAt(row.floor, row.otherPeers), { lastVersion: row.lastVersion }, record(row.verdict, row.summary, row.trailing));
		if (row.refused === undefined) {
			assert.deepEqual(refusals, [], row.name);
			continue;
		}
		assert.equal(refusals.length, 1, `${row.name}: ${JSON.stringify(refusals)}`);
		assert.ok(refusals[0].includes(row.refused), `${row.name}: ${refusals[0]}`);
	}
});

// Each helper is vendored into several packages under `scripts/`, because a
// published package cannot import another's source. A copy edited alone would
// give one package a different rule, so every copy must match.
for (const helper of ["append-system.mjs", "lane-retention.ts"]) {
	test(`vendored ${helper} helpers stay identical`, () => {
		const hashes = [];
		for (const { dir } of packages()) {
			const script = join(root, dir, "scripts", helper);
			if (!existsSync(script)) continue;
			hashes.push([dir, createHash("sha256").update(readFileSync(script)).digest("hex")]);
		}
		assert.ok(hashes.length > 1, `expected more than one ${helper} copy; found ${JSON.stringify(hashes)}`);
		assert.equal(new Set(hashes.map(([, hash]) => hash)).size, 1, `${helper} helpers differ: ${JSON.stringify(hashes)}`);
	});
}

// The settings reader every package vendors: one `package-config.ts` per
// package, the same bytes in each. Taking the copies as an argument is what lets
// the control below plant each defect instead of asserting against a list.
function vendoredReaderCopies() {
	return packages().map(({ dir }) => [dir, tsFiles(join(root, dir)).filter((file) => basename(file) === "package-config.ts").map((file) => readFileSync(file))]);
}

function vendoredReaderRefusals(copies) {
	const refusals = copies.filter(([, files]) => files.length !== 1).map(([dir, files]) => `${dir}: carries ${files.length} package-config.ts copies, not 1`);
	const hashes = Object.fromEntries(copies.flatMap(([dir, files]) => files.map((content) => [dir, createHash("sha256").update(content).digest("hex")])));
	if (new Set(Object.values(hashes)).size > 1) refusals.push(`package-config.ts copies differ: ${JSON.stringify(hashes)}`);
	return refusals;
}

test("every package vendors one identical package-config.ts", () => {
	const copies = vendoredReaderCopies();
	assert.ok(copies.length > 0, "no packages found: the package reader is broken");
	assert.deepEqual(vendoredReaderRefusals(copies), []);
});

// Must-fail control for the reader above: with every copy equal, a reader that
// stopped comparing would return the same empty list as the correct one.
test("a missing or diverged package-config.ts is reported", () => {
	const copies = vendoredReaderCopies();
	assert.deepEqual(vendoredReaderRefusals(copies), [], "precondition: the real tree vendors one identical copy per package");
	const [planted] = copies[0];
	const without = copies.map(([dir, files]) => [dir, dir === planted ? [] : files]);
	assert.deepEqual(vendoredReaderRefusals(without), [`${planted}: carries 0 package-config.ts copies, not 1`]);
	const diverged = copies.map(([dir, files]) => [dir, dir === planted ? [Buffer.concat([files[0], Buffer.from("\n")])] : files]);
	const refusals = vendoredReaderRefusals(diverged);
	assert.equal(refusals.length, 1, JSON.stringify(refusals));
	assert.ok(refusals[0].startsWith("package-config.ts copies differ:"), refusals[0]);
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

function suiteCounts() {
	return packages().map(({ dir }) => [dir, suiteFiles(join(root, dir)).length]);
}

// Every package must carry a matching file under `tests/`, `test/`, or
// `__tests__/`. Taking the counts as an argument lets the control below run
// this reader over a mutated tree instead of asserting against another list.
function packagesWithoutSuites(counts) {
	return counts.filter(([, files]) => files === 0).map(([dir]) => `${dir}: carries no test file`);
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
		packagesWithoutSuites(counts),
		[],
		"a Pi package carries no test file",
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

// Must-fail control for the reader above: with every package covered, a reader
// that stopped looking would return the same empty list as the correct reader.
test("a package with no test file is reported", () => {
	const counts = suiteCounts();
	assert.deepEqual(packagesWithoutSuites(counts), [], "precondition: every real package carries a suite");

	const stripped = counts.find(([, files]) => files > 0);
	assert.ok(stripped, "no covered package to strip — this control no longer mutates the tree it reads");
	assert.deepEqual(
		packagesWithoutSuites(counts.map(([dir, files]) => [dir, dir === stripped[0] ? 0 : files])),
		[`${stripped[0]}: carries no test file`],
	);
});
