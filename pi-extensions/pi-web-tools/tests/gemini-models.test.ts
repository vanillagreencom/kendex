import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";
import { clearPackageConfigCache } from "../src/package-config.js";
import { loadSettings } from "../src/settings.js";
import { endWebContentSession } from "../src/storage.js";
import { createWebFetchToolDefinition } from "../src/tools/web-fetch.js";
import { createWebSearchToolDefinition } from "../src/tools/web-search.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

beforeEach(endWebContentSession);
afterEach(endWebContentSession);

const ctx = { cwd: process.cwd(), model: { provider: "anthropic" } } as any;
const answer = () => Response.json({ candidates: [{ content: { parts: [{ text: "Answer" }] }, groundingMetadata: { groundingChunks: [{ web: { uri: "https://example.com/a" } }] } }] });

const routes = {
	search: async (getSettings: () => any) => {
		await createWebSearchToolDefinition({ appendEntry() {} } as any, getSettings).execute("call", { query: "q", provider: "gemini" }, undefined, undefined, ctx);
	},
	youtube: async (getSettings: () => any) => {
		await createWebFetchToolDefinition({ appendEntry() {} } as any, getSettings).execute("call", { urls: ["https://youtu.be/abc123XYZ_-"], videoMode: "understand" }, undefined, undefined, ctx);
	},
	"local video": async (getSettings: () => any, root: string) => {
		const clip = join(root, "clip.mp4");
		writeFileSync(clip, "video");
		await createWebFetchToolDefinition({ appendEntry() {} } as any, getSettings).execute("call", { urls: [clip] }, undefined, undefined, ctx);
	},
};

// The extension manager saves each schema.key as a flat property.
const configured = { geminiSearchModel: "set-search-model", "video.geminiModel": "set-video-model" };
const nested = { video: { geminiModel: "nested-video-model" } };

for (const row of [
	{ route: "search", config: {}, expected: "gemini-3.5-flash-lite" },
	{ route: "youtube", config: {}, expected: "gemini-3.8-flash" },
	{ route: "local video", config: {}, expected: "gemini-3.8-flash" },
	{ route: "search", config: configured, expected: "set-search-model" },
	{ route: "youtube", config: configured, expected: "set-video-model" },
	{ route: "local video", config: configured, expected: "set-video-model" },
	{ route: "youtube", config: nested, expected: "nested-video-model" },
	{ route: "local video", config: nested, expected: "nested-video-model" },
] as const) {
	test(`Gemini model: ${row.route}, ${row.config === nested ? "nested setting" : Object.keys(row.config).length ? "flat setting" : "no setting"}`, async (t) => {
		isolateEnvironment(t, settingsEnvironment);
		const root = tempDir(t);
		const user = join(root, "agent");
		mkdirSync(user);
		writeFileSync(join(user, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": row.config } } } }));
		process.env.PI_CODING_AGENT_DIR = user;
		process.env.GEMINI_API_KEY = "gem";
		clearPackageConfigCache();
		const models: string[] = [];
		t.mock.method(globalThis, "fetch", async (input: URL | string | Request) => {
			const url = new URL(String(input));
			const model = url.pathname.match(/\/models\/([^/:]+):generateContent$/)?.[1];
			if (model) {
				models.push(model);
				return answer();
			}
			if (url.pathname === "/upload/v1beta/files") return new Response("{}", { headers: { "x-goog-upload-url": "https://upload.example/session" } });
			if (url.hostname === "upload.example") return Response.json({ file: { uri: "https://generativelanguage.googleapis.com/v1beta/files/clip" } });
			throw new Error(`unexpected endpoint ${url.href}`);
		});
		await routes[row.route](() => loadSettings(root), root);
		assert.deepEqual(models, [row.expected]);
	});
}
