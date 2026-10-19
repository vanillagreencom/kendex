import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { codexChildEnvironment } from "../src/codex-environment.ts";
import { hasCodexLogin, requireCodexLogin, resolveCodexHome } from "../src/auth-presence.ts";

const scratchRoot = join(process.cwd(), "tmp");
mkdirSync(scratchRoot, { recursive: true });

test("login presence checks only the resolved CODEX_HOME auth file", () => {
	const root = mkdtempSync(join(scratchRoot, "auth-presence-"));
	const seededHome = join(root, "seeded home");
	mkdirSync(seededHome);
	assert.equal(resolveCodexHome({ CODEX_HOME: seededHome }, join(root, "other")), seededHome);
	assert.equal(hasCodexLogin(seededHome), false);
	assert.throws(() => requireCodexLogin(seededHome), {
		message: `codex-login-missing home=${seededHome}`,
	});
	writeFileSync(join(seededHome, "auth.json"), "credential-bytes-never-read");
	assert.equal(hasCodexLogin(seededHome), true);
});

test("Codex child inherits the exact home and no ambient credential variable", () => {
	const child = codexChildEnvironment("/seeded/codex", {
		PATH: "/bin",
		HOME: "/home/lane",
		CODEX_HOME: "/wrong",
		OPENAI_API_KEY: "alternate",
		GH_TOKEN: "alternate",
		SSH_AUTH_SOCK: "/socket",
		DATABASE_PASSWORD: "alternate",
		LANG: "C.UTF-8",
	});
	assert.deepEqual(child, {
		PATH: "/bin",
		HOME: "/home/lane",
		CODEX_HOME: "/seeded/codex",
		LANG: "C.UTF-8",
	});
});
