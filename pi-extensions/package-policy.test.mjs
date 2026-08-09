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

function tsFiles(dir) {
	const out = [];
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === "node_modules" || entry.name === "bundle") continue;
		const path = join(dir, entry.name);
		if (entry.isDirectory()) out.push(...tsFiles(path));
		else if (entry.isFile() && entry.name.endsWith(".ts")) out.push(path);
	}
	return out;
}

test("skill suites pin Node before the first Node command", () => {
	const workflow = readFileSync(join(root, "..", ".github", "workflows", "skill-tests.yml"), "utf8").split("\n");
	const setupNode = workflow.findIndex((line) => line.includes("uses: actions/setup-node@v4"));
	const deepResearch = workflow.findIndex((line) => line.includes("name: deep-research node suite"));
	const firstNodeCommand = workflow.findIndex((line) => /^\s*run:\s*node(?:\s|$)/.test(line));
	const setupBun = workflow.findIndex((line) => line.includes("uses: oven-sh/setup-bun@v2"));
	const piQol = workflow.findIndex((line) => line.includes("name: pi-qol regression suite"));
	const piClaudeBridge = workflow.findIndex((line) => line.includes("name: pi-claude-bridge unit suite"));
	assert.notEqual(setupNode, -1, "skill suites configure Node");
	assert.notEqual(firstNodeCommand, -1, "skill suites contain a Node command");
	assert.ok(setupNode < firstNodeCommand, "actions/setup-node must run before the first Node command");
	assert.ok(setupNode < deepResearch && deepResearch < setupBun, "deep-research stays between Node and Bun setup");
	assert.ok(setupBun < piQol && piQol < piClaudeBridge, "Pi package suite order stays unchanged");
	const nextStep = workflow.findIndex((line, index) => index > setupNode && /^\s{6}- (?:name|uses):/.test(line));
	assert.notEqual(nextStep, -1, "Node setup is followed by another workflow step");
	const setupBlock = workflow.slice(setupNode, nextStep);
	assert.ok(setupBlock.some((line) => line.trim() === "node-version: 22.19.0"), "skill suites pin exact Node 22.19.0");
	assert.ok(!setupBlock.some((line) => /^\s*cache:/.test(line)), "Node setup does not add caching");
});

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
