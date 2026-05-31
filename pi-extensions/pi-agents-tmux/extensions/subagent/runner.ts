import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { Message } from "@earendil-works/pi-ai";
import {
	formatSize,
	truncateHead,
	truncateTail,
	withFileMutationQueue,
	type AgentToolResult,
	type ExtensionAPI,
	type TruncationResult,
} from "@earendil-works/pi-coding-agent";
import type { AgentConfig } from "./agents.js";
import { sanitizeCwdSnapshotText, setGitExecFileForTests as setSnapshotGitExecFileForTests, snapshotCwdGitState } from "./cwd-snapshot.js";
import { getFinalOutput, stringifyError } from "./format.js";
import { safeFileName } from "./names.js";
import {
	getPiInvocation,
	PI_SUBAGENT_CHILD_PANE_ENV,
	writePromptToTempFile,
} from "./pane.js";
import {
	oneShotTranscriptPath,
} from "./paths.js";
import { randomHex } from "./random.js";
import {
	resultLimits,
	selectedEffortForAgent,
	selectedModelForAgent,
	selectedThinkingLevelForAgent,
	selectedToolsForAgent,
	normalizedPiToolName,
	settingBoolean,
} from "./settings.js";
import {
	guardReusedSessionBudget,
	isContextLengthExceededEnvelope,
	resolveBgSession,
	resultHasContextLengthExceeded,
	summarizeAttempt,
	type BgSessionSelection,
} from "./sessions.js";
import { createTaskId, emitSubagentEvent, tryEmitSubagentEvent } from "./tasks.js";
import { normalizePiStreamEvent } from "./transcripts.js";
import {
	DETAIL_STRING_MAX_CHARS,
	type CwdSnapshot,
	type PreparedSingleResult,
	type ResultLimits,
	type SingleResult,
	type SubagentDetails,
} from "./types.js";

export type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

type SpawnProcess = typeof spawn;
let spawnProcess: SpawnProcess = spawn;
const MAX_RESULT_DIAGNOSTICS = 12;
const BG_EXCLUDED_TOOLS = ["complete_subagent"];
const BG_EXCLUDED_TOOL_SET = new Set(BG_EXCLUDED_TOOLS.map(normalizedPiToolName));

export function setSingleAgentSpawnForTests(spawner?: SpawnProcess): void {
	spawnProcess = spawner ?? spawn;
}

export function setGitExecFileForTests(execFileOverride?: Parameters<typeof setSnapshotGitExecFileForTests>[0]): void {
	setSnapshotGitExecFileForTests(execFileOverride);
}

function appendResultDiagnostic(result: Pick<SingleResult, "diagnostics">, diagnostic: string): void {
	const compact = sanitizeCwdSnapshotText(diagnostic, { multiline: true }).replace(/\s+/g, " ").trim();
	if (!compact) return;
	const diagnostics = [...(result.diagnostics ?? [])];
	if (!diagnostics.includes(compact)) diagnostics.push(compact);
	result.diagnostics = diagnostics.slice(-MAX_RESULT_DIAGNOSTICS);
}

function transcriptFullStreamEnabled(): boolean {
	return /^(1|true|yes|on)$/i.test(process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL?.trim() ?? "");
}

function activeToolsForBgAgent(activeTools: string[]): string[] {
	return activeTools.filter((tool) => !BG_EXCLUDED_TOOL_SET.has(normalizedPiToolName(tool)));
}

function streamEventName(event: any): string | undefined {
	if (typeof event?.event === "string") return event.event;
	if (typeof event?.type === "string") return event.type;
	return undefined;
}

function shouldAppendTranscriptEvent(eventName: string | undefined, fullStream = transcriptFullStreamEnabled()): boolean {
	return fullStream || eventName !== "message_update";
}

interface AgentStartTranscriptMetadata {
	agent: string;
	model?: string;
	args: string[];
}

function transcriptMetadataArgs(args: string[]): string[] {
	const sanitized = [...args];
	if (sanitized.at(-1)?.startsWith("Task: ")) sanitized.pop();
	return sanitized;
}

