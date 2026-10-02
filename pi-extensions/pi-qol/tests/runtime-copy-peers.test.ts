import { describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { patchFile, scratch } from "./search-fixture.ts";

const packageDir = resolve(import.meta.dir, "..");
const PROBE = "tests/runtime-copy-peers.probe.ts";
const CODING_AGENT = "@earendil-works/pi-coding-agent";
const manifest = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8")) as { peerDependencies: Record<string, string> };

// The version the runner installed the peers at, which the CI step names.
const PIN_ENV = "PI_QOL_PEER_VERSION";

// The child gets only HOME and the runner's peer version, so no inherited
// NODE_PATH, NODE_OPTIONS or BUN_OPTIONS reaches its resolution. --no-install
// stops Bun from fetching a missing peer into its global cache, which would
// stand in for the install.
function probe(contextDir: string, pin: string | undefined, preload: string[] = []): { exitCode: number; stdout: string; stderr: string } {
	const home = scratch();
	try {
		const env: Record<string, string> = { HOME: home };
		if (pin !== undefined) env[PIN_ENV] = pin;
		const run = Bun.spawnSync([process.execPath, "--no-install", ...preload, join(contextDir, PROBE)], { cwd: contextDir, env, stdout: "pipe", stderr: "pipe" });
		return { exitCode: run.exitCode, stdout: run.stdout.toString(), stderr: run.stderr.toString() };
	} finally { rmSync(home, { recursive: true, force: true }); }
}

type Peers = "linked" | "absent" | "mixed";

// A disposable package context: the probe, its fixture, the runtime it copies
// and the manifest, with the peers each row plants.
function packageContext(parent: string, peers: Peers): string {
	const dir = scratch(parent);
	mkdirSync(join(dir, "tests"));
	for (const entry of ["package.json", "extensions", "scripts", PROBE, "tests/search-fixture.ts"]) cpSync(join(packageDir, entry), join(dir, entry), { recursive: true });
	if (peers === "linked") symlinkSync(join(packageDir, "node_modules"), join(dir, "node_modules"));
	if (peers === "mixed") {
		for (const peer of Object.keys(manifest.peerDependencies)) {
			mkdirSync(dirname(join(dir, "node_modules", peer)), { recursive: true });
			if (peer !== CODING_AGENT) symlinkSync(join(packageDir, "node_modules", peer), join(dir, "node_modules", peer));
		}
		const fake = join(dir, "node_modules", CODING_AGENT);
		mkdirSync(fake);
		writeFileSync(join(fake, "package.json"), JSON.stringify({ name: CODING_AGENT, version: "0.85.0", type: "module", exports: { ".": { import: "./index.js" } } }));
		writeFileSync(join(fake, "index.js"), "export {};\n");
	}
	return dir;
}

describe("copied runtime against the installed Pi peers", () => {
	test("the copy imports and runs through the package's installed peers and is removed on success and failure", () => {
		const pin = process.env[PIN_ENV];
		const run = probe(packageDir, pin);
		expect(run.stderr).toBe("");
		expect(run.stdout).toMatch(/^runtime-copy-peers: proved version=\d+\.\d+\.\d+ model=anthropic\/claude-proof\n$/);
		if (pin !== undefined) expect(run.stdout).toContain(` version=${pin} `);
		expect(run.exitCode).toBe(0);
	}, 30_000);

	// Must-fail controls: one planted defect per precondition rule, one that
	// runs the copy against the suite's peer stubs, and one per teardown rule,
	// each on a private package context. A context under this package's tmp/
	// with no node_modules of its own resolves the peers from the package
	// above it, which is the outside-package defect. The floor row raises the
	// floor past the installed set; the last row lowers it beneath the set, as
	// an install above the floor without a pin, and passes.
	test("each precondition rule and teardown refuses its planted defect", () => {
		const declared = `"${CODING_AGENT}": "${manifest.peerDependencies[CODING_AGENT]}"`;
		const rows: Array<{ rule: string; parent: string; peers: Peers; pin?: string; patch?: { file: string; from: string; to: string }; preload?: string[]; refusal: string | null }> = [
			{ rule: "floor form", parent: tmpdir(), peers: "linked", patch: { file: "package.json", from: `"${CODING_AGENT}": ">=`, to: `"${CODING_AGENT}": "^` }, refusal: `floor-form peer=${CODING_AGENT} range=[^` },
			{ rule: "installed", parent: tmpdir(), peers: "absent", refusal: "peer-unresolved peer=@earendil-works/pi-agent-core " },
			{ rule: "inside the package", parent: join(packageDir, "tmp"), peers: "absent", refusal: "peer-outside-package peer=@earendil-works/pi-agent-core " },
			{ rule: "one version", parent: tmpdir(), peers: "mixed", refusal: `peer-version peer=${CODING_AGENT} installed=0.85.0 want=` },
			{ rule: "runner pin", parent: tmpdir(), peers: "linked", pin: "0.0.0", refusal: "peer-version peer=@earendil-works/pi-agent-core installed=" },
			{ rule: "floor", parent: tmpdir(), peers: "linked", patch: { file: "package.json", from: declared, to: `"${CODING_AGENT}": ">=999.0.0"` }, refusal: "peer-below-floor version=[" },
			{ rule: "real peers", parent: tmpdir(), peers: "linked", preload: ["--preload", join(packageDir, "tests/preload.ts")], refusal: "copy-run model=null" },
			{ rule: "teardown", parent: tmpdir(), peers: "linked", patch: { file: "tests/search-fixture.ts", from: "rmSync(root, { recursive: true, force: true })", to: "void root" }, refusal: "teardown-left outcomes=success,failure " },
			{ rule: "failure kept", parent: tmpdir(), peers: "linked", patch: { file: "tests/search-fixture.ts", from: "as T, root);", to: "as T, root).catch(() => undefined);" }, refusal: "failure-lost outcome=[undefined]" },
			{ rule: "above the floor", parent: tmpdir(), peers: "linked", patch: { file: "package.json", from: declared, to: `"${CODING_AGENT}": ">=0.0.1"` }, refusal: null },
		];
		for (const row of rows) {
			const dir = packageContext(row.parent, row.peers);
			try {
				if (row.patch) patchFile(join(dir, row.patch.file), row.patch.from, row.patch.to);
				const run = probe(dir, row.pin, row.preload);
				if (row.refusal === null) expect({ rule: row.rule, exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr }).toMatchObject({ rule: row.rule, exitCode: 0, stdout: expect.stringMatching(/^runtime-copy-peers: proved /), stderr: "" });
				else expect({ rule: row.rule, exitCode: run.exitCode, refused: run.stderr.startsWith(`runtime-copy-peers: ${row.refusal}`), stderr: run.stderr }).toMatchObject({ rule: row.rule, exitCode: 1, refused: true });
			} finally { rmSync(dir, { recursive: true, force: true }); }
		}
	}, 90_000);
});
