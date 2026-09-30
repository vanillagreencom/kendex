import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import test from "node:test";
import { IMAGE_PREVIEW_CACHE_MAX_CHARS } from "../src/image-preview-cache.js";
import { IMAGE_SAVE_DISPLAY_MESSAGE_TYPE, registerOpenAICodexCustomProvider } from "../src/provider-shim.js";

const PNG_1X1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");

type Renderer = (message: unknown, options: unknown, theme: unknown) => { render(width: number): string[] };

function imageRenderer(): Renderer {
	const renderers = new Map<string, Renderer>();
	const pi = {
		registerProvider() {},
		on() {},
		registerMessageRenderer(type: string, renderer: Renderer) { renderers.set(type, renderer); },
	};
	registerOpenAICodexCustomProvider(pi as never, { getCurrentCwd: () => process.cwd() });
	const renderer = renderers.get(IMAGE_SAVE_DISPLAY_MESSAGE_TYPE);
	assert.ok(renderer);
	return renderer;
}

/** A PNG whose file is `bytes` long: a 1x1 image padded after its end. */
function writePng(dir: string, name: string, bytes: number): string {
	const path = join(dir, name);
	writeFileSync(path, Buffer.concat([PNG_1X1, Buffer.alloc(Math.max(0, bytes - PNG_1X1.length))]));
	return path;
}

function show(renderer: Renderer, path: string) {
	const message = { content: "image", details: { savedImages: [{ absolutePath: path, relativePath: path, outputFormat: "png", callId: "c", responseId: undefined, latestAbsolutePath: path, latestRelativePath: "" }] } };
	return renderer(message, { expanded: false }, undefined);
}

const hasDimensions = (lines: string[]) => lines.join("\n").includes("1x1");

/** Render until the background read has landed, as Pi's next redraws would. */
async function renderLoaded(component: { render(width: number): string[] }): Promise<string[]> {
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const lines = component.render(120);
		if (hasDimensions(lines)) return lines;
		// A real wait: the read is file I/O on the thread pool, not a microtask.
		await setTimeout(5);
	}
	assert.fail("image preview never loaded");
}

test("an image preview is read in the background, never inside a render", async (t) => {
	const dir = mkdtempSync(join(tmpdir(), "codex-image-preview-"));
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	const renderer = imageRenderer();
	const component = show(renderer, writePng(dir, "a.png", PNG_1X1.length));
	assert.equal(hasDimensions(component.render(120)), false);
	assert.equal(hasDimensions(await renderLoaded(component)), true);
});

test("previews past the cache bound are dropped, least recently shown first", async (t) => {
	const dir = mkdtempSync(join(tmpdir(), "codex-image-preview-"));
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	const renderer = imageRenderer();
	// Each preview holds 40% of the bound as base64, so two fit and three do not.
	const bytes = Math.ceil((IMAGE_PREVIEW_CACHE_MAX_CHARS * 0.4 * 3) / 4);
	const first = writePng(dir, "first.png", bytes);
	const second = writePng(dir, "second.png", bytes);
	const third = writePng(dir, "third.png", bytes);
	await renderLoaded(show(renderer, first));
	await renderLoaded(show(renderer, second));
	// Showing the first again makes the second the least recently shown.
	assert.equal(hasDimensions(show(renderer, first).render(120)), true);
	await renderLoaded(show(renderer, third));
	// A fresh message shows a cached preview at once and a dropped one without it.
	assert.deepEqual([first, second, third].map((path) => hasDimensions(show(renderer, path).render(120))), [true, false, true]);
});
