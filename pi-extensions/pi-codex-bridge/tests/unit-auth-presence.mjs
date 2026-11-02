import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { hasCodexLogin, requireCodexLogin, resolveCodexHome } from "../src/auth-presence.ts";
import { codexChildEnvironment } from "../src/codex-environment.ts";

const scratchRoot = join(process.cwd(), "tmp");
mkdirSync(scratchRoot, { recursive: true });

test("the bridge home is PI_CODEX_BRIDGE_HOME, else CODEX_HOME, else ~/.codex, a blank value counting as unset", () => {
	const userHome = "/home/lane";
	for (const row of [
		{ env: { PI_CODEX_BRIDGE_HOME: " /bridge home ", CODEX_HOME: "/shell" }, home: "/bridge home" },
		{ env: { PI_CODEX_BRIDGE_HOME: "  ", CODEX_HOME: " /shell " }, home: "/shell" },
		{ env: { CODEX_HOME: "/shell" }, home: "/shell" },
		{ env: { PI_CODEX_BRIDGE_HOME: "", CODEX_HOME: "  " }, home: join(userHome, ".codex") },
		{ env: {}, home: join(userHome, ".codex") },
	]) {
		assert.equal(resolveCodexHome(row.env, userHome), row.home, JSON.stringify(row.env));
	}
});

// The remedy's command runs in a person's shell, so the row runs it through
// sh, with a stand-in codex that signs in where CODEX_HOME points, as the
// Codex CLI does. The shell's own CODEX_HOME names another home.
test("a missing login names the bridge home, and its sign-in command writes the login there", () => {
	const root = mkdtempSync(join(scratchRoot, "auth-presence-"));
	const bridgeHome = resolveCodexHome({ PI_CODEX_BRIDGE_HOME: join(root, "bridge's home"), CODEX_HOME: join(root, "shell") });
	const shellHome = join(root, "shell");
	const bin = join(root, "bin");
	for (const dir of [bridgeHome, shellHome, bin]) mkdirSync(dir);
	writeFileSync(join(bin, "codex"), '#!/bin/sh\n[ "$1" = login ] && printf x > "$CODEX_HOME/auth.json"\n');
	chmodSync(join(bin, "codex"), 0o755);
	assert.equal(hasCodexLogin(bridgeHome), false);
	let message = "";
	assert.throws(() => requireCodexLogin(bridgeHome), (error) => (message = error.message).split("\n")[0] === `codex-login-missing home=${bridgeHome}`);
	const remedy = message.split("\n").at(-1);
	execFileSync("sh", ["-c", remedy.slice(remedy.lastIndexOf(": ") + 2)], { env: { PATH: `${bin}:${process.env.PATH}`, CODEX_HOME: shellHome } });
	assert.equal(hasCodexLogin(bridgeHome), true);
	assert.equal(hasCodexLogin(shellHome), false);
});

// Every name outside the allowlist is dropped, whatever it is called: the
// planted names include credentials no name pattern would recognize.
test("the Codex child inherits only the allowlisted variables and the exact home", () => {
	const child = codexChildEnvironment("/seeded/codex", {
		PATH: "/bin",
		HOME: "/home/lane",
		LANG: "C.UTF-8",
		LC_ALL: "C.UTF-8",
		TMPDIR: "/scratch",
		HTTPS_PROXY: "http://proxy:3128",
		no_proxy: "localhost",
		SSL_CERT_FILE: "/ca.pem",
		CODEX_HOME: "/wrong",
		OPENAI_API_KEY: "planted",
		CODEX_API_KEY: "planted",
		GH_TOKEN: "planted",
		SSH_AUTH_SOCK: "/socket",
		DATABASE_URL: "postgres://user:planted@db",
		LANE_CREDS: "planted",
		NODE_OPTIONS: "--require /planted.js",
	});
	assert.deepEqual(child, {
		PATH: "/bin",
		HOME: "/home/lane",
		LANG: "C.UTF-8",
		LC_ALL: "C.UTF-8",
		TMPDIR: "/scratch",
		HTTPS_PROXY: "http://proxy:3128",
		no_proxy: "localhost",
		SSL_CERT_FILE: "/ca.pem",
		CODEX_HOME: "/seeded/codex",
	});
});
