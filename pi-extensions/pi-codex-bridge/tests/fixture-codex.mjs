// Login-free suites against the real app-server of every supported Codex
// release, driven through the bridge's own start path, with a mock model
// provider on 127.0.0.1. The rows come from the manifest's supported list, so
// a listed release runs each row or fails.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { supportedCodexVersions } from "../src/codex-policy.ts";
import { ARG_SENTINEL, ENV_SENTINEL, assertFixtureRelease, codeModeOnlyModel, filesHolding, fixtureCodex, fixtureWorld, piModel } from "./lib/codex-fixture.mjs";
import { goneWithin } from "./lib/stub-codex.mjs";
import { finish, readTool, system, toolResult, user } from "./lib/fake-client.mjs";
import { customToolCall, functionCall, message, offeredTools } from "./lib/mock-responses.mjs";

// Each row stops its world from t.after, which runs even when the row times
// out, and `--test-force-exit` ends the file once every row has reported.
const FIXTURE_TIMEOUT = 30_000;

function captureStderr() {
	const lines = [];
	const write = process.stderr.write.bind(process.stderr);
	process.stderr.write = (chunk, ...rest) => {
		lines.push(chunk.toString());
		return write(chunk, ...rest);
	};
	return { text: () => lines.join(""), restore: () => (process.stderr.write = write) };
}

