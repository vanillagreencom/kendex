/**
 * Pi Session Bridge
 *
 * Project-local Pi extension that keeps the normal interactive TUI while exposing
 * a Unix-domain JSONL side channel for external controllers.
 *
 * Discovery:
 *   ${PI_BRIDGE_DIR:-/tmp/pi-session-bridge-$UID}/instances/<pid>.json
 *
 * Protocol:
 *   Clients connect to the advertised socket and send one JSON object per LF.
 *   The bridge replies with JSONL responses and broadcasts live Pi events.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

import { installPiActivityBridgePublisher } from "./activity-broker.js";
import { resolveSessionId } from "./child-session-id.js";

const PROTOCOL = "pi-session-bridge.v1";
const INSTALL_SYMBOL = Symbol.for("vstack.pi-session-bridge.installed");
const STATUS_KEY = "session-bridge";
const QUESTION_SERVICE_SYMBOL = Symbol.for("vstack.pi-questions.service");
const CONFIG_ID = "@vanillagreen/pi-session-bridge";
const DEFAULT_HISTORY_LIMIT = 500;
const DEFAULT_MAX_LINE_BYTES = 1024 * 1024;

type JsonObject = Record<string, unknown>;
type VstackConfig = Record<string, unknown>;
type Delivery = "auto" | "steer" | "followUp" | "now";

export interface SlashCommandInfoLike {
	name: string;
	source?: "extension" | "prompt" | "skill" | string;
	description?: string;
	sourceInfo?: { path?: string; baseDir?: string };
}

export interface SlashExpansion {
	expanded: boolean;
	kind?: "skill" | "prompt";
	command?: string;
	text?: string;
	error?: string;
}

export type SkillExpansionCache = Map<string, Map<string, string>>;

export interface SlashExpansionOptions {
	sessionId?: string;
	skillExpansionCache?: SkillExpansionCache;
}

interface ExecResultLike { stdout?: string; stderr?: string; code?: number | null; killed?: boolean }
export type ExecLike = (command: string, args: string[], options?: { timeout?: number }) => Promise<ExecResultLike>;

interface BridgeClient {
	socket: net.Socket;
	buffer: string;
	events: boolean;
}

const loadedSkillHashesBySession: SkillExpansionCache = new Map();

interface InstanceInfo {
	protocol: string;
	pid: number;
	hostname: string;
	cwd: string;
	sessionId?: string;
	sessionFile?: string;
	sessionName?: string;
	model?: { provider?: string; id?: string; name?: string };
	thinkingLevel?: string;
	isIdle?: boolean;
	hasPendingMessages?: boolean;
	socketPath: string;
	bridgeDir: string;
	startedAt: string;
	updatedAt: string;
	lastReason?: string;
	/** vstack#60: parent session id when this bridge runs in a spawned subagent pane. */
	parentSessionId?: string;
	/** vstack#60: PI_BRIDGE_CHILD_ROLE env value when set (e.g. 'subagent'). */
	childRole?: string;
}

interface QuestionService {
	listPending(): unknown[];
	reply(requestId: string, answers: unknown, source?: string): boolean;
	reject(requestId: string, source?: string): boolean;
	subscribe(listener: (event: unknown) => void): () => void;
}

function expandHome(input: string): string {
	if (input === "~") return os.homedir();
	if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
	return input;
}

