import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { codexChildEnvironment } from "./codex-environment.js";
import { CodexProtocolClient } from "./json-rpc.js";
import { INITIALIZE_PARAMS, type CodexModel, type JsonObject } from "./protocol.js";

const execFileAsync = promisify(execFile);
export const SUPPORTED_CODEX_VERSION = "0.154.0";

export const APP_SERVER_ARGS = [
	"app-server",
	"--stdio",
	"--disable", "shell_tool",
	"--disable", "apps",
	"--disable", "plugins",
	"--disable", "remote_plugin",
	"--disable", "multi_agent",
	"--disable", "browser_use",
	"--disable", "computer_use",
	"--disable", "image_generation",
	"--disable", "view_image",
	"--disable", "sleep_tool",
	"--disable", "hooks",
	"-c", 'web_search="disabled"',
] as const;

function object(value: unknown, key: string): JsonObject {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`codex-protocol-invalid-${key}`);
	}
	return value as JsonObject;
}

export async function assertSupportedCodex(
	executable: string,
	codexHome: string,
	env: NodeJS.ProcessEnv = process.env,
): Promise<void> {
	const childEnv = codexChildEnvironment(codexHome, env);
	const { stdout } = await execFileAsync(executable, ["--version"], {
		env: childEnv,
		encoding: "utf8",
		maxBuffer: 4096,
	});
	if (stdout.trim() !== `codex-cli ${SUPPORTED_CODEX_VERSION}`) {
		throw new Error(`codex-version-unsupported expected=${SUPPORTED_CODEX_VERSION}`);
	}
}

export async function startAppServer(
	executable: string,
	codexHome: string,
	env: NodeJS.ProcessEnv = process.env,
): Promise<CodexProtocolClient> {
	await assertSupportedCodex(executable, codexHome, env);
	const child = spawn(executable, [...APP_SERVER_ARGS], {
		env: codexChildEnvironment(codexHome, env),
		stdio: ["pipe", "pipe", "pipe"],
	});
	const client = new CodexProtocolClient(child);
	await client.request("initialize", INITIALIZE_PARAMS as unknown as JsonObject);
	client.notify("initialized");
	return client;
}

export async function listCodexModels(client: CodexProtocolClient): Promise<CodexModel[]> {
	const models: CodexModel[] = [];
	let cursor: string | null = null;
	do {
		const response = object(await client.request("model/list", {
			includeHidden: false,
			...(cursor === null ? {} : { cursor }),
		}), "model-list");
		if (!Array.isArray(response.data)) throw new Error("codex-protocol-invalid-model-list-data");
		for (const raw of response.data) {
			const model = object(raw, "model");
			const reasoningEfforts = Array.isArray(model.supportedReasoningEfforts)
				? model.supportedReasoningEfforts
				: [];
			if (
				typeof model.id !== "string"
				|| typeof model.model !== "string"
				|| typeof model.displayName !== "string"
				|| typeof model.description !== "string"
				|| typeof model.hidden !== "boolean"
				|| !Array.isArray(model.inputModalities)
				|| !Array.isArray(model.supportedReasoningEfforts)
				|| reasoningEfforts.some((entry) => {
					const effort = object(entry, "model-reasoning-effort");
					return typeof effort.reasoningEffort !== "string" || typeof effort.description !== "string";
				})
				|| typeof model.defaultReasoningEffort !== "string"
				|| typeof model.isDefault !== "boolean"
			) throw new Error("codex-protocol-invalid-model");
			models.push(model as unknown as CodexModel);
		}
		if (response.nextCursor !== null && typeof response.nextCursor !== "string") {
			throw new Error("codex-protocol-invalid-model-cursor");
		}
		cursor = response.nextCursor as string | null;
	} while (cursor !== null);
	return models;
}
