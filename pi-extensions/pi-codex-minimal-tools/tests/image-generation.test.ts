import assert from "node:assert/strict";
import test from "node:test";
import { directImageGeneration } from "../src/tools/image-generation.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";

import { world } from "./helpers/world.js";

test("directImageGeneration omits deprecated response_format and passes abort signal", async (t) => {
	const { cwd } = world(t);
	const previousKey = process.env.OPENAI_API_KEY;
	const previousFetch = globalThis.fetch;
	const controller = new AbortController();
	let body: Record<string, unknown> = {};
	let seenSignal: AbortSignal | undefined;
	process.env.OPENAI_API_KEY = "test";
	globalThis.fetch = (async (_url: string | URL | Request, init?: RequestInit) => {
		body = JSON.parse(String(init?.body));
		seenSignal = init?.signal ?? undefined;
		return new Response(JSON.stringify({ data: [{ b64_json: Buffer.from("png").toString("base64") }] }), { status: 200, headers: { "content-type": "application/json" } });
	}) as typeof fetch;
	try {
		await directImageGeneration({ prompt: "test" }, cwd, { ...DEFAULT_SETTINGS, directImageApiFallback: true }, controller.signal);
		assert.equal("response_format" in body, false);
		assert.equal(seenSignal, controller.signal);
	} finally {
		if (previousKey === undefined) delete process.env.OPENAI_API_KEY;
		else process.env.OPENAI_API_KEY = previousKey;
		globalThis.fetch = previousFetch;
	}
});
