import assert from "node:assert/strict";
import test from "node:test";
import { proxyForWebSocketUrl } from "../src/provider-shim.js";
import { environment, noProxyEnvironment } from "./helpers/world.js";

for (const row of [
	{ name: "secure", url: "wss://chatgpt.com/backend-api/codex/responses", noProxy: undefined, expected: "http://proxy.example:8080" },
	{ name: "plain", url: "ws://localhost:8080/socket", noProxy: undefined, expected: "http://plain-proxy.example:8080" },
	{ name: "root bypass", url: "wss://chatgpt.com/backend-api/codex/responses", noProxy: ".chatgpt.com,localhost", expected: undefined },
	{ name: "subdomain bypass", url: "wss://api.chatgpt.com/backend-api/codex/responses", noProxy: ".chatgpt.com,localhost", expected: undefined },
]) {
	test(`websocket proxy: ${row.name}`, (t) => {
		environment(t, { ...noProxyEnvironment, HTTPS_PROXY: "http://proxy.example:8080", HTTP_PROXY: "http://plain-proxy.example:8080", NO_PROXY: row.noProxy });
		assert.equal(proxyForWebSocketUrl(row.url), row.expected);
	});
}
