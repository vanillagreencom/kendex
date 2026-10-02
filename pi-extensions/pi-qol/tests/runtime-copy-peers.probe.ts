// Package-context proof that a runtimeCopy copy imports and runs through the
// Pi peers installed in this package's node_modules. It runs as a plain Bun
// script, never under `bun test`, so bunfig.toml's preload stubs no peer, and
// tests/runtime-copy-peers.test.ts starts it with an explicit environment.
// Exit 0 prints one `proved` line; a refusal prints one line on stderr,
// `runtime-copy-peers: <key> <values>`, and exits 1. The keys are the protocol
// that test reads.

import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type * as Cache from "../extensions/qol/session-search/cache.ts";
import { runtimeCopy } from "./search-fixture.ts";

const CODING_AGENT = "@earendil-works/pi-coding-agent";
const MODEL = { provider: "anthropic", id: "claude-proof" };

class Refusal extends Error {
	constructor(key: string, values: string) {
		super(`runtime-copy-peers: ${key} ${values}`);
	}
}

const packageDir = resolve(import.meta.dir, "..");
const manifest = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8")) as { peerDependencies?: Record<string, string> };

// The runner that installed the peers names their one version in
// PI_QOL_PEER_VERSION, as the CI step does; a run without it, such as the
// pi-update audit's install at its target, takes the version the peers share.
const PIN_ENV = "PI_QOL_PEER_VERSION";

// The package policy holds a peer floor to the `>=x.y.z` form.
function codingAgentFloor(): string {
	const floor = manifest.peerDependencies?.[CODING_AGENT] ?? "";
	const version = /^>=(\d+\.\d+\.\d+)$/.exec(floor)?.[1];
	if (!version) throw new Refusal("floor-form", `peer=${CODING_AGENT} range=[${floor}]`);
	return version;
}

// npm can exit 0 without the set in place, so each peer must resolve from
// this package, through import.meta.resolve as Pi's import-only entries
// need, into this package's own node_modules, every peer at one version that
// meets the floor. Returns that version.
function assertPeersInstalled(floor: string, pin: string | undefined): string {
	let want = pin;
	for (const peer of Object.keys(manifest.peerDependencies ?? {})) {
		let entry: string;
		try {
			entry = realpathSync(fileURLToPath(import.meta.resolve(peer)));
		} catch (error) {
			throw new Refusal("peer-unresolved", `peer=${peer} cause=[${(error as Error).message}]`);
		}
		const installed = join(packageDir, "node_modules", ...peer.split("/"));
		const root = existsSync(installed) ? realpathSync(installed) : installed;
		if (!entry.startsWith(root + sep)) throw new Refusal("peer-outside-package", `peer=${peer} entry=${entry}`);
		const version = String((JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { version?: unknown }).version);
		want ??= version;
		if (version !== want) throw new Refusal("peer-version", `peer=${peer} installed=${version} want=${want} pin=[${pin ?? ""}]`);
	}
	if (want === undefined || Bun.semver.order(want, floor) < 0) throw new Refusal("peer-below-floor", `version=[${want ?? ""}] floor=${floor}`);
	return want;
}

// Pi's SessionManager reads the model back; the suite's preload stub has no
// `open`, so only the real installed SDK returns it.
async function runCopy(cache: typeof Cache, root: string): Promise<void> {
	const session = join(root, "session.jsonl");
	writeFileSync(session, [
		{ type: "session", version: 3, id: "proof", timestamp: "2026-01-01T00:00:00.000Z", cwd: root },
		{ type: "model_change", id: "m1", parentId: null, timestamp: "2026-01-01T00:00:00.000Z", provider: MODEL.provider, modelId: MODEL.id },
	].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
	const model = cache.sessionModelInfo(session);
	if (model?.provider !== MODEL.provider || model.id !== MODEL.id) throw new Refusal("copy-run", `model=${JSON.stringify(model ?? null)}`);
}

// Both outcomes run before teardown is judged, so one refusal names every
// outcome that left its copy behind.
async function assertTeardown(): Promise<void> {
	let succeeded = "";
	await runtimeCopy<typeof Cache>("qol/session-search/cache.ts", [], async (cache, root) => {
		succeeded = root;
		await runCopy(cache, root);
	});

	let failed = "";
	const planted = new Error("planted callback failure");
	const outcome = await runtimeCopy<typeof Cache>("qol/session-search/cache.ts", [], async (_cache, root) => {
		failed = root;
		throw planted;
	}).then(() => undefined, (error: unknown) => error);
	if (outcome !== planted) throw new Refusal("failure-lost", `outcome=[${String(outcome)}]`);

	const left = [["success", succeeded], ["failure", failed]].filter(([, root]) => !root || existsSync(root));
	if (left.length) throw new Refusal("teardown-left", `outcomes=${left.map(([name]) => name).join(",")} paths=[${left.map(([, root]) => root).join(",")}]`);
}

try {
	const version = assertPeersInstalled(codingAgentFloor(), process.env[PIN_ENV]);
	await assertTeardown();
	console.log(`runtime-copy-peers: proved version=${version} model=${MODEL.provider}/${MODEL.id}`);
} catch (error) {
	console.error(error instanceof Refusal ? error.message : `runtime-copy-peers: error ${(error as Error)?.stack ?? String(error)}`);
	process.exit(1);
}