function withAgentStartTranscriptMetadata(event: any, metadata: AgentStartTranscriptMetadata): any {
	if (!event || typeof event !== "object" || Array.isArray(event)) return event;
	const enriched = {
		agent: metadata.agent,
		model: metadata.model ?? null,
		args: transcriptMetadataArgs(metadata.args),
	};
	if (event.event && typeof event.event === "object" && !Array.isArray(event.event) && event.event.type === "agent_start") {
		return { ...event, event: { ...event.event, ...enriched } };
	}
	if (event.type === "event" && event.event === "agent_start") {
		const data = event.data && typeof event.data === "object" && !Array.isArray(event.data) ? event.data : {};
		return { ...event, data: { ...data, ...enriched } };
	}
	if (event.type === "agent_start") return { ...event, ...enriched };
	return event;
}

function eventContentValue(payload: any): unknown {
	if (payload && typeof payload === "object" && "content" in payload) return payload.content;
	if (payload?.message && typeof payload.message === "object" && "content" in payload.message) return payload.message.content;
	return undefined;
}

function contentHasTextPart(content: unknown): boolean {
	if (!Array.isArray(content)) return false;
	return content.some((part) => {
		if (!part || typeof part !== "object") return false;
		const candidate = part as { text?: unknown; type?: unknown };
		return candidate.type === "text" && typeof candidate.text === "string" && candidate.text.length > 0;
	});
}

function agentEndHasTextlessContent(payload: any): boolean {
	const content = eventContentValue(payload);
	if (content == null) return true;
	return Array.isArray(content) && !contentHasTextPart(content);
}

function malformedAgentEndContentDiagnostic(payload: any): string | undefined {
	const content = eventContentValue(payload);
	if (content == null || Array.isArray(content)) return undefined;
	return `compact-then-empty detector skipped malformed agent_end content: expected array/null/undefined, got ${typeof content}`;
}

function compactThenEmptySummary(cwdSnapshot?: CwdSnapshot): string {
	const base = "Subagent compacted and exited without a final text message; inspect the worker cwd before assuming failure.";
	if (!cwdSnapshot) return base;
	const dirty = cwdSnapshot.dirty ? "dirty" : "clean";
	return `${base} HEAD ${cwdSnapshot.head.slice(0, 12)} (${dirty}) ${cwdSnapshot.lastCommit.subject}`;
}

export function formatTruncationNotice(
	truncation: TruncationResult,
	fullOutputPath?: string,
	fullOutputError?: string,
	direction: "head" | "tail" = "head",
): string {
	const omittedLines = Math.max(0, truncation.totalLines - truncation.outputLines);
	const omittedBytes = Math.max(0, truncation.totalBytes - truncation.outputBytes);
	const shown = direction === "tail" ? `showing last ${truncation.outputLines}` : `showing ${truncation.outputLines}`;
	const artifact = fullOutputPath
		? ` Full output saved to: ${fullOutputPath}`
		: fullOutputError
			? ` Full output preservation failed: ${fullOutputError}`
			: "";
	return `[Output truncated (${direction}): ${shown} of ${truncation.totalLines} lines (${formatSize(
		truncation.outputBytes,
	)} of ${formatSize(truncation.totalBytes)}). ${omittedLines} lines (${formatSize(omittedBytes)}) omitted.${artifact}]`;
}

export async function writeFullOutputArtifact(
	runtimeRoot: string,
	agentName: string,
	label: string,
	text: string,
): Promise<{ error?: string; path?: string }> {
	const dir = path.join(runtimeRoot, "outputs", safeFileName(agentName || "subagent"));
	const filePath = path.join(
		dir,
		`${Date.now()}-${randomHex(8)}-${safeFileName(label || "output")}.txt`,
	);
	try {
		await withFileMutationQueue(filePath, async () => {
			await fs.promises.mkdir(dir, { recursive: true, mode: 0o700 });
			await fs.promises.writeFile(filePath, text, { encoding: "utf-8", mode: 0o600 });
		});
		return { path: filePath };
	} catch (error) {
		return { error: stringifyError(error) };
	}
}

