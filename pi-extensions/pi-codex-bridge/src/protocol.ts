export type RequestId = number | string;
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export interface DynamicTool {
	type: "function";
	name: string;
	description: string;
	inputSchema: unknown;
}

export interface DynamicToolCall {
	threadId: string;
	turnId: string;
	callId: string;
	namespace: string | null;
	tool: string;
	arguments: JsonObject;
}

export interface CodexModel {
	id: string;
	model: string;
	displayName: string;
	description: string;
	hidden: boolean;
	inputModalities: string[];
	supportedReasoningEfforts: Array<{ reasoningEffort: string }>;
	defaultReasoningEffort: string;
	isDefault: boolean;
}

export type ServerMessage = {
	id?: RequestId;
	method?: string;
	params?: JsonObject;
	result?: unknown;
	error?: unknown;
};

export const INITIALIZE_PARAMS = {
	clientInfo: {
		name: "pi_codex_bridge",
		title: "Pi Codex bridge",
		version: "1.0.0",
	},
	capabilities: {
		experimentalApi: true,
		requestAttestation: false,
	},
} as const;
