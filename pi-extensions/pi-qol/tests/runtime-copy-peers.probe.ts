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

// The CI step installs every peer at the coding-agent floor, so the floor is
// the exact pin. The package policy holds a peer floor to the `>=x.y.z` form.
function pinnedVersion(): string {
	const floor = manifest.peerDependencies?.[CODING_AGENT] ?? "";
	const version = /^>=(\d+\.\d+\.\d+)$/.exec(floor)?.[1];
	if (!version) throw new Refusal("floor-form", `peer=${CODING_AGENT} range=[${floor}]`);
	return version;
}

// npm can exit 0 without the set in place, so each peer must resolve from
// this package, through import.meta.resolve as Pi's import-only entries
// need, into this package's own node_modules at the pinned version.
function assertPeersInstalled(pin: string): void {
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
		const version = (JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { version?: unknown }).version;
		if (version !== pin) throw new Refusal("peer-version", `peer=${peer} installed=${String(version)} pin=${pin}`);
	}
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

async function assertTeardown(): Promise<void> {
	let succeeded = "";
	await runtimeCopy<typeof Cache>("qol/session-search/cache.ts", [], async (cache, root) => {
		succeeded = root;
		await runCopy(cache, root);
	});
	if (!succeeded || existsSync(succeeded)) throw new Refusal("teardown-left", `outcome=success path=[${succeeded}]`);

	let failed = "";
	const planted = new Error("planted callback failure");
	const outcome = await runtimeCopy<typeof Cache>("qol/session-search/cache.ts", [], async (_cache, root) => {
		failed = root;
		throw planted;
	}).then(() => undefined, (error: unknown) => error);
	if (outcome !== planted) throw new Refusal("failure-lost", `outcome=[${String(outcome)}]`);
	if (!failed || existsSync(failed)) throw new Refusal("teardown-left", `outcome=failure path=[${failed}]`);
}

try {
	const pin = pinnedVersion();
	assertPeersInstalled(pin);
	await assertTeardown();
	console.log(`runtime-copy-peers: proved pin=${pin} model=${MODEL.provider}/${MODEL.id}`);
} catch (error) {
	console.error(error instanceof Refusal ? error.message : `runtime-copy-peers: error ${(error as Error)?.stack ?? String(error)}`);
	process.exit(1);
}
