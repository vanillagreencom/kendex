import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, type ExtensionAPI, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { join } from "node:path";

/** Load the real package manifests and run one scripted tool call without a network provider. */
export async function runBatchSession(options: {
	cwd: string;
	agentDir: string;
	renderer: string;
	batched: boolean;
}) {
	const model = (pi: ExtensionAPI) => {
		const core = createFauxCore({ api: "batch-faux", provider: "batch-faux", models: [{ id: "scripted", contextWindow: 200_000, maxTokens: 1_000 }] });
		core.setResponses([
			() => fauxAssistantMessage([fauxToolCall(options.batched ? "tool_batch" : "bash", options.batched
				? { calls: [{ tool: "bash", args: { command: "echo child-ran" } }] }
				: { command: "echo child-ran" })], { stopReason: "toolUse" }),
			() => fauxAssistantMessage([fauxText("done")]),
		]);
		pi.registerProvider("batch-faux", {
			api: core.api as never, baseUrl: "http://batch-faux.invalid", apiKey: "unused", streamSimple: core.streamSimple as never,
			models: [{ id: "scripted", name: "scripted", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 1_000 }],
		});
	};
	const resourceLoader = new DefaultResourceLoader({
		cwd: options.cwd, agentDir: options.agentDir, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
		additionalExtensionPaths: [join(import.meta.dir, "../../../../pi-hooks"), options.renderer], extensionFactories: [model],
	});
	await resourceLoader.reload();
	const errors = resourceLoader.getExtensions().errors;
	if (errors.length > 0) throw new Error(errors.map((error) => `${error.path}: ${error.error}`).join("\n"));
	const { session } = await createAgentSession({
		cwd: options.cwd, agentDir: options.agentDir, resourceLoader, sessionManager: SessionManager.inMemory(options.cwd),
		settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }), tools: ["bash", "tool_batch"],
	});
	try {
		await session.bindExtensions({});
		await session.setModel(session.modelRuntime.getModel("batch-faux", "scripted")!);
		await session.prompt("Run it.");
		const results = session.messages.filter((message) => message.role === "toolResult");
		if (results.length !== 1) throw new Error(`tool results=${results.length}`);
		return results[0]!;
	} finally {
		session.dispose();
	}
}
