import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { saveOpenAICodexGeneratedImage } from "../src/provider-shim.js";
import { environment, world } from "./helpers/world.js";

test("saveOpenAICodexGeneratedImage writes generated images under the configured default output dir", async (t) => {
	const { cwd, agent } = world(t);
	environment(t, { PI_CODING_AGENT_DIR: agent });
	const encoded = Buffer.from("png-bytes").toString("base64");
		const saved = await saveOpenAICodexGeneratedImage(cwd, { responseId: "resp_123", callId: "ig_456", result: encoded, outputFormat: "png", imageModel: "gpt-image-2" });
		assert.match(saved.relativePath, /^\.pi[/\\]openai-codex-images[/\\][\dTZ-]+-[a-f0-9]{8}\.png$/);
		assert.equal(saved.latestRelativePath, path.join(".pi", "openai-codex-images", "latest.png"));
		assert.equal(saved.imageModel, "gpt-image-2");
		assert.deepEqual(await fs.readFile(saved.absolutePath), Buffer.from("png-bytes"));
		assert.deepEqual(await fs.readFile(saved.latestAbsolutePath), Buffer.from("png-bytes"));
});
