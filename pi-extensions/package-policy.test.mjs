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

function yamlScalar(value) {
	const trimmed = value.trim();
	if (trimmed.length >= 2 && ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
		return trimmed.slice(1, -1);
	}
	return trimmed;
}

function stepField(lines, key) {
	const pattern = new RegExp(`^(?: {6}-\\s+| {8})${key}:\\s*(.*)$`);
	for (const line of lines) {
		const match = line.match(pattern);
		if (match) return yamlScalar(match[1]);
	}
	return undefined;
}

function stepRun(lines) {
	const pattern = /^(?: {6}-\s+| {8})run:\s*(.*)$/;
	const index = lines.findIndex((line) => pattern.test(line));
	if (index === -1) return undefined;
	const match = lines[index].match(pattern);
	const value = match?.[1]?.trim() ?? "";
	if (!/^[>|][+-]?$/.test(value)) return yamlScalar(value);
	const runIndent = lines[index].match(/^\s*/)?.[0].length ?? 0;
	const body = [];
	for (const line of lines.slice(index + 1)) {
		if (line.trim() && (line.match(/^\s*/)?.[0].length ?? 0) <= runIndent) break;
		body.push(line.slice(Math.min(line.length, runIndent + 2)));
	}
	return body.join("\n");
}

function workflowJobSteps(source, jobName) {
	const lines = source.split("\n");
	const jobs = lines.findIndex((line) => line === "jobs:");
	assert.notEqual(jobs, -1, "workflow has jobs");
	const job = lines.findIndex((line, index) => index > jobs && line === `  ${jobName}:`);
	assert.notEqual(job, -1, `workflow has jobs.${jobName}`);
	const nextJob = lines.findIndex((line, index) => index > job && /^ {2}[A-Za-z0-9_-]+:\s*$/.test(line));
	const jobEnd = nextJob === -1 ? lines.length : nextJob;
	const steps = lines.findIndex((line, index) => index > job && index < jobEnd && line === "    steps:");
	assert.notEqual(steps, -1, `jobs.${jobName} has steps`);

	const blocks = [];
	let current;
	for (const line of lines.slice(steps + 1, jobEnd)) {
		if (/^ {6}-\s+/.test(line)) {
			if (current) blocks.push(current);
			current = [line];
		} else if (current) {
			current.push(line);
		}
	}
	if (current) blocks.push(current);
	return blocks.map((stepLines) => ({
		name: stepField(stepLines, "name"),
		raw: stepLines.join("\n").trimEnd(),
		run: stepRun(stepLines),
		uses: stepField(stepLines, "uses"),
	}));
}

function invokesNodeTool(run) {
	if (!run) return false;
	return run.split(/\r?\n|&&|\|\||;|\|/).some((segment) => {
		let command = segment.trim();
		command = command.replace(/^(?:(?:if|elif|then|do)\s+|!\s+)*/, "");
		command = command.replace(/^(?:(?:sudo|command|time|env)\s+)*/, "");
		command = command.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]+\s+)*/, "");
		const executable = command.match(/^["']?([^\s"']+)/)?.[1]?.split("/").pop()?.replace(/\.exe$/i, "");
		return executable === "node" || executable === "npm" || executable === "npx";
	});
}

function assertSkillSuitesNodePolicy(source) {
	const steps = workflowJobSteps(source, "skill-suites");
	const setupNode = steps.findIndex((step) => step.uses === "actions/setup-node@v4");
	const firstNodeCommand = steps.findIndex((step) => invokesNodeTool(step.run));
	const deepResearch = steps.findIndex((step) => step.name === "deep-research node suite");
	const setupBun = steps.findIndex((step) => step.uses === "oven-sh/setup-bun@v2");
	const piQol = steps.findIndex((step) => step.name === "pi-qol regression suite");
	const piClaudeBridge = steps.findIndex((step) => step.name === "pi-claude-bridge unit suite");
	assert.notEqual(setupNode, -1, "jobs.skill-suites configures Node");
	assert.notEqual(firstNodeCommand, -1, "jobs.skill-suites contains a Node/npm/npx command");
	assert.ok(setupNode < firstNodeCommand, "jobs.skill-suites setup-node must run before its first Node/npm/npx command");
	assert.ok(setupNode < deepResearch && deepResearch < setupBun, "deep-research stays between Node and Bun setup");
	assert.ok(setupBun < piQol && piQol < piClaudeBridge, "Pi package suite order stays unchanged");
	assert.match(steps[setupNode].raw, /^\s*node-version:\s*22\.19\.0\s*$/m, "skill suites pin exact Node 22.19.0");
	assert.doesNotMatch(steps[setupNode].raw, /^\s*cache:/m, "Node setup does not add caching");
}

function replaceOnce(source, before, after) {
	const index = source.indexOf(before);
	assert.notEqual(index, -1, "mutation target exists");
	assert.equal(source.indexOf(before, index + before.length), -1, "mutation target is unique");
	return `${source.slice(0, index)}${after}${source.slice(index + before.length)}`;
}

const skillTestsWorkflow = () => readFileSync(join(root, "..", ".github", "workflows", "skill-tests.yml"), "utf8");

test("skill suites Node policy accepts the pinned workflow", () => {
	assertSkillSuitesNodePolicy(skillTestsWorkflow());
});

test("skill suites Node policy rejects wrong-job setup and hidden block commands", () => {
	const workflow = skillTestsWorkflow();
	const setupStep = workflowJobSteps(workflow, "skill-suites").find((step) => step.uses === "actions/setup-node@v4");
	assert.ok(setupStep, "skill suites setup-node step exists for mutations");
	const withoutSetup = replaceOnce(workflow, setupStep.raw, "");
	const wrongJobSetup = replaceOnce(
		withoutSetup,
		"jobs:\n",
		`jobs:\n  wrong-job:\n    runs-on: ubuntu-latest\n    steps:\n${setupStep.raw}\n\n`,
	);
	assert.throws(() => assertSkillSuitesNodePolicy(wrongJobSetup), /jobs\.skill-suites configures Node/);

	const hiddenCommand = `      - name: hidden pre-setup block command\n        run: |\n          echo preparing\n          npx --version\n\n${setupStep.raw}`;
	const blockCommandBeforeSetup = replaceOnce(workflow, setupStep.raw, hiddenCommand);
	assert.throws(() => assertSkillSuitesNodePolicy(blockCommandBeforeSetup), /before its first Node\/npm\/npx command/);
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
