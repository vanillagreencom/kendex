import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";
import { clearPackageConfigCache, recordProjectTrust } from "../src/package-config.js";
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

type ModelRow = {
	name: string;
	route: keyof typeof routes;
	config: Record<string, unknown>;
	projectConfig?: Record<string, unknown>;
	savedModel?: string;
	expected: string;
	videoModel?: string;
	videoEnabled?: boolean;
};

const rows: ModelRow[] = [
	{ name: "no setting", route: "search", config: {}, expected: "gemini-3.5-flash-lite" },
	{ name: "no setting", route: "youtube", config: {}, expected: "gemini-3.8-flash" },
	{ name: "no setting", route: "local video", config: {}, expected: "gemini-3.8-flash" },
	{ name: "flat setting", route: "search", config: configured, expected: "set-search-model" },
	{ name: "flat setting", route: "youtube", config: configured, expected: "set-video-model" },
	{ name: "flat setting", route: "local video", config: configured, expected: "set-video-model" },
	{ name: "nested setting", route: "youtube", config: nested, expected: "nested-video-model" },
	{ name: "nested setting", route: "local video", config: nested, expected: "nested-video-model" },
	...[
		{ name: "flat/flat", config: { "video.geminiModel": "user-model" }, projectConfig: { "video.geminiModel": "project-model" } },
		{ name: "flat/nested", config: { "video.geminiModel": "user-model" }, projectConfig: { video: { geminiModel: "project-model" } } },
		{ name: "nested/flat", config: { video: { geminiModel: "user-model" } }, projectConfig: { "video.geminiModel": "project-model" } },
		{ name: "nested/nested", config: { video: { geminiModel: "user-model" } }, projectConfig: { video: { geminiModel: "project-model" } } },
	].flatMap((pair) => (["youtube", "local video"] as const).map((route) => ({ ...pair, name: `user/project ${pair.name}`, route, expected: "project-model" }))),
	...(["youtube", "local video"] as const).flatMap((route) => [
		{ name: "settings-screen save over nested model", route, config: nested, savedModel: " saved-video-model ", expected: "saved-video-model" },
		{ name: "blank flat model retains nested", route, config: { ...nested, "video.geminiModel": " " }, expected: "nested-video-model" },
		{ name: "invalid flat model retains nested", route, config: { ...nested, "video.geminiModel": 0 }, expected: "nested-video-model" },
	]),
	{ name: "model merge retains video enabled", route: "search", config: { video: { enabled: false, geminiModel: "user-model" } }, projectConfig: { "video.geminiModel": "project-model" }, expected: "gemini-3.5-flash-lite", videoModel: "project-model", videoEnabled: false },
	{ name: "same-file normalization retains video enabled", route: "search", config: { video: { enabled: false, geminiModel: "nested-video-model" }, "video.geminiModel": "flat-video-model" }, expected: "gemini-3.5-flash-lite", videoModel: "flat-video-model", videoEnabled: false },
];

for (const row of rows) {
	test(`Gemini model: ${row.route}, ${row.name}`, async (t) => {
		isolateEnvironment(t, settingsEnvironment);
		const root = tempDir(t);
		const user = join(root, "agent");
		const project = join(root, "project");
		mkdirSync(user);
		mkdirSync(join(project, ".pi"), { recursive: true });
		const userSettings = join(user, "settings.json");
		writeFileSync(userSettings, JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": row.config } } } }));
		if (row.projectConfig) writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": row.projectConfig } } } }));
		process.env.PI_CODING_AGENT_DIR = user;
		process.env.GEMINI_API_KEY = "gem";
		recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
		clearPackageConfigCache();
		if (row.savedModel !== undefined) {
			assert.equal(loadSettings(project).video.geminiModel, "nested-video-model");
			const saved = { ...row.config, ["video.geminiModel"]: row.savedModel };
			writeFileSync(userSettings, JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": saved } } } }));
			clearPackageConfigCache();
		}
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
		await routes[row.route](() => loadSettings(project), root);
		assert.deepEqual(models, [row.expected]);
		const settings = loadSettings(project);
		assert.equal(row.route === "search" ? settings.geminiSearchModel : settings.video.geminiModel, row.expected);
		if (row.videoModel !== undefined) assert.equal(settings.video.geminiModel, row.videoModel);
		if (row.videoEnabled !== undefined) assert.equal(settings.video.enabled, row.videoEnabled);
	});
}