export async function truncateForToolResult(
	text: string,
	runtimeRoot: string,
	cwd: string,
	agentName: string,
	label: string,
	direction: "head" | "tail" = "head",
	limits: ResultLimits = resultLimits(cwd),
): Promise<Omit<PreparedSingleResult, "result">> {
	if (!settingBoolean("truncateResults", true, cwd)) return { text };
	const truncation = (direction === "tail" ? truncateTail : truncateHead)(text, limits);
	if (!truncation.truncated) return { text: truncation.content };

	const artifact = settingBoolean("preserveFullOutput", true, cwd)
		? await writeFullOutputArtifact(runtimeRoot, agentName, label, text)
		: {};
	return {
		fullOutputError: artifact.error,
		fullOutputPath: artifact.path,
		text: `${truncation.content}\n\n${formatTruncationNotice(truncation, artifact.path, artifact.error, direction)}`,
		truncation,
	};
}

export function truncateForDetails(text: string, cwd?: string): string {
	if (!settingBoolean("truncateResults", true, cwd)) return text;
	const truncation = truncateHead(text, resultLimits(cwd));
	if (!truncation.truncated) return truncation.content;
	return `${truncation.content}\n\n[Output truncated in agent details: showing ${truncation.outputLines} of ${truncation.totalLines} lines (${formatSize(
		truncation.outputBytes,
	)} of ${formatSize(truncation.totalBytes)}).]`;
}

function sanitizeDetailValue(value: unknown, depth = 0): unknown {
	if (depth > 4) return "[Max detail depth reached]";
	if (value == null || typeof value === "number" || typeof value === "boolean") return value;
	if (typeof value === "string") {
		return value.length > DETAIL_STRING_MAX_CHARS
			? `${value.slice(0, DETAIL_STRING_MAX_CHARS)}… [detail string truncated]`
			: value;
	}
	if (Array.isArray(value)) return value.slice(0, 50).map((item) => sanitizeDetailValue(item, depth + 1));
	if (typeof value === "object") {
		const out: Record<string, unknown> = {};
		for (const [index, [key, nested]] of Object.entries(value as Record<string, unknown>).entries()) {
			if (index >= 80) {
				out["[truncated]"] = "detail object field cap reached";
				break;
			}
			out[key] = sanitizeDetailValue(nested, depth + 1);
		}
		return out;
	}
	return String(value);
}

function lastAssistantTextPart(messages: Message[]): { messageIndex: number; partIndex: number } | undefined {
	for (let messageIndex = messages.length - 1; messageIndex >= 0; messageIndex -= 1) {
		const message = messages[messageIndex];
		if (message.role !== "assistant") continue;
		for (let partIndex = message.content.length - 1; partIndex >= 0; partIndex -= 1) {
			const part = message.content[partIndex] as any;
			if (part?.type === "text" && typeof part.text === "string") return { messageIndex, partIndex };
		}
	}
	return undefined;
}

export function cloneMessagesForDetails(messages: Message[], finalOutputText: string | undefined, cwd?: string): Message[] {
	const final = lastAssistantTextPart(messages);
	const cloned: Message[] = [];
	messages.forEach((message, messageIndex) => {
		if (message.role !== "assistant") return;
		const content = message.content.map((part, partIndex) => {
			const candidate = part as any;
			if (candidate?.type === "text" && typeof candidate.text === "string") {
				const isFinal = final?.messageIndex === messageIndex && final?.partIndex === partIndex;
				return { ...candidate, text: isFinal && finalOutputText !== undefined ? finalOutputText : truncateForDetails(candidate.text, cwd) };
			}
			if (candidate?.type === "toolCall") {
				const next = { ...candidate };
				if ("arguments" in next) next.arguments = sanitizeDetailValue(next.arguments);
				if ("args" in next) next.args = sanitizeDetailValue(next.args);
				return next;
			}
			return candidate;
		});
		cloned.push({ ...message, content } as Message);
	});
	return cloned;
}

export async function prepareSingleResultForReturn(
	result: SingleResult,
	runtimeRoot: string,
	cwd: string,
	label: string,
	textOverride?: string,
	limits?: ResultLimits,
): Promise<PreparedSingleResult> {
	const finalOutput = getFinalOutput(result.messages);
	const isError = result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
	const rawText = textOverride ?? (finalOutput || (isError ? result.errorMessage || result.stderr : finalOutput));
	const direction = isError && !finalOutput ? "tail" : "head";
	const output = rawText
		? await truncateForToolResult(rawText, runtimeRoot, cwd, result.agent, label, direction, limits)
		: { text: rawText };
	const prepared: SingleResult = {
		...result,
		messages: cloneMessagesForDetails(result.messages, output.text || undefined, cwd),
	};
	if (isError && output.text && !prepared.errorMessage) prepared.errorMessage = output.text;
	if (output.truncation) {
		prepared.fullOutputError = output.fullOutputError;
		prepared.fullOutputPath = output.fullOutputPath;
		prepared.truncation = output.truncation;
	}
	return { ...output, result: prepared };
}

