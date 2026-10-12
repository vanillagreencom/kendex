// Plain Bun child: the package test preload does not replace Pi's real SDKs.
import type { ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { initTheme } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { generateQolSummary } from "../extensions/qol/compaction.ts";
import { runHandoff } from "../extensions/qol/handoff.ts";
import { generateAutoRenameName } from "../extensions/qol/session-rename.ts";

interface Scenario {
	provider: string;
	api: "openai-completions" | "anthropic-messages";
	purpose: "compaction" | "branch-summary" | "session-search" | "handoff" | "auto-name";
	enabled: boolean;
	refuse?: boolean;
}

const row: Scenario = JSON.parse(process.argv[2]);
const root = process.env.PI_CODING_AGENT_DIR!;
const title = "Private session summary";
const requests: Array<{ path: string; body: Record<string, unknown> }> = [];

function sse(type: string, data: unknown): string {
	return `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
}

const server = Bun.serve({
	hostname: "127.0.0.1",
	port: 0,
	async fetch(request) {
		requests.push({ path: new URL(request.url).pathname, body: await request.json() as Record<string, unknown> });
		if (row.refuse) return Response.json({ error: { message: "No compliant provider", type: "no_providers_available" } }, { status: 400 });
		const stream = row.api === "openai-completions"
			? `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0, model: "fixture", choices: [{ index: 0, delta: { role: "assistant", content: title }, finish_reason: null }] })}\n\ndata: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 0, model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`
			: sse("message_start", { type: "message_start", message: { id: "fixture", type: "message", role: "assistant", model: "fixture", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 0 } } })
				+ sse("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } })
				+ sse("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: title } })
				+ sse("content_block_stop", { type: "content_block_stop", index: 0 })
				+ sse("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } })
				+ sse("message_stop", { type: "message_stop" });
		return new Response(stream, { headers: { "content-type": "text/event-stream" } });
	},
});

try {
	// Pi initializes this global theme before it opens a custom UI. The plain
	// child must do the same before BorderedLoader formats its cancel hint.
	if (row.purpose === "handoff") initTheme("dark", false);
	writeFileSync(join(root, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": {
		"gatewayPrivacy.enabled": row.enabled,
		"compaction.model": `${row.provider}/fixture`,
		"sessionAutoRename.model": `${row.provider}/fixture`,
		"sessionAutoRename.fallbackModel": "",
		"handoffReviewPrompt": false,
	} } } } }));
	const model = {
		type: "chat", provider: row.provider, api: row.api, id: "fixture", name: "fixture", reasoning: false,
		baseUrl: `http://127.0.0.1:${server.port}${row.api === "openai-completions" ? "/v1" : ""}`,
		contextWindow: 200_000, maxTokens: 8192, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		...(row.provider === "openrouter" ? { compat: { openRouterRouting: { order: ["fixture-provider"] } } } : {}),
	};
	const ctx = {
		cwd: root, hasUI: row.purpose === "handoff", isProjectTrusted: () => false,
		// Nested summaries can use a different provider from the main agent.
		model: row.purpose === "handoff" ? model : { provider: row.provider === "openai" ? "openrouter" : "openai", id: "main-agent" },
		modelRegistry: {
			find: (provider: string, id: string) => provider === model.provider && id === model.id ? model : undefined,
			getApiKeyAndHeaders: async () => ({ ok: true, apiKey: "fixture-key" }),
		},
		sessionManager: {
			getSessionFile: () => undefined,
			buildSessionContext: () => ({ messages: [{ role: "user", content: "private fixture conversation", timestamp: 0 }] }),
		},
		ui: {
			notify() {},
			custom: (factory: (tui: unknown, theme: unknown, keys: unknown, done: (value: unknown) => void) => { dispose(): void }) => new Promise((resolve) => {
				const component = factory({ requestRender() {} }, { fg: (_color: string, text: string) => text }, {}, (value) => { component.dispose(); resolve(value); });
			}),
		},
		newSession: async () => ({ cancelled: false }),
	} as unknown as ExtensionCommandContext;
	let result: unknown;
	let outcome = "completed";
	try {
		if (row.purpose === "handoff") await runHandoff("continue the private task", ctx);
		else if (row.purpose === "auto-name") result = await generateAutoRenameName("private fixture conversation", ctx);
		else result = await generateQolSummary(ctx, { conversationText: "private fixture conversation", purpose: row.purpose });
	} catch (error) {
		if (!(error instanceof Error)) throw error;
		outcome = "error";
	}
	console.log(JSON.stringify({ outcome, result, requests }));
} finally {
	server.stop(true);
}
