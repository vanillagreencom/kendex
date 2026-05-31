// vstack#60 workaround regression test: when pi-agents-tmux spawns a
// subagent Pi pane, the generated launcher script must export
// PI_BRIDGE_PARENT_SESSION_ID + PI_BRIDGE_CHILD_ROLE so the
// pi-session-bridge in the child synthesizes a unique session id.
//
// Round-2 reviewer-arch minor #M1: the env names are no longer
// hardcoded as magic strings inside the heredoc — they're declared as
// module constants in pane.ts and interpolated. The bridge package
// owns the canonical names (PARENT_SESSION_ENV / CHILD_ROLE_ENV in
// pi-extensions/pi-session-bridge/extensions/child-session-id.ts); the
// parity test at the bottom asserts both sides agree.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
	CHILD_ROLE_ENV,
	PARENT_SESSION_ENV,
} from "../../pi-session-bridge/extensions/child-session-id.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const PANE_SRC = resolve(HERE, "../extensions/subagent/pane.ts");

test("writeLauncher template exports PI_BRIDGE_PARENT_SESSION_ID for subagent pane", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	assert.match(src, /export \$\{PI_BRIDGE_PARENT_SESSION_ENV\}=\$\{shellQuote\(parentSessionId\)\}/);
});

test("writeLauncher passes the agent name as Pi startup session name", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	assert.match(src, /const args = \["--name", agent\.name, "--session", sessionFile,/);
});

test("writeLauncher template exports PI_BRIDGE_CHILD_ROLE=subagent", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	assert.match(src, /export \$\{PI_BRIDGE_CHILD_ROLE_ENV\}=\$\{shellQuote\(PI_BRIDGE_SUBAGENT_ROLE\)\}/);
});

test("writeLauncher marks persistent children as visible pane owners", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	assert.match(src, /export \$\{PI_SUBAGENT_CHILD_PANE_ENV\}=1/);
});

test("PI_BRIDGE_* env vars are exported BEFORE the exec line so the child Pi inherits them", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	const exportIdx = src.indexOf("PI_BRIDGE_PARENT_SESSION_ENV}=");
	const execIdx = src.indexOf("exec ${command}");
	assert.ok(exportIdx > -1, "expected PI_BRIDGE_PARENT_SESSION_ENV interpolation in writeLauncher");
	assert.ok(execIdx > -1, "expected exec line in writeLauncher");
	assert.ok(exportIdx < execIdx, "PI_BRIDGE_* exports must come before exec");
});

test("PI_BRIDGE_PARENT_SESSION_ID interpolation mirrors the PI_SUBAGENT_PARENT_SESSION_ID source", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	const piSubagent = src.match(/PI_SUBAGENT_PARENT_SESSION_ID=\$\{shellQuote\(([^)]+)\)\}/);
	const piBridge = src.match(/PI_BRIDGE_PARENT_SESSION_ENV\}=\$\{shellQuote\(([^)]+)\)\}/);
	assert.ok(piSubagent, "expected PI_SUBAGENT_PARENT_SESSION_ID export");
	assert.ok(piBridge, "expected PI_BRIDGE_PARENT_SESSION_ENV interpolation");
	assert.equal(piBridge![1], piSubagent![1], "both env vars must propagate the same parent id expression");
});

test("pane.ts local env constants match pi-session-bridge's canonical exports", () => {
	const src = readFileSync(PANE_SRC, "utf8");
	const parentMatch = src.match(/PI_BRIDGE_PARENT_SESSION_ENV\s*=\s*"([^"]+)"/);
	const roleMatch = src.match(/PI_BRIDGE_CHILD_ROLE_ENV\s*=\s*"([^"]+)"/);
	assert.ok(parentMatch, "expected PI_BRIDGE_PARENT_SESSION_ENV constant in pane.ts");
	assert.ok(roleMatch, "expected PI_BRIDGE_CHILD_ROLE_ENV constant in pane.ts");
	assert.equal(parentMatch![1], PARENT_SESSION_ENV, "pane.ts parent-session env name must match bridge canonical");
	assert.equal(roleMatch![1], CHILD_ROLE_ENV, "pane.ts child-role env name must match bridge canonical");
});
