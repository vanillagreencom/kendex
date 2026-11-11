import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { hasCodexLogin, loginMissingMessage, requireCodexLogin, resolveCodexHome } from "../src/auth-presence.ts";
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

test("login presence checks only the resolved home's auth file", () => {
	const root = mkdtempSync(join(scratchRoot, "auth-presence-"));
	const seededHome = join(root, "seeded home");
	mkdirSync(seededHome);
	assert.equal(hasCodexLogin(seededHome), false);
	assert.throws(() => requireCodexLogin(seededHome), (error) => error.message.split("\n")[0] === `codex-login-missing home=${seededHome}`);
	writeFileSync(join(seededHome, "auth.json"), "credential-bytes-never-read");
	assert.equal(hasCodexLogin(seededHome), true);
	assert.doesNotThrow(() => requireCodexLogin(seededHome));
});

// A person copies the remedy's command. A plain `codex login` signs in to
// CODEX_HOME, else ~/.codex, creating ~/.codex, and refuses a CODEX_HOME folder
// that does not exist (Codex 0.163.0 and 0.166.0). So the command is offered
// only where it signs in to the bridge home; elsewhere the remedy names the
// home and carries no shell assignment.
test("the sign-in remedy is a plain codex login only where that login reaches the bridge home", () => {
	const userHome = "/home/lane";
	const cliDefault = join(userHome, ".codex");
	for (const row of [
		{ env: {}, plain: true },
		{ env: { CODEX_HOME: "/shell" }, plain: true },
		{ env: { PI_CODEX_BRIDGE_HOME: " ", CODEX_HOME: "/shell" }, plain: true },
		{ env: { PI_CODEX_BRIDGE_HOME: "/shell", CODEX_HOME: "/shell" }, plain: true },
		{ env: { PI_CODEX_BRIDGE_HOME: cliDefault }, plain: true },
		{ env: { PI_CODEX_BRIDGE_HOME: "/bridge's home" }, plain: false },
		{ env: { PI_CODEX_BRIDGE_HOME: "/bridge's home", CODEX_HOME: "/shell" }, plain: false },
		{ env: { PI_CODEX_BRIDGE_HOME: cliDefault, CODEX_HOME: "/shell" }, plain: false },
	]) {
		const label = JSON.stringify(row.env);
		const home = resolveCodexHome(row.env, userHome);
		const [key, remedy] = loginMissingMessage(home, row.env, userHome).split("\n");
		assert.equal(key, `codex-login-missing home=${home}`, label);
		if (row.plain) {
			assert.ok(remedy.endsWith(": codex login"), label);
			assert.ok(!remedy.includes("CODEX_HOME"), label);
		} else {
			assert.ok(remedy.includes(home), label);
			assert.ok(!remedy.includes("CODEX_HOME=") && !remedy.endsWith(": codex login"), label);
		}
	}
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
