import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { model, system, user } from "./lib/fake-client.mjs";

const scratch = join(process.cwd(), "tmp");
mkdirSync(scratch, { recursive: true });

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

test("without a Codex login the provider advertises no model and refuses with the home", async () => {
	const home = mkdtempSync(join(scratch, "factory-nologin-"));
	const saved = { CODEX_HOME: process.env.CODEX_HOME, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
	process.env.CODEX_HOME = home;
	process.env.PI_CODING_AGENT_DIR = mkdtempSync(join(scratch, "factory-pi-"));
	try {
		const { default: factory } = await import("../src/index.ts");
		const pi = fakePi();
		await factory(pi);
		const [provider] = pi.providers;
		assert.ok(provider, "the provider is registered so Pi can show it once a login appears");
		assert.deepEqual(provider.getModels(), []);
		assert.equal(await provider.auth.apiKey.check(), undefined);
		assert.throws(() => provider.streamSimple(model, { messages: [system(), user("Hello")] }), (error) => error.message.split("\n")[0] === `codex-login-missing home=${home}`);
		const notices = [];
		for (const handler of pi.handlers.get("session_start") ?? []) handler({ reason: "startup" }, { hasUI: true, ui: { notify: (text, level) => notices.push([text.split("\n")[0], level]) } });
		assert.deepEqual(notices, [[`codex-login-missing home=${home}`, "warning"]]);
		for (const handler of pi.handlers.get("session_shutdown") ?? []) await handler({}, {});
	} finally {
		for (const [name, value] of Object.entries(saved)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
	}
});
