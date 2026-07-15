import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { complete } from "./pi-ai-compat.js";
import { BorderedLoader, type ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { acquireVstackModalLock } from "./bridges.js";
import { serializeMessagesForSummary } from "./compaction.js";
import { HANDOFF_SYSTEM_PROMPT } from "./constants.js";
import { settingBoolean } from "./settings.js";

function errorMessage(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return message.length > 180 ? `${message.slice(0, 179)}…` : message;
}

export async function runHandoff(args: string, ctx: ExtensionCommandContext): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify("handoff requires interactive mode", "error");
		return;
	}

	if (!ctx.model) {
		ctx.ui.notify("No model selected", "error");
		return;
	}

	const goal = args.trim();
	if (!goal) {
		ctx.ui.notify("Usage: /handoff <goal for new thread>", "error");
		return;
	}

	const built = (ctx.sessionManager as any).buildSessionContext?.();
	const messages = Array.isArray(built?.messages) ? built.messages as AgentMessage[] : [];

	if (messages.length === 0) {
		ctx.ui.notify("No conversation to hand off", "error");
		return;
	}

	const conversationText = serializeMessagesForSummary(messages);
	const currentSessionFile = ctx.sessionManager.getSessionFile();

	const releaseModalLock = acquireVstackModalLock();
	let result: string | null = null;
	let generationError: unknown;
	try {
		result = await ctx.ui.custom<string | null>((tui: any, theme: any, _kb: any, done: (value: string | null) => void) => {
			const loader = new BorderedLoader(tui, theme, "Generating handoff prompt...");
			loader.onAbort = () => done(null);

			const doGenerate = async () => {
				const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model!);
				if (!auth.ok || !auth.apiKey) {
					throw new Error(auth.ok ? `No API key for ${ctx.model!.provider}` : auth.error);
				}

				const userMessage: Message = {
					role: "user",
					content: [
						{
							type: "text",
							text: `## Conversation History\n\n${conversationText}\n\n## User's Goal for New Thread\n\n${goal}`,
						},
					],
					timestamp: Date.now(),
				};

				const response = await complete(
					ctx.model!,
					{ systemPrompt: HANDOFF_SYSTEM_PROMPT, messages: [userMessage] },
					{ apiKey: auth.apiKey, headers: auth.headers, signal: loader.signal },
				);

				if (response.stopReason === "aborted") return null;
				return response.content
					.filter((content): content is { type: "text"; text: string } => content.type === "text")
					.map((content) => content.text)
					.join("\n");
			};

			doGenerate()
				.then(done)
				.catch((error) => {
					generationError = error;
					done(null);
				});

			return loader;
		});
	} finally {
		releaseModalLock();
	}

	if (result === null) {
		if (generationError) ctx.ui.notify(`Handoff generation failed: ${errorMessage(generationError)}`, "error");
		else ctx.ui.notify("Cancelled", "info");
		return;
	}

	const prompt = settingBoolean("handoffReviewPrompt", true, ctx.cwd) ? await ctx.ui.editor("Edit handoff prompt", result) : result;
	if (prompt === undefined) {
		ctx.ui.notify("Cancelled", "info");
		return;
	}

	const newSessionResult = await ctx.newSession({
		parentSession: currentSessionFile,
		withSession: async (replacementCtx: any) => {
			replacementCtx.ui.setEditorText(prompt);
			replacementCtx.ui.notify("Handoff ready. Submit when ready.", "info");
		},
	});

	if (newSessionResult.cancelled) {
		ctx.ui.notify("New session cancelled", "info");
	}
}
