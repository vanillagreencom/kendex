// Login-free suites against the real Codex 0.163.0 app-server, driven through
// the bridge's own start path, with a mock model provider on 127.0.0.1.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { ARG_SENTINEL, ENV_SENTINEL, filesHolding, fixtureWorld, piModel } from "./lib/codex-fixture.mjs";
import { finish, readTool, system, toolResult, user } from "./lib/fake-client.mjs";
import { functionCall, message, offeredTools } from "./lib/mock-responses.mjs";

const FIXTURE_TIMEOUT = 60_000;

function captureStderr() {
	const lines = [];
	const write = process.stderr.write.bind(process.stderr);
	process.stderr.write = (chunk, ...rest) => {
		lines.push(chunk.toString());
		return write(chunk, ...rest);
	};
	return { text: () => lines.join(""), restore: () => (process.stderr.write = write) };
}

test("configured MCP servers stay off at start and at cold resume, and their values reach nothing the bridge writes", { timeout: FIXTURE_TIMEOUT }, async () => {
	const world = await fixtureWorld("mcp-off", {
		script: [
			[functionCall("read", { path: "fixture.txt" }, "call-1")],
			[message("first answer")],
			[message("second answer")],
		],
	});
	const stderr = captureStderr();
	const events = [];
	try {
		const model = piModel(world.model);
		const transcript = [system([readTool]), user("Read the fixture")];
		const first = world.newBridge();
		const toolUse = await finish(first.streamSimple(model, { messages: transcript }));
		assert.equal(toolUse.reason, "toolUse", toolUse.error?.errorMessage);
		assert.equal(toolUse.message.content.at(-1).name, "read");
		transcript.push(toolUse.message, toolResult("call-1", "FIXTURE-VALUE"));
		const answer = await finish(first.streamSimple(model, { messages: transcript }, { onProviderStreamEvent: (event) => void events.push(event) }));
		assert.equal(answer.reason, "stop", answer.error?.errorMessage);
		assert.equal(answer.message.content.at(-1).text, "first answer");
		const toolOutput = world.mock.requests[1].body.input.find((item) => item.type === "function_call_output");
		assert.equal(toolOutput.call_id, "call-1");
		assert.match(JSON.stringify(toolOutput.output), /FIXTURE-VALUE/);
		await first.close();

		// A fresh bridge and app-server: the cold resume path.
		transcript.push(answer.message, user("And again", 9));
		const second = world.newBridge();
		const resumed = await finish(second.streamSimple(model, { messages: transcript }));
		assert.equal(resumed.reason, "stop", resumed.error?.errorMessage);
		assert.equal(resumed.message.content.at(-1).text, "second answer");
		await second.close();

		const methods = world.sentMethods();
		assert.equal(methods.filter((method) => method === "thread/start").length, 1);
		assert.equal(methods.filter((method) => method === "thread/resume").length, 1);
		assert.equal(methods.filter((method) => method === "config/read").length, 2);
		assert.deepEqual(world.startedMarkers(), []);

		// The env and argument sentinels of both configured servers.
		const seen = [stderr.text(), JSON.stringify(events), JSON.stringify([toolUse, answer, resumed]), JSON.stringify(world.children.map(({ command, args, env }) => ({ command, args, env })))].join("\n");
		for (const sentinel of [ENV_SENTINEL, ARG_SENTINEL]) {
			assert.equal(seen.includes(sentinel), false, `${sentinel} reached the bridge's output, events or child argv`);
			assert.deepEqual(filesHolding(world.root, sentinel, [world.homeConfig, world.projectConfig]), [], `${sentinel} reached a file outside the config that declares it`);
		}
	} finally {
		stderr.restore();
		await world.close();
	}
});

test("a server that appears after the name read starts and the bridge stops the app-server", { timeout: FIXTURE_TIMEOUT }, async () => {
	const world = await fixtureWorld("mcp-late", { script: [[message("unreached")]] });
	try {
		world.onWrite((line) => {
			if (line.includes('"method":"thread/start"')) world.addLateServer();
		});
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Hello")] }));
		assert.equal(end.type, "error");
		assert.equal(end.error.errorMessage, "codex-mcp-started name=late_marker");
		const [appServer] = world.children;
		if (appServer.child.exitCode === null && appServer.child.signalCode === null) await new Promise((resolve) => appServer.child.once("exit", resolve));
		assert.equal(appServer.child.signalCode, "SIGKILL");
		assert.equal(world.mock.requests.length, 0);
		await bridge.close();
	} finally {
		await world.close();
	}
});

test("an enabled feature no review covers refuses the thread before any model request", { timeout: FIXTURE_TIMEOUT }, async () => {
	const world = await fixtureWorld("feature", { userConfig: "[features]\nmemories = true\n", script: [[message("unreached")]] });
	try {
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Hello")] }));
		assert.equal(end.error?.errorMessage, "codex-feature-unreviewed name=memories");
		assert.equal(world.mock.requests.length, 0);
		assert.equal(world.sentMethods().includes("turn/start"), false);
		await bridge.close();
	} finally {
		await world.close();
	}
});

test("Codex offers the model no native tool, and a native call it makes runs nothing", { timeout: FIXTURE_TIMEOUT }, async () => {
	const script = [];
	const world = await fixtureWorld("native", { script });
	const ran = join(world.root, "NATIVE-RAN");
	script.push(
		[
			functionCall("exec_command", { cmd: `touch ${ran}` }, "native-1"),
			functionCall("shell", { command: ["touch", ran] }, "native-2"),
			functionCall("apply_patch", { input: `*** Begin Patch\n*** Add File: ${ran}\n+x\n*** End Patch` }, "native-3"),
		],
		[message("after native")],
	);
	try {
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Run a command")] }));
		const offered = world.mock.requests.flatMap((request) => offeredTools(request.body));
		assert.ok(offered.includes("read"), `Pi's tool is offered: ${offered}`);
		for (const native of ["exec_command", "write_stdin", "shell", "apply_patch", "view_image", "web_search", "image_generation", "spawn_agent"]) {
			assert.equal(offered.some((name) => name.split(".").at(-1) === native), false, `${native} is offered: ${offered}`);
		}
		assert.equal(existsSync(ran), false);
		assert.equal(end.reason, "stop", end.error?.errorMessage);
		await bridge.close();
	} finally {
		await world.close();
	}
});

test("a sub-agent a model with collaboration tools spawns is refused", { timeout: FIXTURE_TIMEOUT }, async () => {
	const world = await fixtureWorld("subagent", {
		model: "gpt-6-sol",
		script: [[{ ...functionCall("spawn_agent", { task_name: "sub", message: "work outside Pi" }, "spawn-1"), namespace: "collaboration" }], [message("sub")], [message("parent")]],
	});
	try {
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Delegate")] }));
		assert.equal(end.type, "error");
		assert.match(end.error.errorMessage, /^codex-(native-item type=subAgentActivity|foreign-thread thread=\S+)$/);
		await bridge.close();
	} finally {
		await world.close();
	}
});
