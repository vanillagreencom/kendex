import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { type AgentSession, createAgentSession, DefaultResourceLoader, type ExtensionAPI, type ExtensionBindings, type ExtensionFactory, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";

/* A whole Pi session in process, on the Pi this package's test script
 * installs, with a scripted model in place of a provider. */

const PROVIDER = "pi-hooks-faux";
const MODEL = "scripted";

/**
 * The model: it runs the command an opening `RUN: ` prompt names, and ends
 * every other turn at once. Each request's last message is pushed to
 * `prompts` as `<role>: <text>`, so a case reads what the model was handed.
 * `requests`, where supplied, keeps all messages of each model request.
 */
function scriptedModel(pi: ExtensionAPI, prompts: string[], requests?: string[][]): void {
	const core = createFauxCore({ api: PROVIDER, provider: PROVIDER, models: [{ id: MODEL, contextWindow: 200_000, maxTokens: 1_000 }] });
	const answer = (context: { messages: { role: string; content: unknown }[] }) => {
		const messages = context.messages.map((message) => ({
			role: message.role,
			text: typeof message.content === "string" ? message.content : (message.content as { text?: string }[]).map((part) => part.text ?? "").join("\n"),
		}));
		requests?.push(messages.map((message) => `${message.role}: ${message.text}`));
		const last = messages.at(-1)!;
		const text = last.text;
		prompts.push(`${last.role}: ${text}`);
		if (last.role === "user" && text.startsWith("RUN: ")) return fauxAssistantMessage([fauxToolCall("bash", { command: text.slice(5) })], { stopReason: "toolUse" });
		return fauxAssistantMessage([fauxText("done")]);
	};
	core.setResponses(Array.from({ length: 30 }, () => answer));
	pi.registerProvider(PROVIDER, {
		api: core.api as never,
		baseUrl: "http://pi-hooks-faux.invalid",
		apiKey: "unused",
		streamSimple: core.streamSimple as never,
		models: [{ id: MODEL, name: MODEL, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 1_000 }],
	});
}

/**
 * A session in `cwd` under the Pi agent directory `agentDir`, loading the
 * extension entries `paths` and nothing else from disk, beside the scripted
 * model and any `factories` a case adds. Session start has been emitted and
 * the model chosen, as every Pi mode does before its first prompt; the caller
 * disposes the session.
 */
export async function startSession(options: {
	cwd: string;
	agentDir: string;
	paths: string[];
	prompts: string[];
	factories?: ExtensionFactory[];
	requests?: string[][];
	bindings?: ExtensionBindings;
	settingsManager?: SettingsManager;
}): Promise<AgentSession> {
	const settingsManager = options.settingsManager ?? SettingsManager.inMemory({ compaction: { enabled: false } });
	const resourceLoader = new DefaultResourceLoader({
		cwd: options.cwd,
		agentDir: options.agentDir,
		settingsManager,
		noExtensions: true,
		noSkills: true,
		noPromptTemplates: true,
		noThemes: true,
		noContextFiles: true,
		additionalExtensionPaths: options.paths,
		extensionFactories: [(pi) => scriptedModel(pi, options.prompts, options.requests), ...(options.factories ?? [])],
	});
	await resourceLoader.reload();
	const { session } = await createAgentSession({
		cwd: options.cwd,
		agentDir: options.agentDir,
		resourceLoader,
		sessionManager: SessionManager.inMemory(options.cwd),
		settingsManager,
		tools: ["bash"],
	});
	try {
		await session.bindExtensions(options.bindings ?? {});
		await session.setModel(session.modelRuntime.getModel(PROVIDER, MODEL)!);
	} catch (error) {
		session.dispose();
		throw error;
	}
	return session;
}
