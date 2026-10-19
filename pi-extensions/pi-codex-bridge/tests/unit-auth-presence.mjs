import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { hasCodexLogin, requireCodexLogin, resolveCodexHome } from "../src/auth-presence.ts";
import { codexChildEnvironment } from "../src/codex-environment.ts";

const scratchRoot = join(process.cwd(), "tmp");
mkdirSync(scratchRoot, { recursive: true });

test("login presence checks only the resolved CODEX_HOME auth file", () => {
	const root = mkdtempSync(join(scratchRoot, "auth-presence-"));
	const seededHome = join(root, "seeded home");
	mkdirSync(seededHome);
	assert.equal(resolveCodexHome({ CODEX_HOME: ` ${seededHome} ` }, join(root, "other")), seededHome);
	assert.equal(resolveCodexHome({ CODEX_HOME: "  " }, join(root, "user")), join(root, "user", ".codex"));
	assert.equal(hasCodexLogin(seededHome), false);
	assert.throws(() => requireCodexLogin(seededHome), (error) => error.message.split("\n")[0] === `codex-login-missing home=${seededHome}`);
	writeFileSync(join(seededHome, "auth.json"), "credential-bytes-never-read");
	assert.equal(hasCodexLogin(seededHome), true);
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
