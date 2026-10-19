import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const [action, snapshotPath] = process.argv.slice(2);
assert.ok(action === "write" || action === "compare", "usage: credential-snapshot.mjs <write|compare> <snapshot-path>");
assert.ok(snapshotPath, "snapshot path is required");

const codexHome = process.env.CODEX_HOME?.trim() || join(homedir(), ".codex");
const piHome = process.env.PI_CODING_AGENT_DIR?.trim() || join(homedir(), ".pi", "agent");
const credentialPaths = [
	join(codexHome, "auth.json"),
	join(piHome, "auth.json"),
];
const settingsPaths = [
	join(piHome, "settings.json"),
	join(piHome, "models.json"),
];

function metadata(path) {
	if (!existsSync(path)) return null;
	const stat = statSync(path, { bigint: true });
	return {
		size: stat.size.toString(),
		mtimeNs: stat.mtimeNs.toString(),
		ctimeNs: stat.ctimeNs.toString(),
		mode: stat.mode.toString(),
	};
}

function snapshot() {
	return {
		credentials: Object.fromEntries(credentialPaths.map((path) => [path, metadata(path)])),
		settings: Object.fromEntries(settingsPaths.map((path) => [
			path,
			existsSync(path) ? createHash("sha256").update(readFileSync(path)).digest("hex") : null,
		])),
	};
}

if (action === "write") {
	writeFileSync(snapshotPath, JSON.stringify(snapshot()));
	console.log(`credential-scan-before codex_home=${JSON.stringify(codexHome)} credential_files=${credentialPaths.length} settings_files=${settingsPaths.length}`);
} else {
	const before = JSON.parse(readFileSync(snapshotPath, "utf8"));
	assert.deepEqual(snapshot(), before, "Codex or Pi credential/settings files changed during the live bridge run");
	console.log(`credential-scan-after unchanged=${credentialPaths.length + settingsPaths.length}`);
}
