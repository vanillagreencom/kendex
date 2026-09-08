import type { Dispatcher } from "undici";
import assert from "node:assert/strict";
import test from "node:test";
import { webSocketOptionsForUrl } from "../src/provider-shim.js";
import { environment, noProxyEnvironment } from "./helpers/world.js";

test("websocket options carry the proxy dispatcher and authorization", async (t) => {
	environment(t, { ...noProxyEnvironment, HTTPS_PROXY: "http://proxy.example:8080" });
	const options = await webSocketOptionsForUrl("wss://chatgpt.com/backend-api/codex/responses", { Authorization: "Bearer token" });
	t.after(async () => { await (options.dispatcher as Dispatcher | undefined)?.close(); });
	assert.equal(options.headers.Authorization, "Bearer token");
	assert.equal("proxy" in options, false);
	assert.ok(options.dispatcher);
});