export function detailsWithTruncation(details: SubagentDetails, prepared: PreparedSingleResult): SubagentDetails {
	if (!prepared.truncation) return details;
	return {
		...details,
		fullOutputError: prepared.fullOutputError,
		fullOutputPath: prepared.fullOutputPath,
		truncation: prepared.truncation,
	};
}

export async function runSingleAgent(
	defaultCwd: string,
	runtimeRoot: string,
	agents: AgentConfig[],
	agentName: string,
	task: string,
	cwd: string | undefined,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	step: number | undefined,
	pi: ExtensionAPI,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
	sessionKey?: string,
): Promise<SingleResult> {
	const agent = agents.find((a) => a.name === agentName);

	if (!agent) {
		const available = agents.map((a) => `"${a.name}"`).join(", ") || "none";
		return {
			agent: agentName,
			agentSource: "unknown",
			task,
			exitCode: 1,
			messages: [],
			stderr: `Unknown agent: "${agentName}". Available agents: ${available}.`,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
			step,
		};
	}

	const selectedModel = selectedModelForAgent(agent, parentModel, defaultCwd);
	const selectedThinking = selectedThinkingLevelForAgent(parentThinkingLevel, defaultCwd);
	const selectedEffort = selectedEffortForAgent(agent, selectedModel, selectedThinking);
	const firstSession = resolveBgSession(runtimeRoot, agent.name, sessionKey);
	await fs.promises.mkdir(path.dirname(firstSession.path), { recursive: true, mode: 0o700 }).catch(() => undefined);

	const budgetGuard = firstSession.explicit
		? await guardReusedSessionBudget(firstSession.path, agent.name, selectedModel, cwd ?? defaultCwd)
		: undefined;
	if (budgetGuard && !budgetGuard.ok) {
		const errorMessage = budgetGuard.warning ?? `Refusing reused session for ${agent.name}: estimated context budget exceeded.`;
		return {
			agent: agentName,
			agentSource: agent.source,
			task,
			exitCode: 1,
			messages: [],
			stderr: errorMessage,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: budgetGuard.estimate.tokens, turns: 0 },
			model: selectedModel,
			effort: selectedEffort,
			sessionMode: "resumed",
			sessionKey: firstSession.key,
			sessionKeyExplicit: true,
			sessionPath: firstSession.path,
			ephemeralSession: false,
			stopReason: "session_budget_exceeded",
			errorMessage,
			step,
		};
	}

	const first = await runSingleAgentAttempt(
		defaultCwd,
		runtimeRoot,
		agent,
		agentName,
		task,
		cwd,
		selectedModel,
		selectedThinking,
		selectedEffort,
		step,
		pi,
		signal,
		onUpdate,
		makeDetails,
		firstSession,
		1,
	);
	if (budgetGuard?.warning) first.stderr = [budgetGuard.warning, first.stderr].filter(Boolean).join("\n");

	if (!resultHasContextLengthExceeded(first)) return first;

	const retrySession = resolveBgSession(runtimeRoot, agent.name);
	const warning = `Context length exceeded for ${agent.name} session ${firstSession.key}; retrying once with fresh session ${retrySession.key}.`;
	first.stderr = [first.stderr, warning].filter(Boolean).join("\n");
	first.errorMessage = first.errorMessage ?? warning;
	emitSubagentEvent(pi, "subagents:retrying", {
		mode: "oneshot",
		agent: agent.name,
		taskId: first.taskId,
		task,
		runtimeRoot,
		transcriptPath: first.transcriptPath,
		model: first.model,
		effort: first.effort,
		usage: first.usage,
		reason: "context_length_exceeded",
		retrySessionKey: retrySession.key,
	});

	const retry = await runSingleAgentAttempt(
		defaultCwd,
		runtimeRoot,
		agent,
		agentName,
		task,
		cwd,
		selectedModel,
		selectedThinking,
		selectedEffort,
		step,
		pi,
		signal,
		onUpdate,
		makeDetails,
		retrySession,
		2,
	);
	const attempts = [summarizeAttempt(first), summarizeAttempt(retry)];
	retry.attempts = attempts;
	const retryFailed = retry.exitCode !== 0 || retry.stopReason === "error" || retry.stopReason === "aborted" || resultHasContextLengthExceeded(retry);
	if (!retryFailed) {
		retry.stderr = [warning, retry.stderr].filter(Boolean).join("\n");
		return retry;
	}

	const retryError = retry.errorMessage || retry.stderr || "retry failed without output";
	const firstError = first.errorMessage || first.stderr || "first attempt failed without output";
	const combinedError = [
		`Context length exceeded for ${agent.name}; retry with fresh session also failed.`,
		first.errorEnvelope ? `First raw error envelope: ${first.errorEnvelope}` : "",
		retry.errorEnvelope ? `Retry raw error envelope: ${retry.errorEnvelope}` : "",
		`First attempt (${first.sessionKey ?? firstSession.key}) exit ${first.exitCode}: ${firstError}`,
		`Retry attempt (${retry.sessionKey ?? retrySession.key}) exit ${retry.exitCode}: ${retryError}`,
	].filter(Boolean).join("\n");
	retry.exitCode = retry.exitCode === 0 ? 1 : retry.exitCode;
	retry.errorMessage = combinedError;
	retry.stderr = [warning, combinedError, retry.stderr].filter(Boolean).join("\n");
	return retry;
}

