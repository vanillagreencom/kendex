import assert from "node:assert/strict";
import test from "node:test";
import { setImmediate } from "node:timers/promises";
import { registerBackgroundImageGenerationCommand } from "../src/background-image-generation.js";
import { environment, world } from "./helpers/world.js";

function commandWorld(t: Parameters<typeof world>[0]) {
	const { cwd, agent } = world(t);
	environment(t, { PI_CODING_AGENT_DIR: agent });
	let command: ((args: string, ctx: unknown) => Promise<void>) | undefined;
	let shutdown: (() => void) | undefined;
	const messages: unknown[] = [];
	const notices: Array<{ message: string; level: string }> = [];
	const statuses: unknown[] = [];
	registerBackgroundImageGenerationCommand({
		on(event: string, handler: () => void) { if (event === "session_shutdown") shutdown = handler; },
		registerMessageRenderer() {},
		registerCommand(_name: string, value: { handler: typeof command }) { command = value.handler; },
		sendMessage(message: unknown) { messages.push(message); },
	} as never);
	assert.ok(command); assert.ok(shutdown);
	t.after(() => shutdown!());
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	const auth = { ok: true, apiKey: `header.${payload}.signature`, headers: {} };
	const ctx = {
		cwd, model: { provider: "openai-codex", id: "gpt-5.4", input: ["text", "image"] },
		modelRegistry: { getApiKeyAndHeaders: async () => auth },
		ui: {
			notify(message: string, level: string) { notices.push({ message, level }); },
			setStatus(_key: string, value: unknown) { statuses.push(value); },
			setWidget() {},
		},
	};
	return { run: (prompt: string) => command!(prompt, ctx), shutdown, messages, notices, statuses, ctx, auth };
}

test("five image commands cap live fetches and session shutdown aborts every body", async (t) => {
	const fixture = commandWorld(t);
	const live = new Set<AbortSignal>();
	const signals: AbortSignal[] = [];
	t.mock.method(globalThis, "fetch", async (_url: unknown, init: RequestInit) => {
		const signal = init.signal;
		assert.ok(signal);
		signals.push(signal);
		live.add(signal);
		return new Response(new ReadableStream({ start(controller) {
			signal.addEventListener("abort", () => {
				live.delete(signal);
				controller.error(signal.reason);
			}, { once: true });
		} }));
	});
	for (let index = 0; index < 5; index++) await fixture.run(`Image ${index}`);
	await setImmediate();
	assert.equal(live.size, 4);
	assert.equal(fixture.notices.filter(notice => notice.level === "warning").length, 1);
	fixture.shutdown();
	await setImmediate();
	assert.equal(live.size, 0);
	assert.ok(signals.every(signal => signal.aborted));
	assert.equal(fixture.messages.length, 0);
	const statusCount = fixture.statuses.length;
	await setImmediate();
	assert.equal(fixture.statuses.length, statusCount, "old jobs must not restore the shutdown status context");
	assert.equal(fixture.statuses.at(-1), undefined);
});

test("image job waiting for credentials cannot start a fetch after shutdown", async (t) => {
	const fixture = commandWorld(t);
	let release: ((auth: typeof fixture.auth) => void) | undefined;
	fixture.ctx.modelRegistry.getApiKeyAndHeaders = () => new Promise(resolve => { release = resolve; });
	let requests = 0;
	t.mock.method(globalThis, "fetch", async () => { requests++; return new Response(""); });
	await fixture.run("Image waiting for credentials");
	fixture.shutdown();
	release!(fixture.auth);
	await setImmediate();
	assert.equal(requests, 0);
	assert.equal(fixture.messages.length, 0);
});

test("failed image jobs release slots for later commands", async (t) => {
	const fixture = commandWorld(t);
	let requests = 0;
	t.mock.method(globalThis, "fetch", async () => { requests++; throw new Error("controlled network failure"); });
	for (let index = 0; index < 5; index++) {
		await fixture.run(`Image ${index}`);
		await setImmediate();
	}
	assert.equal(requests, 5);
	assert.equal(fixture.messages.length, 5);
	assert.equal(fixture.notices.filter(notice => notice.level === "warning").length, 0);
});
