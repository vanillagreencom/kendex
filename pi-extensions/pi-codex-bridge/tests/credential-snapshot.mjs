// Live-smoke proof that the bridge wrote no Pi credential or settings file.
// Pi's files are compared byte for byte. CODEX_HOME/auth.json belongs to
// Codex, which may refresh it during the run, so it is reported, not compared.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const [action, snapshotPath] = process.argv.slice(2);
assert.ok(action === "write" || action === "compare", "usage: credential-snapshot.mjs <write|compare> <snapshot-path>");
assert.ok(snapshotPath, "snapshot path is required");

const codexAuth = join(process.env.CODEX_HOME?.trim() || join(homedir(), ".codex"), "auth.json");
const piHome = process.env.PI_CODING_AGENT_DIR?.trim() || join(homedir(), ".pi", "agent");
const piFiles = ["auth.json", "settings.json", "models.json"].map((name) => join(piHome, name));

function snapshot() {
	return Object.fromEntries(piFiles.map((path) => [path, existsSync(path) ? createHash("sha256").update(readFileSync(path)).digest("hex") : null]));
}

function codexAuthMtime() {
	return existsSync(codexAuth) ? statSync(codexAuth, { bigint: true }).mtimeNs.toString() : null;
}

if (action === "write") {
	writeFileSync(snapshotPath, JSON.stringify({ pi: snapshot(), codexAuthMtime: codexAuthMtime() }));
	console.log(`credential-scan-before pi_files=${piFiles.length}`);
} else {
	const before = JSON.parse(readFileSync(snapshotPath, "utf8"));
	assert.deepEqual(snapshot(), before.pi, "a Pi credential or settings file changed during the live bridge run");
	console.log(`credential-scan-after pi_unchanged=${piFiles.length} codex_auth_changed=${codexAuthMtime() !== before.codexAuthMtime}`);
}