async function runSingleAgentAttempt(
	defaultCwd: string,
	runtimeRoot: string,
	agent: AgentConfig,
	agentName: string,
	task: string,
	cwd: string | undefined,
	selectedModel: string | undefined,
	selectedThinking: string | undefined,
	selectedEffort: string | undefined,
	step: number | undefined,
	pi: ExtensionAPI,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
	session: BgSessionSelection,
	attempt: number,
): Promise<SingleResult> {
	const args: string[] = ["--mode", "json", "-p", "--name", agent.name, "--session", session.path];
	if (selectedModel) args.push("--model", selectedModel);
	if (selectedThinking && selectedThinking !== "off") args.push("--thinking", selectedThinking);
	args.push("--exclude-tools", BG_EXCLUDED_TOOLS.join(","));
	const inheritedActiveTools = pi.getActiveTools?.() ?? [];
	const selectedTools = selectedToolsForAgent(agent, defaultCwd, [], activeToolsForBgAgent(inheritedActiveTools));
	if (selectedTools && selectedTools.length > 0) args.push("--tools", selectedTools.join(","));
	else if (inheritedActiveTools.length > 0) args.push("--no-tools");

	let tmpPromptDir: string | null = null;
	let tmpPromptPath: string | null = null;
	const oneShotTaskId = createTaskId(agent.name);
	const transcriptPath = oneShotTranscriptPath(runtimeRoot, agent.name, oneShotTaskId);
	const transcriptWrites: Promise<unknown>[] = [];

	const appendTranscript = (record: Record<string, unknown>) => {
		transcriptWrites.push(
			fs.promises
				.appendFile(transcriptPath, `${JSON.stringify({ ts: new Date().toISOString(), ...record })}\n`, { encoding: "utf-8" })
				.catch(() => undefined),
		);
	};

	const currentResult: SingleResult = {
		agent: agentName,
		agentSource: agent.source,
		task,
		sessionMode: session.explicit ? "resumed" : "fresh",
		// -1 = still running. Real exit code is set after proc.close; streaming
		// partials must not look completed to callers that key on exitCode.
		exitCode: -1,
		attempt,
		messages: [],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		model: selectedModel,
		effort: selectedEffort,
		sessionKey: session.key,
		sessionKeyExplicit: session.explicit,
		sessionPath: session.path,
		ephemeralSession: session.ephemeral,
		taskId: oneShotTaskId,
		transcriptPath,
		step,
	};

	const emitUpdate = () => {
		if (onUpdate) {
			const rawOutput = getFinalOutput(currentResult.messages);
			const displayText = rawOutput ? truncateForDetails(rawOutput, cwd ?? defaultCwd) : "(running...)";
			const partialResult: SingleResult = {
				...currentResult,
				messages: cloneMessagesForDetails(currentResult.messages, rawOutput ? displayText : undefined, cwd ?? defaultCwd),
			};
			onUpdate({
				content: [{ type: "text", text: displayText }],
				details: makeDetails([partialResult]),
			});
		}
	};

	try {
		await fs.promises.mkdir(path.dirname(transcriptPath), { recursive: true, mode: 0o700 });
		await fs.promises.writeFile(transcriptPath, "", { encoding: "utf-8", mode: 0o600 });
		emitSubagentEvent(pi, "subagents:started", {
			mode: "oneshot",
			agent: agent.name,
			taskId: oneShotTaskId,
			task,
			runtimeRoot,
			transcriptPath,
			model: selectedModel,
			effort: selectedEffort,
			sessionMode: currentResult.sessionMode,
			sessionKey: session.explicit ? session.key : undefined,
			sessionPath: session.path,
			ephemeralSession: session.ephemeral,
			attempt,
		});
		appendTranscript({ type: "start", agent: agent.name, taskId: oneShotTaskId, task, cwd: cwd ?? defaultCwd, sessionMode: currentResult.sessionMode, sessionKey: session.explicit ? session.key : undefined, sessionPath: session.path, ephemeralSession: session.ephemeral, attempt });

		if (agent.systemPrompt.trim()) {
			const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt);
			tmpPromptDir = tmp.dir;
			tmpPromptPath = tmp.filePath;
			args.push("--append-system-prompt", tmpPromptPath);
		}

		args.push(`Task: ${task}`);
		let wasAborted = false;

		const exitCode = await new Promise<number>((resolve) => {
			const invocation = getPiInvocation(args);
			// Child identity env mirrors the pane launcher's agent identity
			// for bg one-shot lanes (issue #228). Restricted delegation reads
			// PI_SUBAGENT_CHILD_AGENT to authorize the caller. Strip pane-only
			// ownership/session markers, including PI_SUBAGENT_CHILD_PANE, so
			// bg lanes never mutate an inherited tmux pane or attach to pane
			// session/bridge scope —
			// without an explicit delete a parent process that already has
			// those vars set (for example, this Pi running inside a pane
			// itself) would leak them into the bg child and
			// `runtimeSessionId()` would attach the child to the wrong
			// runtime root.
			const childEnv: NodeJS.ProcessEnv = { ...process.env, PI_SUBAGENT_CHILD_AGENT: agent.name };
			if (agent.color) childEnv.PI_SUBAGENT_CHILD_COLOR = agent.color;
			else delete childEnv.PI_SUBAGENT_CHILD_COLOR;
			delete childEnv[PI_SUBAGENT_CHILD_PANE_ENV];
			delete childEnv.PI_SUBAGENT_PARENT_SESSION_ID;
			for (const key of Object.keys(childEnv)) {
				if (key.startsWith("PI_BRIDGE_")) delete childEnv[key];
			}
			const proc = spawnProcess(invocation.command, invocation.args, {
				cwd: cwd ?? defaultCwd,
				env: childEnv,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
			});
			const keepFullTranscript = transcriptFullStreamEnabled();
			let buffer = "";
			let sawSessionCompact = false;
			let compactThenEmptyAgentEnd = false;
			let postCompactAssistantHasText = false;
			let latestFilteredMessageUpdate: any;

			const flushFilteredMessageUpdate = (reason: "nonzero_exit" | "process_error") => {
				if (keepFullTranscript || !latestFilteredMessageUpdate) return;
				appendTranscript({
					stream: "stdout",
					raw: JSON.stringify(latestFilteredMessageUpdate),
					event: latestFilteredMessageUpdate,
					buffered: true,
					reason,
				});
				latestFilteredMessageUpdate = undefined;
			};

			const processLine = (line: string) => {
				if (!line.trim()) return;
				let event: any;
				try {
					event = JSON.parse(line);
				} catch {
					appendTranscript({ stream: "stdout", raw: line, parseError: true });
					return;
				}
				const normalized = normalizePiStreamEvent(event);
				const eventName = normalized.name;
				if (eventName === "message_update" && !keepFullTranscript) latestFilteredMessageUpdate = normalized.event;
				if (shouldAppendTranscriptEvent(eventName, keepFullTranscript)) {
					const transcriptEvent = eventName === "agent_start"
						? withAgentStartTranscriptMetadata(normalized.event, { agent: agent.name, model: selectedModel, args })
						: normalized.event;
					appendTranscript({ stream: "stdout", raw: JSON.stringify(transcriptEvent), event: transcriptEvent });
				}
				const payload = normalized.payload;

				if (eventName === "session_compact") {
					sawSessionCompact = true;
					compactThenEmptyAgentEnd = false;
					postCompactAssistantHasText = false;
				}

				if (eventName === "agent_end") {
					const malformedDiagnostic = malformedAgentEndContentDiagnostic(payload);
					if (malformedDiagnostic) appendResultDiagnostic(currentResult, malformedDiagnostic);
					compactThenEmptyAgentEnd = sawSessionCompact && !postCompactAssistantHasText && agentEndHasTextlessContent(payload);
				}

				if (eventName === "message_end") latestFilteredMessageUpdate = undefined;
				if (eventName === "message_end" && payload.message) {
					const msg = payload.message as Message;
					currentResult.messages.push(msg);

					if (msg.role === "assistant") {
						if (sawSessionCompact && contentHasTextPart(msg.content)) postCompactAssistantHasText = true;
						currentResult.usage.turns++;
						const usage = msg.usage;
						if (usage) {
							currentResult.usage.input += usage.input || 0;
							currentResult.usage.output += usage.output || 0;
							currentResult.usage.cacheRead += usage.cacheRead || 0;
							currentResult.usage.cacheWrite += usage.cacheWrite || 0;
							currentResult.usage.cost += usage.cost?.total || 0;
							currentResult.usage.contextTokens = usage.totalTokens || 0;
						}
						if (!currentResult.model && msg.model) currentResult.model = msg.model;
						if (msg.stopReason) currentResult.stopReason = msg.stopReason;
						if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
					}
					emitUpdate();
				}

				const hasContextOverflowEnvelope = isContextLengthExceededEnvelope(event) || isContextLengthExceededEnvelope(payload);
				if (eventName === "error" || hasContextOverflowEnvelope) {
					const rawEnvelope = line;
					const errorText = typeof payload.error === "string" ? payload.error : JSON.stringify(payload.error ?? payload ?? event);
					currentResult.errorEnvelope = rawEnvelope;
					currentResult.errorMessage = errorText;
					currentResult.stderr += `${rawEnvelope}\n`;
					emitUpdate();
				}

				if (eventName === "tool_result_end") {
					emitUpdate();
				}
			};

			proc.stdout.on("data", (data) => {
				buffer += data.toString();
				const lines = buffer.split("\n");
				buffer = lines.pop() || "";
				for (const line of lines) processLine(line);
			});

			proc.stderr.on("data", (data) => {
				const text = data.toString();
				currentResult.stderr += text;
				appendTranscript({ stream: "stderr", text });
			});

			proc.on("close", (code, closeSignal) => {
				if (buffer.trim()) processLine(buffer);
				if (compactThenEmptyAgentEnd) currentResult.needsCompletionReason = "compact-then-empty";
				const signalName = typeof closeSignal === "string" && closeSignal ? closeSignal : undefined;
				const exitCode = signalName || wasAborted ? (code && code !== 0 ? code : 1) : (code ?? 0);
				if (signalName && !currentResult.errorMessage) currentResult.errorMessage = `Agent process terminated by signal ${signalName}`;
				if (exitCode !== 0) flushFilteredMessageUpdate("nonzero_exit");
				appendTranscript({ type: "exit", code: exitCode, ...(signalName ? { signal: signalName } : {}), attempt });
				Promise.allSettled(transcriptWrites).finally(() => resolve(exitCode));
			});

			proc.on("error", (error) => {
				currentResult.errorMessage = stringifyError(error);
				flushFilteredMessageUpdate("process_error");
				appendTranscript({ type: "process_error", error: stringifyError(error), attempt });
				Promise.allSettled(transcriptWrites).finally(() => resolve(1));
			});

			if (signal) {
				const killProc = () => {
					wasAborted = true;
					proc.kill("SIGTERM");
					setTimeout(() => {
						if (!proc.killed) proc.kill("SIGKILL");
					}, 5000);
				};
				if (signal.aborted) killProc();
				else signal.addEventListener("abort", killProc, { once: true });
			}
		});

		currentResult.exitCode = exitCode;
		if (wasAborted) {
			currentResult.stopReason = "aborted";
			currentResult.errorMessage = "Agent was aborted";
			const summary = "Agent was aborted before completion.";
			emitSubagentEvent(pi, "subagents:failed", {
				mode: "oneshot",
				agent: agent.name,
				taskId: oneShotTaskId,
				task,
				status: "aborted",
				summary,
				runtimeRoot,
				transcriptPath,
				model: currentResult.model,
				effort: currentResult.effort,
				usage: currentResult.usage,
				error: currentResult.errorMessage || "Agent was aborted",
				sessionMode: currentResult.sessionMode,
				sessionKey: session.explicit ? session.key : undefined,
				sessionPath: session.path,
				ephemeralSession: session.ephemeral,
				attempt,
			});
			throw new Error("Agent was aborted");
		}
		if (
			currentResult.needsCompletionReason === "compact-then-empty" &&
			!resultHasContextLengthExceeded(currentResult)
		) {
			currentResult.status = "needs_completion";
			currentResult.stopReason = "needs_completion";
			const cwdSnapshot = await snapshotCwdGitState(cwd ?? defaultCwd, (diagnostic) => appendResultDiagnostic(currentResult, diagnostic));
			if (cwdSnapshot) currentResult.cwdSnapshot = cwdSnapshot;
			const summary = compactThenEmptySummary(cwdSnapshot);
			currentResult.errorMessage = summary;
			const needsCompletionPayload = {
				mode: "oneshot",
				agent: agent.name,
				taskId: oneShotTaskId,
				task,
				status: "needs_completion",
				reason: "compact-then-empty",
				summary,
				runtimeRoot,
				transcriptPath,
				model: currentResult.model,
				effort: currentResult.effort,
				usage: currentResult.usage,
				sessionMode: currentResult.sessionMode,
				sessionKey: session.explicit ? session.key : undefined,
				sessionPath: session.path,
				ephemeralSession: session.ephemeral,
				attempt,
				diagnostics: currentResult.diagnostics,
				...(cwdSnapshot ? { cwdSnapshot } : {}),
			};
			const emitted = tryEmitSubagentEvent(pi, "subagents:needs_completion", needsCompletionPayload);
			if (!emitted.ok) {
				const diagnostic = `Failed to emit subagents:needs_completion for ${agent.name} (${oneShotTaskId}): ${emitted.error ?? "unknown error"}`;
				appendResultDiagnostic(currentResult, diagnostic);
				appendTranscript({ type: "diagnostic", diagnostic, attempt });
			}
			return currentResult;
		}
		const failed = exitCode !== 0 || currentResult.stopReason === "error" || currentResult.stopReason === "aborted";
		const finalOutput = getFinalOutput(currentResult.messages);
		emitSubagentEvent(pi, failed ? "subagents:failed" : "subagents:completed", {
			mode: "oneshot",
			agent: agent.name,
			taskId: oneShotTaskId,
			task,
			status: failed ? "failed" : "completed",
			...(finalOutput ? { summary: finalOutput, finalOutput } : {}),
			runtimeRoot,
			transcriptPath,
			model: currentResult.model,
			effort: currentResult.effort,
			usage: currentResult.usage,
			error: failed ? currentResult.errorMessage || currentResult.stderr || undefined : undefined,
			sessionMode: currentResult.sessionMode,
			sessionKey: session.explicit ? session.key : undefined,
			sessionPath: session.path,
			ephemeralSession: session.ephemeral,
			attempt,
		});
		return currentResult;
	} finally {
		await Promise.allSettled(transcriptWrites);
		if (tmpPromptPath)
			try {
				fs.unlinkSync(tmpPromptPath);
			} catch {
				/* ignore */
			}
		if (tmpPromptDir)
			try {
				fs.rmdirSync(tmpPromptDir);
			} catch {
				/* ignore */
			}
	}
}
