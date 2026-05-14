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
import { getFinalOutput, stringifyError } from "./format.js";
import { safeFileName } from "./names.js";
import {
	getPiInvocation,
	writePromptToTempFile,
} from "./pane.js";
import {
	oneShotTranscriptPath,
} from "./paths.js";
import { randomHex } from "./random.js";
import {
	resultLimits,
	selectedModelForAgent,
	selectedThinkingLevelForAgent,
	selectedToolsForAgent,
	settingBoolean,
} from "./settings.js";
import {
	guardReusedSessionBudget,
	isContextLengthExceededEnvelope,
	isContextLengthExceededText,
	resolveBgSession,
	resultHasContextLengthExceeded,
	summarizeAttempt,
	type BgSessionSelection,
} from "./sessions.js";
import { createTaskId, emitSubagentEvent } from "./tasks.js";
import {
	DETAIL_STRING_MAX_CHARS,
	type PreparedSingleResult,
	type ResultLimits,
	type SingleResult,
	type SubagentDetails,
} from "./types.js";

export type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

type SpawnProcess = typeof spawn;
let spawnProcess: SpawnProcess = spawn;

export function setSingleAgentSpawnForTests(spawner?: SpawnProcess): void {
	spawnProcess = spawner ?? spawn;
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
	step: number | undefined,
	pi: ExtensionAPI,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
	session: BgSessionSelection,
	attempt: number,
): Promise<SingleResult> {
	const args: string[] = ["--mode", "json", "-p", "--session", session.path];
	if (selectedModel) args.push("--model", selectedModel);
	if (selectedThinking && selectedThinking !== "off") args.push("--thinking", selectedThinking);
	const selectedTools = selectedToolsForAgent(agent, defaultCwd, [], pi.getActiveTools?.() ?? []);
	if (selectedTools && selectedTools.length > 0) args.push("--tools", selectedTools.join(","));

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
		// -1 = still running. Real exit code is set after proc.close; streaming
		// partials must not look completed to callers that key on exitCode.
		exitCode: -1,
		attempt,
		messages: [],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		model: selectedModel,
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
			sessionKey: session.key,
			sessionPath: session.path,
			ephemeralSession: session.ephemeral,
			attempt,
		});
		appendTranscript({ type: "start", agent: agent.name, taskId: oneShotTaskId, task, cwd: cwd ?? defaultCwd, sessionKey: session.key, sessionPath: session.path, ephemeralSession: session.ephemeral, attempt });

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
			const proc = spawnProcess(invocation.command, invocation.args, {
				cwd: cwd ?? defaultCwd,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
			});
			let buffer = "";

			const processLine = (line: string) => {
				if (!line.trim()) return;
				let event: any;
				try {
					event = JSON.parse(line);
					appendTranscript({ stream: "stdout", raw: line, event });
				} catch {
					appendTranscript({ stream: "stdout", raw: line, parseError: true });
					return;
				}

				if (event.type === "message_end" && event.message) {
					const msg = event.message as Message;
					currentResult.messages.push(msg);

					if (msg.role === "assistant") {
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

				const hasContextOverflowEnvelope = isContextLengthExceededEnvelope(event) || isContextLengthExceededText(line);
				if (event.type === "error" || hasContextOverflowEnvelope) {
					const rawEnvelope = line;
					const errorText = typeof event.error === "string" ? event.error : JSON.stringify(event.error ?? event);
					currentResult.errorEnvelope = rawEnvelope;
					currentResult.errorMessage = errorText;
					currentResult.stderr += `${rawEnvelope}\n`;
					emitUpdate();
				}

				if (event.type === "tool_result_end") {
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

			proc.on("close", (code) => {
				if (buffer.trim()) processLine(buffer);
				appendTranscript({ type: "exit", code: code ?? 0, attempt });
				Promise.allSettled(transcriptWrites).finally(() => resolve(code ?? 0));
			});

			proc.on("error", (error) => {
				currentResult.errorMessage = stringifyError(error);
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
			emitSubagentEvent(pi, "subagents:failed", {
				mode: "oneshot",
				agent: agent.name,
				taskId: oneShotTaskId,
				task,
				status: "aborted",
				runtimeRoot,
				transcriptPath,
				model: currentResult.model,
				usage: currentResult.usage,
				sessionKey: session.key,
				sessionPath: session.path,
				ephemeralSession: session.ephemeral,
				attempt,
			});
			throw new Error("Agent was aborted");
		}
		const failed = exitCode !== 0 || currentResult.stopReason === "error" || currentResult.stopReason === "aborted";
		emitSubagentEvent(pi, failed ? "subagents:failed" : "subagents:completed", {
			mode: "oneshot",
			agent: agent.name,
			taskId: oneShotTaskId,
			task,
			status: failed ? "failed" : "completed",
			runtimeRoot,
			transcriptPath,
			model: currentResult.model,
			usage: currentResult.usage,
			error: failed ? currentResult.errorMessage || currentResult.stderr || undefined : undefined,
			sessionKey: session.key,
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
