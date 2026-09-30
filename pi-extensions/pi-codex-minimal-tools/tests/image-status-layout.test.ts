import assert from "node:assert/strict";
import test from "node:test";
import { setImmediate } from "node:timers/promises";
import { registerBackgroundImageGenerationCommand } from "../src/background-image-generation.js";
import { clearPackageConfigCache } from "../src/package-config.js";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { environment, world } from "./helpers/world.js";

test("image status reuses layout, refreshes elapsed time without reinstalling and clears on shutdown", async (t) => {
	const { cwd, agent } = world(t);
	environment(t, { PI_CODING_AGENT_DIR: agent });
	t.mock.timers.enable({ apis: ["Date", "setInterval"], now: 10000 });
	type Component = { render(width: number): string[]; invalidate(): void };
	let widget: Component | undefined;
	let installs = 0;
	let redraws = 0;
	let color = "";
	const theme = { fg: (_token: string, text: string) => color + text, bold: (text: string) => text };
	const commands = new Map<string, { handler(args: string, ctx: unknown): Promise<void> }>();
	let shutdown: (() => void) | undefined;
	registerBackgroundImageGenerationCommand({
		on(event: string, handler: () => void) { if (event === "session_shutdown") shutdown = handler; },
		registerMessageRenderer() {}, registerCommand(name: string, value: { handler(args: string, ctx: unknown): Promise<void> }) { commands.set(name, value); },
		sendMessage() {},
	} as never);
	const releases: Array<(auth: { ok: false; error: string }) => void> = [];
	const ctx = {
		cwd, model: { provider: "openai-codex", id: "gpt-5.4", input: ["text", "image"] },
		modelRegistry: { getApiKeyAndHeaders: () => new Promise(resolve => { releases.push(resolve); }) },
		ui: { notify() {}, setStatus() {}, setWidget(_key: string, factory?: (tui: unknown, theme: unknown) => Component) {
			installs++;
			widget = factory?.({ requestRender() { redraws++; } }, theme);
		} },
	};
	try {
		await commands.get("image-gen")!.handler("First image", ctx);
		assert.ok(widget);
		const first = widget.render(80);
		assert.equal(widget.render(80), first);
		assert.notEqual(widget.render(40), first);
		const narrow = widget.render(40);
		color = "\x1b[31m";
		widget.invalidate();
		assert.notEqual(widget.render(40), narrow);
		assert.ok(widget.render(40).join("\n").includes("\x1b[31m"));
		writeFileSync(join(agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-codex-minimal-tools": { glyphStyle: "ascii" } } } } }));
		clearPackageConfigCache();
		assert.ok(widget.render(40).join("\n").includes("+"));
		const oversized = widget.render(70000);
		assert.notEqual(widget.render(70000), oversized);
		t.mock.timers.tick(1000);
		assert.equal(installs, 1);
		assert.equal(redraws, 1);
		assert.ok(widget.render(80).join("\n").includes("1s"));
		await commands.get("image-gen")!.handler("Second image", ctx);
		assert.equal(installs, 1);
		assert.ok(widget.render(80).join("\n").includes("2 running"));
		const beforeCompletion = widget.render(80);
		releases[0]!({ ok: false, error: "Controlled authentication failure" });
		await setImmediate();
		assert.notEqual(widget.render(80), beforeCompletion);
		assert.ok(widget.render(80).join("\n").includes("1 running"));
		shutdown!();
		assert.deepEqual(widget.render(80), []);
		const rendersAtShutdown = redraws;
		t.mock.timers.tick(1000);
		assert.equal(redraws, rendersAtShutdown);
		releases[1]!({ ok: false, error: "Controlled authentication failure" });
		await setImmediate();
		assert.equal(installs, 1);
	} finally {
		shutdown?.();
	}
});
