import assert from "node:assert/strict";
import test from "node:test";
import { APP_SERVER_ARGS, SUPPORTED_CODEX_VERSION } from "../src/app-server.ts";
import { INITIALIZE_PARAMS } from "../src/protocol.ts";

test("app-server handshake opts into dynamic tools without attestation", () => {
	assert.deepEqual(INITIALIZE_PARAMS.capabilities, {
		experimentalApi: true,
		requestAttestation: false,
	});
	assert.equal(SUPPORTED_CODEX_VERSION, "0.154.0");
});

test("app-server launch disables the supported native execution features", () => {
	const disabled = APP_SERVER_ARGS.flatMap((value, index) => APP_SERVER_ARGS[index - 1] === "--disable" ? [value] : []);
	assert.deepEqual(disabled, [
		"shell_tool",
		"apps",
		"plugins",
		"remote_plugin",
		"multi_agent",
		"browser_use",
		"computer_use",
		"image_generation",
		"view_image",
		"sleep_tool",
		"hooks",
	]);
	assert.ok(APP_SERVER_ARGS.includes('web_search="disabled"'));
});