for (const version of supportedCodexVersions()) {
	/** A world whose bridges launch this release's fixture CLI. */
	const worldFor = (name, options = {}) => fixtureWorld(`${name}-${version}`, { ...options, codex: fixtureCodex(version) });

	test(`codex ${version}: the fixture CLI is that release`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("version");
		t.after(() => world.close());
		assertFixtureRelease(fixtureCodex(version), version, world.home);
	});

	test(`codex ${version}: configured MCP servers stay off at start and at cold resume, and their values reach nothing the bridge writes`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("mcp-off", {
			script: [
				[functionCall("read", { path: "fixture.txt" }, "call-1", "pi")],
				[message("first answer")],
				[message("second answer")],
			],
		});
		const stderr = captureStderr();
		t.after(async () => {
			stderr.restore();
			await world.close();
		});
		const events = [];
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
	});

	// The late server keeps running after stdin closes, so only the bridge's
	// stop, through Codex's own teardown, ends it.
	test(`codex ${version}: a server that appears after the name read starts, and the bridge stops it with the app-server`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("mcp-late", { script: [[message("unreached")]] });
		t.after(() => world.close());
		world.onWrite((line) => {
			if (line.includes('"method":"thread/start"')) world.addLateServer();
		});
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Hello")] }));
		assert.equal(end.type, "error");
		assert.equal(end.error.errorMessage, "codex-mcp-started name=late_marker");
		await bridge.close();
		const [appServer] = world.children;
		assert.ok(appServer.child.exitCode !== null || appServer.child.signalCode !== null, "the app-server exited");
		// Any late server Codex forked before it stopped exists once close has
		// waited for the app-server's exit.
		for (const pid of [...new Set([...world.markerPids(), ...world.runningMarkers()])]) {
			assert.equal(await goneWithin(pid), true, `MCP server ${pid} still runs after the breach and close`);
		}
		assert.equal(world.mock.requests.length, 0);
	});

	test(`codex ${version}: an enabled feature no review covers refuses the thread before any model request`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("feature", { userConfig: "[features]\nmemories = true\n", script: [[message("unreached")]] });
		t.after(() => world.close());
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Hello")] }));
		assert.equal(end.error?.errorMessage, "codex-feature-unreviewed name=memories");
		assert.equal(world.mock.requests.length, 0);
		assert.equal(world.sentMethods().includes("turn/start"), false);
		await bridge.close();
	});

	// No native tool Codex offers can change a file or run a command, and each
	// group of offered tools has its guard: ../DEVELOPMENT.md § Native tools
	// This row holds the environment tools on the default mock model, which
	// Codex offers no native tool but `apply_patch`: Codex answers the call
	// itself on a turn with no environment. Of the other groups, the code-mode
	// row holds only that exec lists no Pi tool and the sub-agent row only the
	// refused spawn. The contrast drops `environments` from thread/start
	// and turn/start, and there the same call starts a fileChange item, which the
	// bridge refuses. So the row fails when the empty environment stops keeping
	// the call from a patch, and when it stops seeing a started patch.
	test(`codex ${version}: Codex offers the default model no native tool but apply_patch, native calls start no item, write nothing and fail no turn, and without the empty environment the patch starts`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const script = [];
		const world = await worldFor("native", { script });
		t.after(() => world.close());
		const ran = join(world.project, "NATIVE-RAN");
		const patch = `*** Begin Patch\n*** Add File: ${ran}\n+x\n*** End Patch\n`;
		script.push(
			[
				functionCall("exec_command", { cmd: `touch ${ran}` }, "native-1"),
				functionCall("shell", { command: ["touch", ran] }, "native-2"),
				customToolCall("apply_patch", patch, "native-3"),
				functionCall("apply_patch", { input: patch }, "native-4"),
				functionCall("request_user_input", { questions: [{ id: "q", header: "Ask", question: "Which file?", options: [] }] }, "ask-1"),
			],
			[message("after native")],
		);
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Run a command")] }));
		await bridge.close();
		const offered = world.mock.requests.flatMap((request) => offeredTools(request.body));
		assert.ok(offered.includes("pi.read"), `Pi's tool is offered: ${offered}`);
		const native = offered.filter((name) => name !== "pi" && !name.startsWith("pi.") && name !== "apply_patch");
		assert.deepEqual(native, [], `Codex offers a native tool other than apply_patch: ${native}`);
		const answered = world.mock.requests[1]?.body.input.find((item) => item.type === "custom_tool_call_output" && item.call_id === "native-3");
		assert.ok(answered !== undefined, "Codex did not answer the apply_patch call to the model");
		const started = world.startedItemTypes();
		assert.equal(started.includes("fileChange") || started.includes("commandExecution"), false, `a native item started: ${started}`);
		assert.equal(existsSync(ran), false);
		assert.equal(end.reason, "stop", end.error?.errorMessage);

		script.push([customToolCall("apply_patch", patch, "native-contrast")]);
		const contrast = world.newBridge({ withoutEnvironments: true });
		const refused = await finish(contrast.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Patch a file")] }));
		await contrast.close();
		assert.equal(refused.error?.errorMessage, "codex-native-item type=fileChange");
	});

	// The second launch drops the direct-namespace setting and is the contrast:
	// there Codex nests Pi's tools inside `exec`, which fails closed with the
	// code-mode host off.
	test(`codex ${version}: a code-mode-only model sees Pi's tools as the direct pi namespace, outside exec, and its call reaches Pi`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const slug = "mock-code-mode";
		const world = await worldFor("code-mode", {
			model: slug,
			modelCatalog: [codeModeOnlyModel(slug)],
			script: [[functionCall("read", { path: "fixture.txt" }, "call-1", "pi")], [message("answer")], [message("contrast")]],
		});
		t.after(() => world.close());
		const model = piModel(world.model);
		const transcript = [system([readTool]), user("Read the fixture")];
		const frames = [];
		const bridge = world.newBridge();
		const toolUse = await finish(bridge.streamSimple(model, { messages: transcript }, { onProviderStreamEvent: (frame) => void frames.push(frame) }));
		assert.equal(toolUse.reason, "toolUse", toolUse.error?.errorMessage);
		assert.deepEqual(toolUse.message.content.at(-1), { type: "toolCall", id: "call-1", name: "read", arguments: { path: "fixture.txt" } });
		const call = frames.find((frame) => frame.method === "item/tool/call");
		assert.equal(call?.params.namespace, "pi");
		transcript.push(toolUse.message, toolResult("call-1", "FIXTURE-VALUE"));
		const answer = await finish(bridge.streamSimple(model, { messages: transcript }));
		assert.equal(answer.reason, "stop", answer.error?.errorMessage);
		assert.equal(answer.message.content.at(-1).text, "answer");
		assert.match(JSON.stringify(world.mock.requests[1].body.input.find((item) => item.type === "function_call_output")), /FIXTURE-VALUE/);
		await bridge.close();

		const execText = (request) => request.body.tools.find((tool) => tool.name === "exec")?.description ?? "";
		const direct = world.mock.requests[0];
		assert.ok(offeredTools(direct.body).includes("pi.read"), `pi.read is not offered directly: ${offeredTools(direct.body)}`);
		assert.ok(execText(direct).length > 0, "the model has no exec tool, so the plan is not code mode");
		assert.equal(execText(direct).includes("pi__read"), false, "exec lists Pi's read");

		const contrast = world.newBridge({ withoutSetting: 'features.code_mode.direct_only_tool_namespaces=["pi"]' });
		const nested = await finish(contrast.streamSimple(model, { messages: [system([readTool]), user("Contrast")] }));
		assert.equal(nested.reason, "stop", nested.error?.errorMessage);
		await contrast.close();
		const nestedRequest = world.mock.requests[2];
		assert.equal(offeredTools(nestedRequest.body).includes("pi.read"), false);
		assert.ok(execText(nestedRequest).includes("pi__read"), "without the setting exec does not list Pi's read");

		const [withSetting, withoutSetting] = world.enabledFeatures();
		assert.ok(withSetting.length > 0, "no feature list was read");
		assert.deepEqual(withSetting, withoutSetting);
	});

	// Codex refuses a thread whose declared tools include `mcp` or `mcp__*`.
	test(`codex ${version}: Pi tools named mcp and mcp__* start a thread under escaped names, and a call maps back to the Pi name`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("mcp-name", { script: [[functionCall("pi_mcp", { action: "list" }, "call-mcp", "pi")], [message("after mcp")]] });
		t.after(() => world.close());
		const tools = ["mcp", "mcp__srv__tool"].map((name) => ({ name, description: `Pi tool ${name}`, parameters: { type: "object", properties: { action: { type: "string" } } } }));
		const model = piModel(world.model);
		const transcript = [system(tools), user("List MCP servers")];
		const bridge = world.newBridge();
		const toolUse = await finish(bridge.streamSimple(model, { messages: transcript }));
		assert.equal(toolUse.reason, "toolUse", toolUse.error?.errorMessage);
		assert.deepEqual(toolUse.message.content.at(-1), { type: "toolCall", id: "call-mcp", name: "mcp", arguments: { action: "list" } });
		const offered = offeredTools(world.mock.requests[0].body);
		assert.ok(offered.includes("pi.pi_mcp") && offered.includes("pi.pi_mcp__srv__tool"), `escaped tools are not offered: ${offered}`);
		transcript.push(toolUse.message, toolResult("call-mcp", "MCP-LIST", "mcp"));
		const answer = await finish(bridge.streamSimple(model, { messages: transcript }));
		assert.equal(answer.reason, "stop", answer.error?.errorMessage);
		assert.match(JSON.stringify(world.mock.requests[1].body.input.find((item) => item.type === "function_call_output")), /MCP-LIST/);
		await bridge.close();
	});

	// The scripted spawn is the parent's first model response; a sub-agent's turn
	// would take the next scripted response. Only the parent's two model requests
	// may reach the mock: the spawn request and the parent's answer to its result.
	test(`codex ${version}: a sub-agent spawn on a code-mode model starts no thread and makes no model request`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("subagent", {
			model: "gpt-6-sol",
			script: [[functionCall("spawn_agent", { task_name: "sub", message: "work outside Pi" }, "spawn-1", "collaboration")], [message("parent")], [message("sub-agent")]],
		});
		t.after(() => world.close());
		const bridge = world.newBridge();
		const end = await finish(bridge.streamSimple(piModel(world.model), { messages: [system([readTool]), user("Delegate")] }));
		assert.equal(end.reason, "stop", end.error?.errorMessage);
		assert.equal(end.message.content.at(-1).text, "parent");
		assert.equal(world.mock.requests.length, 2);
		const offered = offeredTools(world.mock.requests[0].body);
		assert.ok(offered.includes("collaboration.spawn_agent"), `the code-mode catalog entry offers sub-agents: ${offered}`);
		assert.equal(offered.some((name) => /request_user_input/.test(name)), false, `request_user_input is offered: ${offered}`);
		await bridge.close();
	});

	test(`codex ${version}: another model's turn after Pi's boundary reaches Codex through a new thread`, { timeout: FIXTURE_TIMEOUT }, async (t) => {
		const world = await worldFor("other-provider", { script: [[message("first")], [message("after switch")]] });
		t.after(() => world.close());
		const model = piModel(world.model);
		const bridge = world.newBridge();
		const first = await finish(bridge.streamSimple(model, { messages: [system([readTool]), user("Q1")] }));
		assert.equal(first.reason, "stop", first.error?.errorMessage);
		const other = { role: "assistant", content: [{ type: "text", text: "OTHER-PROVIDER-ANSWER-MARKER" }], api: "anthropic-messages", provider: "anthropic", model: "claude", stopReason: "stop", usage: first.message.usage, timestamp: 5 };
		const next = await finish(bridge.streamSimple(model, { messages: [system([readTool]), user("Q1"), first.message, user("Q2", 4), other, user("Q3", 6)] }));
		assert.equal(next.reason, "stop", next.error?.errorMessage);
		assert.equal(world.sentMethods().filter((method) => method === "thread/start").length, 2);
		assert.match(JSON.stringify(world.mock.requests[1].body.input), /OTHER-PROVIDER-ANSWER-MARKER/);
		await bridge.close();
	});
}
