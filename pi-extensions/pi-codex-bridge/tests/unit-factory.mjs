import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { clearPackageConfigCache } from "../src/package-config.ts";
import { model, system, user } from "./lib/fake-client.mjs";
import { writeStubCodex } from "./lib/stub-codex.mjs";

const scratch = join(process.cwd(), "tmp");
mkdirSync(scratch, { recursive: true });
const PACKAGE_ID = "@vanillagreen/pi-codex-bridge";
const disabled = { kendex: { extensionManager: { config: { [PACKAGE_ID]: { enabled: false } } } } };

function fakePi() {
	const handlers = new Map();
	const providers = [];
	return {
		providers,
		handlers,
		registerProvider: (provider) => providers.push(provider),
		on: (event, handler) => handlers.set(event, [...(handlers.get(event) ?? []), handler]),
		events: { on: () => () => undefined },
	};
}

// Where the provider comes from on a fresh start, per login and project
// setting. `factory` and `started` are the providers registered after the
// factory and after session_start; `server` is whether model discovery
// started an app-server. A project's disable holds only once Pi trusts it,
// and Pi's trust answer arrives at session_start.
for (const row of [
	{ name: "no login", login: false, project: {}, trusted: true, factory: 1, started: 1, server: false, notice: "codex-login-missing" },
	{ name: "a login", login: true, project: {}, trusted: true, factory: 1, started: 1, server: true, notice: undefined },
	{ name: "a login, and a trusted project disables the package", login: true, project: disabled, trusted: true, factory: 0, started: 0, server: false, notice: undefined },
	{ name: "a login, and an untrusted project disables the package", login: true, project: disabled, trusted: false, factory: 0, started: 1, server: true, notice: undefined },
]) {
	test(`fresh startup with ${row.name}`, { timeout: 20_000 }, async () => {
		const home = mkdtempSync(join(scratch, "factory-home-"));
		if (row.login) writeFileSync(join(home, "auth.json"), "{}");
		const bin = mkdtempSync(join(scratch, "factory-bin-"));
		writeStubCodex(bin);
		const project = mkdtempSync(join(scratch, "factory-project-"));
		mkdirSync(join(project, ".pi"));
		writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify(row.project));
		const saved = { CODEX_HOME: process.env.CODEX_HOME, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR, PATH: process.env.PATH };
		const savedCwd = process.cwd();
		process.env.CODEX_HOME = home;
		process.env.PI_CODING_AGENT_DIR = mkdtempSync(join(scratch, "factory-pi-"));
		process.env.PATH = `${bin}:${process.env.PATH}`;
		process.chdir(project);
		clearPackageConfigCache();
		const pi = fakePi();
		try {
			const { default: factory } = await import("../src/index.ts");
			await factory(pi);
			assert.equal(pi.providers.length, row.factory);
			const notices = [];
			const ctx = { hasUI: true, cwd: project, isProjectTrusted: () => row.trusted, ui: { notify: (text, level) => notices.push([text.split("\n")[0], level]) } };
			for (const handler of pi.handlers.get("session_start") ?? []) await handler({ reason: "startup" }, ctx);
			assert.equal(pi.providers.length, row.started);
			assert.equal(existsSync(join(bin, "app-server.pid")), row.server);
			assert.deepEqual(notices, row.notice === undefined ? [] : [[`${row.notice} home=${home}`, "warning"]]);
			const [provider] = pi.providers;
			if (provider !== undefined && !row.login) {
				assert.deepEqual(provider.getModels(), []);
				assert.equal(await provider.auth.apiKey.check(), undefined);
				assert.throws(() => provider.streamSimple(model, { messages: [system(), user("Hello")] }), (error) => error.message.split("\n")[0] === `codex-login-missing home=${home}`);
			}
		} finally {
			for (const handler of pi.handlers.get("session_shutdown") ?? []) await handler({}, {});
			process.chdir(savedCwd);
			for (const [name, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[name];
				else process.env[name] = value;
			}
			clearPackageConfigCache();
		}
	});
}