function projectSettingsPath(cwd: string): string {
	let current = path.resolve(cwd);
	while (true) {
		const candidate = path.join(current, ".pi", "settings.json");
		if (fs.existsSync(candidate)) return candidate;
		if (fs.existsSync(path.join(current, ".pi")) || fs.existsSync(path.join(current, ".git")) || fs.existsSync(path.join(current, ".vstack-lock.json"))) return candidate;
		const parent = path.dirname(current);
		if (parent === current) return path.join(path.resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

function piSettingsPaths(cwd = process.cwd()): string[] {
	const userDir = path.resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
	return [path.join(userDir, "settings.json"), projectSettingsPath(cwd)];
}

function readVstackConfig(cwd?: string): VstackConfig {
	const merged: VstackConfig = {};
	for (const settingsPath of piSettingsPaths(cwd)) {
		if (!fs.existsSync(settingsPath)) continue;
		try {
			const parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
			const config = parsed?.vstack?.extensionManager?.config?.[CONFIG_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readVstackConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export default function sessionBridge(pi: ExtensionAPI) {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	const clients = new Set<BridgeClient>();
	const history: JsonObject[] = [];
	const historyLimit = readPositiveInt(process.env.PI_BRIDGE_HISTORY, settingNumber("historyLimit", DEFAULT_HISTORY_LIMIT));
	const bridgeDir = getBridgeDir();
	const instancesDir = path.join(bridgeDir, "instances");
	const socketPath = path.join(bridgeDir, `pi-${process.pid}.sock`);
	const registryPath = path.join(instancesDir, `${process.pid}.json`);
	const startedAt = new Date().toISOString();

	let server: net.Server | undefined;
	let currentCtx: ExtensionContext | undefined;
	let currentInfo: InstanceInfo | undefined;
	let heartbeat: NodeJS.Timeout | undefined;
	let exitHandler: (() => void) | undefined;
	let questionUnsubscribe: (() => void) | undefined;
	let activityUnsubscribe: (() => void) | undefined;
	let stopping = false;

	function getState(reason?: string): InstanceInfo {
		const ctx = currentCtx;
		const model = ctx?.model;
		const defaultId = callOptional(ctx?.sessionManager, "getSessionId");
		// vstack#60: subagent panes inherit the parent session id from
		// pi-core; synthesize a unique id when launched with the env vars
		// pi-agents-tmux sets on subagent spawn.
		const resolvedSession = resolveSessionId({ defaultId, pid: process.pid });
		return {
			protocol: PROTOCOL,
			pid: process.pid,
			hostname: os.hostname(),
			cwd: ctx?.cwd ?? process.cwd(),
			sessionId: resolvedSession.sessionId,
			sessionFile: callOptional(ctx?.sessionManager, "getSessionFile"),
			sessionName: callOptional(ctx?.sessionManager, "getSessionName") ?? pi.getSessionName?.(),
			model: model ? { provider: model.provider, id: model.id, name: model.name } : undefined,
			thinkingLevel: pi.getThinkingLevel?.(),
			isIdle: ctx?.isIdle?.(),
			hasPendingMessages: ctx?.hasPendingMessages?.(),
			socketPath,
			bridgeDir,
			startedAt,
			updatedAt: new Date().toISOString(),
			lastReason: reason,
			parentSessionId: resolvedSession.parentSessionId,
			childRole: resolvedSession.childRole,
		};
	}

	async function writeRegistry(reason?: string) {
		currentInfo = getState(reason);
		await fs.promises.mkdir(instancesDir, { recursive: true, mode: 0o700 });
		await fs.promises.writeFile(registryPath, `${JSON.stringify(currentInfo, null, 2)}\n`, { mode: 0o600 });
	}

	function getQuestionService(): QuestionService | undefined {
		const service = (globalThis as unknown as Record<PropertyKey, unknown>)[QUESTION_SERVICE_SYMBOL];
		if (!service || typeof service !== "object") return undefined;
		const candidate = service as Partial<QuestionService>;
		if (
			typeof candidate.listPending === "function" &&
			typeof candidate.reply === "function" &&
			typeof candidate.reject === "function" &&
			typeof candidate.subscribe === "function"
		) {
			return candidate as QuestionService;
		}
		return undefined;
	}

	function ensureQuestionSubscription() {
		if (questionUnsubscribe) return;
		const service = getQuestionService();
		if (!service) return;
		questionUnsubscribe = service.subscribe((event) => publish("question", event));
	}

	function requireQuestionService(): QuestionService {
		ensureQuestionSubscription();
		const service = getQuestionService();
		if (!service) throw new Error("pi-questions service is not available in this Pi runtime");
		return service;
	}

	function readRequestId(command: JsonObject): string {
		const value = command.requestId ?? command.request_id;
		if (typeof value !== "string" || value.trim().length === 0) throw new Error("Expected requestId/request_id");
		return value.trim();
	}

	function writeRegistrySoon(reason?: string) {
		writeRegistry(reason).catch((error) => {
			broadcast({ type: "bridge_error", error: stringifyError(error), where: "writeRegistry" });
		});
	}

	async function start(ctx: ExtensionContext, reason: string) {
		stopping = false;
		currentCtx = ctx;
		if (server) {
			writeRegistrySoon(reason);
			return;
		}

		await fs.promises.mkdir(bridgeDir, { recursive: true, mode: 0o700 });
		await fs.promises.mkdir(instancesDir, { recursive: true, mode: 0o700 });
		await unlinkIfExists(socketPath);

		server = net.createServer((socket) => addClient(socket));
		server.on("error", (error) => {
			broadcast({ type: "bridge_error", error: stringifyError(error), where: "server" });
		});

		await new Promise<void>((resolve, reject) => {
			server!.once("error", reject);
			server!.listen(socketPath, () => {
				server!.off("error", reject);
				resolve();
			});
		});

		await fs.promises.chmod(bridgeDir, 0o700).catch(() => undefined);
		await fs.promises.chmod(instancesDir, 0o700).catch(() => undefined);
		await writeRegistry(reason);

		heartbeat = setInterval(() => writeRegistrySoon("heartbeat"), settingNumber("heartbeatMs", 15_000, ctx.cwd));
		heartbeat.unref?.();

		exitHandler = () => cleanupSync();
		process.once("exit", exitHandler);

		if (ctx.hasUI) {
			if (settingBoolean("showStatus", true, ctx.cwd)) ctx.ui.setStatus(STATUS_KEY, `bridge:${process.pid}`);
			if (settingBoolean("notifyOnStart", false, ctx.cwd)) ctx.ui.notify(`Session bridge listening at ${socketPath}`, "info");
		}

		ensureQuestionSubscription();
		if (!activityUnsubscribe) {
			activityUnsubscribe = installPiActivityBridgePublisher("pi-session-bridge", (event) => publish("vstack_activity", event));
		}
		publish("bridge_start", { state: currentInfo });
	}

	async function stop(reason: string) {
		if (stopping) return;
		stopping = true;
		publish("bridge_stop", { reason });

		if (currentCtx?.hasUI) currentCtx.ui.setStatus(STATUS_KEY, undefined);
		if (heartbeat) clearInterval(heartbeat);
		heartbeat = undefined;
		questionUnsubscribe?.();
		questionUnsubscribe = undefined;
		activityUnsubscribe?.();
		activityUnsubscribe = undefined;

		for (const client of clients) {
			send(client, { type: "bridge_stop", reason });
			client.socket.end();
		}
		clients.clear();

		const closing = server;
		server = undefined;
		if (closing) {
			await new Promise<void>((resolve) => closing.close(() => resolve()));
		}

		if (exitHandler) process.off("exit", exitHandler);
		exitHandler = undefined;
		await unlinkIfExists(socketPath);
		await unlinkIfExists(registryPath);
		currentCtx = undefined;
		stopping = false;
	}

	function cleanupSync() {
		try {
			fs.rmSync(socketPath, { force: true });
			fs.rmSync(registryPath, { force: true });
		} catch {
			// Best-effort process-exit cleanup; registry clients also stale-check pid/socket.
		}
	}

	function addClient(socket: net.Socket) {
		const client: BridgeClient = { socket, buffer: "", events: true };
		clients.add(client);
		socket.setEncoding("utf8");
		send(client, { type: "bridge_hello", protocol: PROTOCOL, state: currentInfo ?? getState("connect") });

		socket.on("data", (chunk) => {
			client.buffer += chunk;
			if (Buffer.byteLength(client.buffer, "utf8") > settingNumber("maxLineBytes", DEFAULT_MAX_LINE_BYTES, currentCtx?.cwd)) {
				send(client, { type: "response", success: false, error: "Input line exceeds 1 MiB" });
				client.buffer = "";
				return;
			}

			while (true) {
				const newline = client.buffer.indexOf("\n");
				if (newline === -1) break;
				let line = client.buffer.slice(0, newline);
				client.buffer = client.buffer.slice(newline + 1);
				if (line.endsWith("\r")) line = line.slice(0, -1);
				if (!line.trim()) continue;
				handleLine(client, line).catch((error) => {
					send(client, { type: "response", success: false, error: stringifyError(error) });
				});
			}
		});

		socket.on("close", () => clients.delete(client));
		socket.on("error", () => clients.delete(client));
	}

	async function handleLine(client: BridgeClient, line: string) {
		let command: JsonObject;
		try {
			command = JSON.parse(line) as JsonObject;
		} catch (error) {
			send(client, { type: "response", success: false, command: "parse", error: stringifyError(error) });
			return;
		}

		const id = command.id;
		const type = typeof command.type === "string" ? command.type : undefined;
		ensureQuestionSubscription();
		try {
			switch (type) {
				case "ping":
					sendResponse(client, id, "ping", true, { protocol: PROTOCOL, state: getState("ping") });
					break;
				case "get_state":
				case "state":
					sendResponse(client, id, "get_state", true, getState("get_state"));
					break;
				case "history": {
					const requested = readPositiveInt(command.limit, historyLimit);
					sendResponse(client, id, "history", true, { events: history.slice(-Math.min(requested, historyLimit)) });
					break;
				}
				case "get_commands":
				case "commands":
					sendResponse(client, id, "get_commands", true, { commands: pi.getCommands() });
					break;
				case "questions":
				case "question_list": {
					const service = getQuestionService();
					sendResponse(client, id, "questions", true, {
						available: Boolean(service),
						questions: service?.listPending() ?? [],
					});
					break;
				}
				case "answer":
				case "question_reply": {
					const requestId = readRequestId(command);
					const service = requireQuestionService();
					service.reply(requestId, command.answers, "bridge");
					sendResponse(client, id, "answer", true, { answered: true, requestId });
					break;
				}
				case "reject":
				case "question_reject": {
					const requestId = readRequestId(command);
					const service = requireQuestionService();
					service.reject(requestId, "bridge");
					sendResponse(client, id, "reject", true, { rejected: true, requestId });
					break;
				}
				case "emit": {
					const message = typeof command.message === "string" ? command.message : "test";
					publish("bridge_emit", { message });
					sendResponse(client, id, "emit", true, { message });
					break;
				}
				case "subscribe":
					client.events = command.enabled !== false;
					sendResponse(client, id, "subscribe", true, { enabled: client.events });
					break;
				case "prompt":
				case "send":
					await sendPrompt(client, id, "prompt", command, "auto");
					break;
				case "steer":
					await sendPrompt(client, id, "steer", command, "steer");
					break;
				case "follow_up":
				case "followUp":
					await sendPrompt(client, id, "follow_up", command, "followUp");
					break;
				case "abort":
					await currentCtx?.abort?.();
					sendResponse(client, id, "abort", true, getState("abort"));
					break;
				case "shutdown":
					if (command.confirm !== true) {
						sendResponse(client, id, "shutdown", false, undefined, "Set confirm:true to shutdown this Pi session");
						break;
					}
					currentCtx?.shutdown?.();
					sendResponse(client, id, "shutdown", true, { requested: true });
					break;
				default:
					sendResponse(client, id, type ?? "unknown", false, undefined, `Unknown command type: ${type ?? "<missing>"}`);
			}
		} catch (error) {
			sendResponse(client, id, type ?? "unknown", false, undefined, stringifyError(error));
		}
	}

	async function sendPrompt(
		client: BridgeClient,
		id: unknown,
		commandName: string,
		command: JsonObject,
		defaultDelivery: Delivery,
	) {
		const content = command.content ?? command.message;
		if (typeof content !== "string" && !Array.isArray(content)) {
			sendResponse(client, id, commandName, false, undefined, "Expected string message or content array");
			return;
		}

		const requested = normalizeDelivery(command.deliverAs ?? command.streamingBehavior, defaultDelivery);
		const idle = currentCtx?.isIdle?.() ?? true;
		const deliverAs = requested === "auto" ? (idle ? undefined : "steer") : requested === "now" ? undefined : requested;
		const options = deliverAs ? { deliverAs } : undefined;

		// vstack#13: pi.sendUserMessage hardcodes expandPromptTemplates:
		// false, so bridge delivery recreates the slash resolver in two
		// safe pieces. Skills/prompt templates can be expanded from public
		// command metadata and still preserve steer/followUp. Extension/TUI
		// commands have no public handler API, so they go through this Pi
		// process's own tmux pane after resolving pane_id from process
		// ancestry. Never use `tmux display-message -p '#{pane_id}'` here:
		// it returns the active client pane and can misroute to another tab.
		if (typeof content === "string" && content.startsWith("/")) {
			const expanded = expandLoadedSlashContent(content, pi.getCommands() as SlashCommandInfoLike[], fs.readFileSync, {
				sessionId: currentInfo?.sessionId ?? getState("slash_expansion").sessionId ?? `pid:${process.pid}`,
				skillExpansionCache: loadedSkillHashesBySession,
			});
			if (expanded.expanded) {
				pi.sendUserMessage(expanded.text as never, options as never);
				sendResponse(client, id, commandName, true, {
					deliveredAs: deliverAs ?? "now",
					idleBeforeSend: idle,
					expandedAs: expanded.kind,
					expandedCommand: expanded.command,
				});
				return;
			}
			if (expanded.error) {
				sendResponse(client, id, commandName, false, undefined, `Slash expansion failed: ${expanded.error}`);
				return;
			}

			try {
				const exec = pi.exec.bind(pi) as ExecLike;
				const paneId = await resolveOwnTmuxPaneByParentChain(exec);
				await pasteAndSubmitToPane(exec, paneId, content);
				sendResponse(client, id, commandName, true, {
					deliveredAs: "tmuxPane",
					idleBeforeSend: idle,
					paneId,
				});
				return;
			} catch (error) {
				// Non-tmux / stale-pane / paste failure: preserve the old
				// behavior rather than fail the bridge request.
				pi.sendUserMessage(content as never, options as never);
				sendResponse(client, id, commandName, true, {
					deliveredAs: deliverAs ?? "now",
					idleBeforeSend: idle,
					slashDispatchFallback: "sendUserMessage",
					slashDispatchError: stringifyError(error),
				});
				return;
			}
		}

		pi.sendUserMessage(content as never, options as never);
		sendResponse(client, id, commandName, true, { deliveredAs: deliverAs ?? "now", idleBeforeSend: idle });
	}

	function publish(event: string, data: unknown) {
		const envelope = toJsonable({ type: "event", event, timestamp: new Date().toISOString(), data });
		history.push(envelope);
		if (history.length > historyLimit) history.splice(0, history.length - historyLimit);
		broadcast(envelope);
	}

	function broadcast(payload: JsonObject) {
		for (const client of clients) {
			if (client.events) send(client, payload);
		}
	}

	pi.registerCommand("bridge:status", {
		description: "Show the session bridge socket and registry location",
		handler: async (_args, ctx) => {
			currentCtx = ctx;
			await writeRegistry("bridge:status");
			ctx.ui.notify(`Bridge socket: ${socketPath}\nRegistry: ${registryPath}`, "info");
		},
	});

	pi.registerCommand("bridge:ping", {
		description: "Emit a session-bridge ping event (useful for external bridge tests)",
		handler: async (args, ctx) => {
			currentCtx = ctx;
			const text = args.trim() || "pong";
			publish("bridge_pong", { text });
			ctx.ui.notify(`Bridge ping: ${text}`, "info");
		},
	});

	pi.on("session_start", async (event, ctx) => {
		await start(ctx, event.reason ?? "session_start");
	});

	pi.on("session_shutdown", async (event) => {
		await stop(event.reason ?? "session_shutdown");
	});

	pi.on("input", async (event: any, ctx: ExtensionContext) => {
		currentCtx = ctx;
		publish("input", event);
		if (typeof event.text === "string" && event.text.startsWith("/bridge:ping")) {
			const text = event.text.slice("/bridge:ping".length).trim() || "pong";
			publish("bridge_pong", { text, source: event.source });
			if (ctx.hasUI) ctx.ui.notify(`Bridge ping: ${text}`, "info");
			return { action: "handled" as const };
		}
		return { action: "continue" as const };
	});

	for (const eventName of [
		"agent_start",
		"agent_end",
		"turn_start",
		"turn_end",
		"message_start",
		"message_update",
		"message_end",
		"tool_execution_start",
		"tool_execution_update",
		"tool_execution_end",
		"model_select",
		"thinking_level_select",
		"session_compact",
		"session_tree",
	] as const) {
		pi.on(eventName as never, async (event: unknown, ctx: ExtensionContext) => {
			currentCtx = ctx;
			if (eventName === "agent_start" || eventName === "agent_end" || eventName === "model_select" || eventName === "thinking_level_select") {
				writeRegistrySoon(eventName);
			}
			publish(eventName, event);
		});
	}
}

export function expandLoadedSlashContent(
	text: string,
	commands: SlashCommandInfoLike[],
	readFile: (filePath: string, encoding: BufferEncoding) => string = fs.readFileSync,
	options: SlashExpansionOptions = {},
): SlashExpansion {
	const parsed = parseSlashCommand(text);
	if (!parsed) return { expanded: false };

	const matches = commands.filter((entry) => entry.name === parsed.commandName);
	// Pi's prompt() checks extension commands before skill/template
	// expansion. Preserve that precedence when names collide.
	if (matches.some((entry) => entry.source === "extension")) return { expanded: false };

	if (parsed.commandName.startsWith("skill:")) {
		const skill = matches.find((entry) => entry.source === "skill");
		const sourcePath = skill?.sourceInfo?.path;
		if (!skill || typeof sourcePath !== "string" || sourcePath.length === 0) return { expanded: false };
		try {
			const skillName = parsed.commandName.slice("skill:".length);
			const raw = readFile(sourcePath, "utf8");
			const contentHash = shortSha256(raw);
			const sessionId = options.sessionId?.trim();
			const cache = options.skillExpansionCache;
			if (sessionId && cache) {
				const sessionCache = cache.get(sessionId);
				const cachedHash = sessionCache?.get(skillName);
				if (cachedHash === contentHash) {
					const invocation = parsed.argsString.trim();
					return {
						expanded: true,
						kind: "skill",
						command: parsed.commandName,
						text: invocation ? `Skill ${skillName} (previously loaded). Invocation: ${invocation}` : `Skill ${skillName} (previously loaded).`,
					};
				}
			}

			const body = stripFrontmatter(raw).trim();
			const baseDir = skill.sourceInfo?.baseDir || path.dirname(sourcePath);
			const block = `<skill name="${skillName}" location="${sourcePath}">\nReferences are relative to ${baseDir}.\n\n${body}\n</skill>`;
			if (sessionId && cache) {
				const sessionCache = cache.get(sessionId) ?? new Map<string, string>();
				sessionCache.set(skillName, contentHash);
				cache.set(sessionId, sessionCache);
			}
			return {
				expanded: true,
				kind: "skill",
				command: parsed.commandName,
				text: parsed.argsString.trim() ? `${block}\n\n${parsed.argsString.trim()}` : block,
			};
		} catch (error) {
			return { expanded: false, error: stringifyError(error) };
		}
	}

	const prompt = matches.find((entry) => entry.source === "prompt");
	const sourcePath = prompt?.sourceInfo?.path;
	if (!prompt || typeof sourcePath !== "string" || sourcePath.length === 0) return { expanded: false };
	try {
		const body = stripFrontmatter(readFile(sourcePath, "utf8"));
		return {
			expanded: true,
			kind: "prompt",
			command: parsed.commandName,
			text: substitutePromptArgs(body, parseCommandArgs(parsed.argsString)),
		};
	} catch (error) {
		return { expanded: false, error: stringifyError(error) };
	}
}

function shortSha256(content: string): string {
	return createHash("sha256").update(content).digest("hex").slice(0, 16);
}

function parseSlashCommand(text: string): { commandName: string; argsString: string } | null {
	if (!text.startsWith("/")) return null;
	const boundary = text.slice(1).search(/\s/);
	const boundaryIndex = boundary === -1 ? -1 : boundary + 1;
	const commandName = boundaryIndex === -1 ? text.slice(1) : text.slice(1, boundaryIndex);
	if (!commandName) return null;
	return { commandName, argsString: boundaryIndex === -1 ? "" : text.slice(boundaryIndex + 1) };
}

export function stripFrontmatter(content: string): string {
	const normalized = content.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
	if (!normalized.startsWith("---")) return normalized;
	const endIndex = normalized.indexOf("\n---", 3);
	if (endIndex === -1) return normalized;
	return normalized.slice(endIndex + 4).trim();
}

export function parseCommandArgs(argsString: string): string[] {
	const args: string[] = [];
	let current = "";
	let inQuote: string | null = null;
	for (let i = 0; i < argsString.length; i++) {
		const char = argsString[i]!;
		if (inQuote) {
			if (char === inQuote) inQuote = null;
			else current += char;
		} else if (char === '"' || char === "'") {
			inQuote = char;
		} else if (/\s/.test(char)) {
			if (current) {
				args.push(current);
				current = "";
			}
		} else {
			current += char;
		}
	}
	if (current) args.push(current);
	return args;
}

export function substitutePromptArgs(content: string, args: string[]): string {
	let result = content;
	result = result.replace(/\$(\d+)/g, (_match, num: string) => args[Number.parseInt(num, 10) - 1] ?? "");
	result = result.replace(/\$\{@:(\d+)(?::(\d+))?\}/g, (_match, startStr: string, lengthStr?: string) => {
		let start = Number.parseInt(startStr, 10) - 1;
		if (start < 0) start = 0;
		if (lengthStr) return args.slice(start, start + Number.parseInt(lengthStr, 10)).join(" ");
		return args.slice(start).join(" ");
	});
	const allArgs = args.join(" ");
	result = result.replace(/\$ARGUMENTS/g, allArgs);
	result = result.replace(/\$@/g, allArgs);
	return result;
}

export async function resolveOwnTmuxPaneByParentChain(
	exec: ExecLike,
	startPid = process.pid,
	maxDepth = 40,
): Promise<string> {
	if (!process.env.TMUX) throw new Error("not in tmux");
	const listed = await exec("tmux", ["list-panes", "-a", "-F", "#{pane_pid} #{pane_id}"], { timeout: 1000 });
	if (!execSucceeded(listed)) throw new Error(`tmux list-panes failed: ${listed.stderr || listed.stdout || "non-zero exit"}`);

	const ancestors = new Map<string, number>();
	let pid = String(startPid);
	for (let depth = 0; depth < maxDepth && pid && pid !== "1"; depth++) {
		if (!ancestors.has(pid)) ancestors.set(pid, depth);
		const ps = await exec("ps", ["-o", "ppid=", "-p", pid], { timeout: 1000 });
		if (!execSucceeded(ps)) break;
		const next = (ps.stdout ?? "").trim().split(/\s+/)[0] ?? "";
		if (!next || next === pid) break;
		pid = next;
	}

	let best: { paneId: string; depth: number } | undefined;
	for (const line of (listed.stdout ?? "").split(/\r?\n/)) {
		const [panePid, paneId] = line.trim().split(/\s+/);
		if (!panePid || !paneId || !/^%\d+$/.test(paneId)) continue;
		const depth = ancestors.get(panePid);
		if (depth === undefined) continue;
		if (!best || depth < best.depth) best = { paneId, depth };
	}
	if (best) return best.paneId;
	throw new Error("Unable to resolve own tmux pane");
}

export async function pasteAndSubmitToPane(exec: ExecLike, paneId: string, text: string): Promise<void> {
	const paste = await exec("tmux", ["send-keys", "-t", paneId, "-l", text], { timeout: 1000 });
	if (!execSucceeded(paste)) throw new Error(`tmux send-keys -l failed: ${paste.stderr || paste.stdout || "non-zero exit"}`);
	const enter = await exec("tmux", ["send-keys", "-t", paneId, "Enter"], { timeout: 1000 });
	if (!execSucceeded(enter)) throw new Error(`tmux send-keys Enter failed: ${enter.stderr || enter.stdout || "non-zero exit"}`);
}

function execSucceeded(result: ExecResultLike): boolean {
	return !result.killed && (result.code ?? 0) === 0;
}

function sendResponse(client: BridgeClient, id: unknown, command: string, success: boolean, data?: unknown, error?: string) {
	send(client, toJsonable({ type: "response", id, command, success, data, error }));
}

function send(client: BridgeClient, payload: unknown) {
	client.socket.write(`${JSON.stringify(toJsonable(payload))}\n`);
}

function normalizeDelivery(value: unknown, fallback: Delivery): Delivery {
	if (value === "auto" || value === "steer" || value === "followUp" || value === "now") return value;
	if (value === "follow_up" || value === "follow-up") return "followUp";
	return fallback;
}

function getBridgeDir() {
	if (process.env.PI_BRIDGE_DIR?.trim()) return path.resolve(process.env.PI_BRIDGE_DIR);
	const configured = settingString("bridgeDir", "");
	if (configured) return path.resolve(expandHome(configured));
	const uid = typeof process.getuid === "function" ? process.getuid() : os.userInfo().username;
	return path.join(os.tmpdir(), `pi-session-bridge-${uid}`);
}

async function unlinkIfExists(filePath: string) {
	try {
		await fs.promises.unlink(filePath);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
	}
}

function readPositiveInt(value: unknown, fallback: number) {
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number.parseInt(value, 10) : Number.NaN;
	return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

function stringifyError(error: unknown) {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
}

function toJsonable<T>(value: T): T {
	const seen = new WeakSet<object>();
	const text = JSON.stringify(value, (_key, nested) => {
		if (typeof nested === "bigint") return nested.toString();
		if (nested instanceof Error) return { name: nested.name, message: nested.message, stack: nested.stack };
		if (typeof nested === "function") return undefined;
		if (nested && typeof nested === "object") {
			if (seen.has(nested)) return "[Circular]";
			seen.add(nested);
		}
		return nested;
	});
	return (text === undefined ? undefined : JSON.parse(text)) as T;
}

function callOptional(target: unknown, method: string): string | undefined {
	if (!target || typeof target !== "object") return undefined;
	const candidate = (target as Record<string, unknown>)[method];
	if (typeof candidate !== "function") return undefined;
	const value = candidate.call(target);
	return typeof value === "string" ? value : undefined;
}
