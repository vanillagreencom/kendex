import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Message } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { atomicWriteFile } from "./file-lock.js";
import type { AgentConfig } from "./agents.js";
import { delay, paneSessionModeToRecordMode } from "./format.js";
import { safeFileName, shellQuote } from "./names.js";
import {
	archivedPaneSessionDir,
	archivedPaneSessions,
	completionPath,
	hasSavedPaneSession,
	inboxDir,
	legacyProjectRuntimeDirs,
	paneSessionPath,
} from "./paths.js";
import { randomHex } from "./random.js";

// vstack#60 workaround: env var names the pi-session-bridge child reads
// on startup. The canonical home is
// pi-extensions/pi-session-bridge/extensions/child-session-id.ts
// (PARENT_SESSION_ENV + CHILD_ROLE_ENV). Mirrored here as constants so
// the launcher script doesn't carry magic strings; the bridge package
// is a sibling so we can't import directly without coupling the two
// extension packages. A parity test in
// tests/subagent-bridge-id.test.ts asserts these values match the
// bridge's exported constants.
const PI_BRIDGE_PARENT_SESSION_ENV = "PI_BRIDGE_PARENT_SESSION_ID";
const PI_BRIDGE_CHILD_ROLE_ENV = "PI_BRIDGE_CHILD_ROLE";
const PI_BRIDGE_SUBAGENT_ROLE = "subagent";
export const PI_SUBAGENT_CHILD_PANE_ENV = "PI_SUBAGENT_CHILD_PANE";
import {
	legacyPackageSessionRuntimeDir,
	piUserDir,
	projectSettingsPath,
	selectedEffortForAgent,
	selectedModelForAgent,
	selectedThinkingLevelForAgent,
	selectedToolsForAgent,
	settingBoolean,
} from "./settings.js";
import {
	appendUniqueDiagnostic,
	createTaskId,
	emitSubagentEvent,
	isTerminalTaskStatus,
	normalizedTaskForDedup,
	paneSessionBelongsToRuntime,
	readPaneRegistry,
	readTaskRegistry,
	samePath,
	updatePaneRegistry,
	updateTaskRegistry,
	upsertTaskRecord,
} from "./tasks.js";
import {
	type BridgeMetadata,
	FIRST_AGENT_COLUMN_ROWS,
	NEXT_AGENT_COLUMN_ROWS,
	PANE_LAUNCHER_VERSION,
	type PaneRegistry,
	type PaneRegistryEntry,
	type QueuedPaneTask,
	SESSION_BRIDGE_PACKAGE_ID,
	type SingleResult,
} from "./types.js";

type ExecCaptureFn = (command: string, args: string[], options?: { cwd?: string }) => Promise<{ code: number; stdout: string; stderr: string; error?: unknown }>;

async function defaultExecCapture(command: string, args: string[], options?: { cwd?: string }): Promise<{ code: number; stdout: string; stderr: string; error?: unknown }> {
	return new Promise((resolve) => {
		const proc = spawn(command, args, { cwd: options?.cwd, shell: false, stdio: ["ignore", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		proc.stdout.on("data", (data) => (stdout += data.toString()));
		proc.stderr.on("data", (data) => (stderr += data.toString()));
		proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
		proc.on("error", (error) => resolve({ code: 1, stdout, stderr: String(error), error }));
	});
}

let execCaptureImpl: ExecCaptureFn = defaultExecCapture;
let paneTitleSpawn = spawn;

export function setPaneExecCaptureForTests(capture?: ExecCaptureFn): void {
	execCaptureImpl = capture ?? defaultExecCapture;
}

export function setTmuxPaneTitleSpawnForTests(spawner?: typeof spawn): void {
	paneTitleSpawn = spawner ?? spawn;
}

export async function execCapture(command: string, args: string[], options?: { cwd?: string }): Promise<{ code: number; stdout: string; stderr: string; error?: unknown }> {
	return execCaptureImpl(command, args, options);
}

export async function tmux(args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
	return execCapture("tmux", args);
}

async function ensureTmux(): Promise<void> {
	if (!process.env.TMUX) throw new Error("Persistent pane agents require tmux ($TMUX is unset).");
	const result = await tmux(["display-message", "-p", "#S"]);
	if (result.code !== 0) throw new Error(`tmux is unavailable: ${result.stderr || result.stdout}`.trim());
}

export async function paneExists(paneId: string): Promise<boolean> {
	const result = await tmux(["display-message", "-p", "-t", paneId, "#{pane_id}"]);
	return result.code === 0 && result.stdout.trim() === paneId;
}

const DELETED_CWD_SUFFIX = " (deleted)";

export interface PaneCwdStaleDetails {
	agent: string;
	paneId: string;
	pid?: string;
	expectedCwd: string;
	actualCwd?: string;
	actualCwdRaw?: string;
	reason: "deleted" | "missing" | "mismatch" | "uninspectable" | "unresolved-pid";
}

export class PaneCwdStaleError extends Error {
	readonly code = "pane-cwd-stale";
	readonly details: PaneCwdStaleDetails;

	constructor(details: PaneCwdStaleDetails) {
		super(formatPaneCwdStaleMessage(details));
		this.name = "PaneCwdStaleError";
		this.details = details;
	}
}

function stripDeletedCwdSuffix(cwd: string): string {
	return cwd.endsWith(DELETED_CWD_SUFFIX) ? cwd.slice(0, -DELETED_CWD_SUFFIX.length) : cwd;
}

function formatPaneCwdStaleMessage(details: PaneCwdStaleDetails): string {
	const actual = details.actualCwdRaw ?? details.actualCwd ?? "(unavailable)";
	const reason = details.reason === "deleted"
		? "pane process cwd was deleted"
		: details.reason === "missing"
			? "pane process cwd no longer exists"
			: details.reason === "mismatch"
				? "pane process cwd differs from requested cwd"
				: details.reason === "unresolved-pid"
					? "pane process pid could not be resolved"
					: "pane process cwd could not be inspected";
	return [
		`pane-cwd-stale: refusing to queue task for ${details.agent}; ${reason}.`,
		`Pane: ${details.paneId}${details.pid ? ` pid=${details.pid}` : ""}`,
		`Actual cwd: ${actual}`,
		`Requested cwd: ${details.expectedCwd}`,
		`Stop the pane with stop_subagent agent=${details.agent} and retry with forceSpawn for a fresh process.`,
	].join("\n");
}

function paneCwdStaleEnvelope(details: PaneCwdStaleDetails, message: string): string {
	return JSON.stringify({ error: { code: "pane-cwd-stale", message, details } });
}

async function paneProcessPid(entry: PaneRegistryEntry): Promise<string | undefined> {
	const result = await tmux(["display-message", "-p", "-t", entry.paneId, "#{pane_pid}"]);
	const tmuxPid = result.code === 0 ? result.stdout.trim() : "";
	if (/^\d+$/.test(tmuxPid)) return tmuxPid;
	const bridgePid = entry.bridgePid?.trim();
	return bridgePid && /^\d+$/.test(bridgePid) ? bridgePid : undefined;
}

export function inspectPaneProcessCwd(entry: Pick<PaneRegistryEntry, "agent" | "paneId">, pid: string | number, expectedCwd: string): PaneCwdStaleDetails | undefined {
	const normalizedPid = String(pid).trim();
	const normalizedExpected = path.resolve(expectedCwd);
	if (!normalizedPid) {
		return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, reason: "unresolved-pid" };
	}
	if (process.platform !== "linux") return undefined;
	let actualRaw: string;
	try {
		actualRaw = fs.readlinkSync(path.join("/proc", normalizedPid, "cwd"));
	} catch {
		return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, pid: normalizedPid, reason: "uninspectable" };
	}
	const deleted = actualRaw.endsWith(DELETED_CWD_SUFFIX);
	const actualCwd = stripDeletedCwdSuffix(actualRaw);
	if (deleted) {
		return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, pid: normalizedPid, actualCwd, actualCwdRaw: actualRaw, reason: "deleted" };
	}
	try {
		const stat = fs.statSync(actualCwd);
		if (!stat.isDirectory()) {
			return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, pid: normalizedPid, actualCwd, actualCwdRaw: actualRaw, reason: "missing" };
		}
	} catch {
		return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, pid: normalizedPid, actualCwd, actualCwdRaw: actualRaw, reason: "missing" };
	}
	if (!samePath(actualCwd, normalizedExpected)) {
		return { agent: entry.agent, paneId: entry.paneId, expectedCwd: normalizedExpected, pid: normalizedPid, actualCwd, actualCwdRaw: actualRaw, reason: "mismatch" };
	}
	return undefined;
}

async function assertPaneCwdReusable(entry: PaneRegistryEntry, expectedCwd: string): Promise<void> {
	if (process.platform !== "linux") return;
	const pid = await paneProcessPid(entry);
	if (!pid) throw new PaneCwdStaleError({ agent: entry.agent, paneId: entry.paneId, expectedCwd: path.resolve(expectedCwd), reason: "unresolved-pid" });
	const stale = inspectPaneProcessCwd(entry, pid, expectedCwd);
	if (stale) throw new PaneCwdStaleError(stale);
}

function emitPaneCwdStale(pi: ExtensionAPI, runtimeRoot: string, task: string, entry: PaneRegistryEntry, details: PaneCwdStaleDetails, message: string): void {
	emitSubagentEvent(pi, "subagents:failed", {
		mode: "pane",
		agent: entry.agent,
		paneId: entry.paneId,
		task,
		status: "failed",
		reason: "pane-cwd-stale",
		summary: message,
		error: message,
		runtimeRoot,
		transcriptPath: entry.sessionFile,
		cwdPid: details.pid,
		expectedCwd: details.expectedCwd,
		actualCwd: details.actualCwd,
		actualCwdRaw: details.actualCwdRaw,
		cwdReason: details.reason,
	});
}

async function parentPid(pid: number): Promise<number | undefined> {
	const result = await execCapture("ps", ["-o", "ppid=", "-p", String(pid)]);
	const parsed = Number.parseInt(result.stdout.trim(), 10);
	return result.code === 0 && Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

async function processHasAncestor(pid: number, ancestorPid: number): Promise<boolean> {
	let current: number | undefined = pid;
	const seen = new Set<number>();
	for (let depth = 0; current && depth < 64 && !seen.has(current); depth += 1) {
		if (current === ancestorPid) return true;
		seen.add(current);
		current = await parentPid(current);
	}
	return false;
}

async function paneContainingProcess(pid: number): Promise<string | undefined> {
	const result = await tmux(["list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}"]);
	if (result.code !== 0) return undefined;
	for (const line of result.stdout.split(/\r?\n/)) {
		const [paneId, panePidText] = line.split("\t");
		const panePid = Number.parseInt(panePidText ?? "", 10);
		if (!paneId || !Number.isInteger(panePid) || panePid <= 0) continue;
		if (await processHasAncestor(pid, panePid)) return paneId;
	}
	return undefined;
}

async function getPrimaryPaneId(): Promise<string> {
	// TMUX_PANE can be stale; prefer the pane whose subtree contains us.
	const currentPane = await paneContainingProcess(process.pid);
	if (currentPane && (await paneExists(currentPane))) return currentPane;
	if (process.env.TMUX_PANE && (await paneExists(process.env.TMUX_PANE))) return process.env.TMUX_PANE;
	const result = await tmux(["display-message", "-p", "#{pane_id}"]);
	if (result.code === 0 && result.stdout.trim()) return result.stdout.trim();
	throw new Error(`Unable to determine primary tmux pane: ${result.stderr || result.stdout}`.trim());
}

function columnCapacity(group: number): number {
	return group <= 1 ? FIRST_AGENT_COLUMN_ROWS : NEXT_AGENT_COLUMN_ROWS;
}

function sortPaneEntries(entries: PaneRegistryEntry[]): PaneRegistryEntry[] {
	return [...entries].sort((a, b) => a.startedAt.localeCompare(b.startedAt) || a.agent.localeCompare(b.agent));
}

function groupedPaneEntries(registry: PaneRegistry): Map<number, PaneRegistryEntry[]> {
	const groups = new Map<number, PaneRegistryEntry[]>();
	for (const entry of sortPaneEntries(Object.values(registry))) {
		if (!entry.layoutGroup) continue;
		const group = groups.get(entry.layoutGroup) ?? [];
		group.push(entry);
		groups.set(entry.layoutGroup, group);
	}
	return groups;
}

function nextLayoutGroup(registry: PaneRegistry): number {
	const groups = groupedPaneEntries(registry);
	for (let group = 1; group <= 16; group += 1) {
		if ((groups.get(group)?.length ?? 0) < columnCapacity(group)) return group;
	}
	return Math.max(1, groups.size + 1);
}

async function cleanupPaneRegistry(registry: PaneRegistry): Promise<boolean> {
	let changed = false;
	for (const [agentName, entry] of Object.entries(registry)) {
		if (!(await paneExists(entry.paneId))) {
			delete registry[agentName];
			changed = true;
			continue;
		}
		if (entry.launcherVersion !== PANE_LAUNCHER_VERSION) {
			await tmux(["kill-pane", "-t", entry.paneId]);
			delete registry[agentName];
			changed = true;
		}
	}
	return changed;
}

async function rebalanceColumn(entries: PaneRegistryEntry[]): Promise<void> {
	if (entries.length <= 1) return;
	const sorted = sortPaneEntries(entries);
	const heightResult = await tmux(["display-message", "-p", "-t", sorted[0].paneId, "#{window_height}"]);
	const windowHeight = Number.parseInt(heightResult.stdout.trim(), 10);
	if (heightResult.code !== 0 || !Number.isFinite(windowHeight) || windowHeight <= 0) return;

	const availablePaneRows = Math.max(sorted.length, windowHeight - (sorted.length - 1));
	const targetHeight = Math.max(3, Math.floor(availablePaneRows / sorted.length));
	for (const entry of sorted.slice(0, -1)) {
		await tmux(["resize-pane", "-t", entry.paneId, "-y", String(targetHeight)]);
	}
}

async function rebalanceColumns(registry: PaneRegistry, primaryPaneId: string): Promise<void> {
	const groups = groupedPaneEntries(registry);
	const columns = [{ paneId: primaryPaneId, group: 0 }];
	for (const [group, entries] of [...groups.entries()].sort(([a], [b]) => a - b)) {
		const representative = sortPaneEntries(entries)[0];
		if (representative) columns.push({ paneId: representative.paneId, group });
	}
	if (columns.length <= 1) return;

	const measured: Array<{ paneId: string; left: number; windowWidth: number }> = [];
	for (const column of columns) {
		if (!(await paneExists(column.paneId))) continue;
		const result = await tmux(["display-message", "-p", "-t", column.paneId, "#{pane_left}\t#{window_width}"]);
		const [leftText, windowWidthText] = result.stdout.trim().split("\t");
		const left = Number.parseInt(leftText ?? "", 10);
		const windowWidth = Number.parseInt(windowWidthText ?? "", 10);
		if (result.code === 0 && Number.isFinite(left) && Number.isFinite(windowWidth)) measured.push({ paneId: column.paneId, left, windowWidth });
	}
	if (measured.length <= 1) return;

	measured.sort((a, b) => a.left - b.left);
	const windowWidth = measured[0].windowWidth;
	const availablePaneColumns = Math.max(measured.length, windowWidth - (measured.length - 1));
	const baseWidth = Math.max(10, Math.floor(availablePaneColumns / measured.length));
	const remainder = Math.max(0, availablePaneColumns - baseWidth * measured.length);
	for (const [index, column] of measured.entries()) {
		const targetWidth = baseWidth + (index >= measured.length - remainder ? 1 : 0);
		await tmux(["resize-pane", "-t", column.paneId, "-x", String(targetWidth)]);
	}
}

export function setCurrentTmuxPaneTitle(title: string): void {
	const paneId = process.env.TMUX_PANE;
	if (!paneId) return;
	const proc = paneTitleSpawn("tmux", ["select-pane", "-t", paneId, "-T", title], { stdio: "ignore" });
	proc.on("error", () => undefined);
	proc.unref?.();
}

function resolveSessionBridgeExtension(cwd?: string): string | undefined {
	const projectPackagesDir = path.join(path.dirname(projectSettingsPath(cwd ?? process.cwd())), "packages");
	const candidates = [
		process.env.PI_SESSION_BRIDGE_EXTENSION,
		path.join(piUserDir(), "packages", SESSION_BRIDGE_PACKAGE_ID, "extensions", "session-bridge.ts"),
		path.join(projectPackagesDir, SESSION_BRIDGE_PACKAGE_ID, "extensions", "session-bridge.ts"),
		path.resolve(cwd ?? process.cwd(), "pi-extensions", "pi-session-bridge", "extensions", "session-bridge.ts"),
	].filter((candidate): candidate is string => Boolean(candidate));
	return candidates.find((candidate) => fs.existsSync(candidate));
}

async function resolvePiBridgeBin(): Promise<string | undefined> {
	const projectBinDir = path.join(path.dirname(projectSettingsPath(process.cwd())), "bin");
	const projectPackagesDir = path.join(path.dirname(projectSettingsPath(process.cwd())), "packages");
	const candidates = [
		process.env.PI_BRIDGE_BIN,
		path.join(piUserDir(), "bin", "pi-bridge"),
		path.join(piUserDir(), "packages", SESSION_BRIDGE_PACKAGE_ID, "bin", "pi-bridge.js"),
		path.join(projectBinDir, "pi-bridge"),
		path.join(projectPackagesDir, SESSION_BRIDGE_PACKAGE_ID, "bin", "pi-bridge.js"),
	].filter((candidate): candidate is string => Boolean(candidate));
	for (const candidate of candidates) {
		if (fs.existsSync(candidate)) return candidate;
	}
	const result = await execCapture("bash", ["-lc", "command -v pi-bridge || true"]);
	const found = result.stdout.trim().split(/\r?\n/)[0];
	return found || undefined;
}

type DiagnosticLogger = (message: string) => void;

function formatResolverFailure(error: unknown): string {
	if (!error || typeof error !== "object") return String(error);
	const candidate = error as { code?: unknown; errno?: unknown; syscall?: unknown; path?: unknown; cwd?: unknown; message?: unknown };
	const fields = ["code", "errno", "syscall", "path", "cwd"] as const;
	const parts = fields.flatMap((field) => {
		const value = candidate[field];
		return value === undefined || value === null || value === "" ? [] : [`${field}=${String(value)}`];
	});
	if (typeof candidate.message === "string" && candidate.message.trim()) parts.push(`message=${candidate.message.trim()}`);
	return parts.length ? parts.join(" ") : String(error);
}

export function createCachedPiBridgeResolver(
	resolve: () => Promise<string | undefined> = resolvePiBridgeBin,
	logDiagnostic?: DiagnosticLogger,
): () => Promise<string | undefined> {
	// vstack#122: interval probes must not re-run path discovery on every tick.
	// Resolve once for the extension lifetime; if the initial lookup fails,
	// emit one structured diagnostic before caching the missing result so later
	// probes can short-circuit without spamming terminal warnings.
	const report = (reason: string) => {
		try { logDiagnostic?.(`pi-bridge resolver failed: ${reason}`); } catch { /* diagnostics are best-effort */ }
	};
	let cached: Promise<string | undefined>;
	try {
		cached = Promise.resolve(resolve()).then(
			(bin) => {
				if (!bin) report("returned undefined");
				return bin;
			},
			(error) => {
				report(formatResolverFailure(error));
				return undefined;
			},
		);
	} catch (error) {
		report(formatResolverFailure(error));
		cached = Promise.resolve(undefined);
	}
	return () => cached;
}

export { resolvePiBridgeBin };

async function discoverBridgeMetadataForPane(entry: PaneRegistryEntry, timeoutMs = 0): Promise<BridgeMetadata | undefined> {
	const bin = await resolvePiBridgeBin();
	if (!bin) return undefined;
	const deadline = Date.now() + Math.max(0, timeoutMs);
	do {
		const result = await execCapture(bin, ["list", "--json"]);
		if (result.code === 0 && result.stdout.trim()) {
			try {
				const instances = (JSON.parse(result.stdout) as Array<Record<string, unknown>>)
					.filter((info) => info && info.stale !== true)
					.sort((a, b) => String(a.startedAt ?? "").localeCompare(String(b.startedAt ?? "")));
				const match = instances.filter((info) => {
					const sessionFile = typeof info.sessionFile === "string" ? info.sessionFile : "";
					return samePath(sessionFile, entry.sessionFile);
				}).at(-1);
				if (match) {
					const pid = match.pid == null ? undefined : String(match.pid);
					const socket = typeof match.socketPath === "string" ? match.socketPath : undefined;
					const sessionFile = typeof match.sessionFile === "string" ? match.sessionFile : undefined;
					if (pid || socket) return { pid, sessionFile, socket };
				}
			} catch {
				// Keep polling until timeout; bridge list output may be transiently incomplete.
			}
		}
		if (Date.now() >= deadline) break;
		await delay(500);
	} while (true);
	return undefined;
}

export async function ensurePaneBridgeMetadata(runtimeRoot: string, entry: PaneRegistryEntry): Promise<BridgeMetadata | undefined> {
	if (!paneSessionBelongsToRuntime(runtimeRoot, entry)) return undefined;
	const metadata = await discoverBridgeMetadataForPane(entry, 2000);
	if ((!metadata?.pid && !metadata?.socket) || !samePath(metadata.sessionFile, entry.sessionFile)) return undefined;
	await updatePaneRegistry(runtimeRoot, (registry) => {
		const current = registry[entry.agent];
		if (current && samePath(current.sessionFile, entry.sessionFile)) {
			current.bridgePid = metadata.pid;
			current.bridgeSocket = metadata.socket;
		}
	});
	entry.bridgePid = metadata.pid;
	entry.bridgeSocket = metadata.socket;
	return metadata;
}

export function getPiInvocation(args: string[]): { command: string; args: string[] } {
	const currentScript = process.argv[1];
	const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
	if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
		return { command: process.execPath, args: [currentScript, ...args] };
	}

	const execName = path.basename(process.execPath).toLowerCase();
	const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
	if (!isGenericRuntime) {
		return { command: process.execPath, args };
	}

	return { command: "pi", args };
}

export async function writePromptToTempFile(agentName: string, prompt: string): Promise<{ dir: string; filePath: string }> {
	const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "pi-subagent-"));
	const safeName = agentName.replace(/[^\w.-]+/g, "_");
	const filePath = path.join(tmpDir, `prompt-${safeName}.md`);
	await atomicWriteFile(filePath, prompt);
	return { dir: tmpDir, filePath };
}

export async function mapWithConcurrencyLimit<TIn, TOut>(
	items: TIn[],
	concurrency: number,
	fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
	if (items.length === 0) return [];
	const limit = Math.max(1, Math.min(concurrency, items.length));
	const results: TOut[] = new Array(items.length);
	let nextIndex = 0;
	const workers = new Array(limit).fill(null).map(async () => {
		while (true) {
			const current = nextIndex++;
			if (current >= items.length) return;
			results[current] = await fn(items[current], current);
		}
	});
	await Promise.all(workers);
	return results;
}

async function writeLauncher(
	runtimeRoot: string,
	parentSessionId: string,
	cwd: string,
	agent: AgentConfig,
	model: string | undefined,
	thinkingLevel: string | undefined,
	activeTools?: string[],
): Promise<{ sessionFile: string; promptFile: string; launcherFile: string }> {
	const dir = runtimeRoot;
	const safeName = safeFileName(agent.name);
	const sessionsDir = path.join(dir, "sessions");
	const promptsDir = path.join(dir, "prompts");
	const launchersDir = path.join(dir, "launchers");
	await fs.promises.mkdir(sessionsDir, { recursive: true, mode: 0o700 });
	await fs.promises.mkdir(promptsDir, { recursive: true, mode: 0o700 });
	await fs.promises.mkdir(launchersDir, { recursive: true, mode: 0o700 });

	const sessionFile = paneSessionPath(dir, agent.name);
	const promptFile = path.join(promptsDir, `${safeName}.md`);
	const launcherFile = path.join(launchersDir, `${safeName}.sh`);

	await atomicWriteFile(promptFile, agent.systemPrompt);

	const args = ["--name", agent.name, "--session", sessionFile, "--append-system-prompt", promptFile];
	const bridgeExtension = settingBoolean("forceSessionBridgeForPanes", true, cwd) ? resolveSessionBridgeExtension(cwd) : undefined;
	if (bridgeExtension) args.push("-e", bridgeExtension);
	if (model) args.push("--model", model);
	if (thinkingLevel && thinkingLevel !== "off") args.push("--thinking", thinkingLevel);
	const selectedTools = selectedToolsForAgent(agent, cwd, ["complete_subagent"], activeTools);
	if (selectedTools && selectedTools.length > 0) args.push("--tools", selectedTools.join(","));

	const invocation = getPiInvocation(args);
	const command = [invocation.command, ...invocation.args].map(shellQuote).join(" ");
	const script = `#!/usr/bin/env bash
set -euo pipefail
cd ${shellQuote(cwd)}
export PI_SUBAGENT_CHILD_AGENT=${shellQuote(agent.name)}
${agent.color ? `export PI_SUBAGENT_CHILD_COLOR=${shellQuote(agent.color)}` : "unset PI_SUBAGENT_CHILD_COLOR"}
export ${PI_SUBAGENT_CHILD_PANE_ENV}=1
export PI_SUBAGENT_PARENT_SESSION_ID=${shellQuote(parentSessionId)}
# vstack#60 workaround: pi-session-bridge reads these on startup and
# synthesizes a unique <parent>:c<pid> session id so 'pi-bridge state
# --session <id>' no longer matches the parent's bridge too.
export ${PI_BRIDGE_PARENT_SESSION_ENV}=${shellQuote(parentSessionId)}
export ${PI_BRIDGE_CHILD_ROLE_ENV}=${shellQuote(PI_BRIDGE_SUBAGENT_ROLE)}
# Inherit cached 1Password service-account token if available so the child
# pi can read op:// refs without triggering the desktop CLI integration
# prompt. No-op for users who don't use 1Password (file won't exist).
if [ -z "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "/run/user/\$(id -u)/op-service-account-token" ]; then
    __op_tok=\$(cat "/run/user/\$(id -u)/op-service-account-token" 2>/dev/null || true)
    [ -n "\$__op_tok" ] && export OP_SERVICE_ACCOUNT_TOKEN="\$__op_tok"
    unset __op_tok
fi
exec ${command}
`;
	await atomicWriteFile(launcherFile, script, 0o700);

	return { sessionFile, promptFile, launcherFile };
}

export async function ensurePersistentPane(
	runtimeRoot: string,
	parentSessionId: string,
	cwd: string,
	agent: AgentConfig,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	activeTools?: string[],
): Promise<PaneRegistryEntry> {
	await ensureTmux();

	let entry: PaneRegistryEntry | undefined;
	let reusedExisting = false;
	let layoutGroup: number | undefined;
	let primaryPaneId: string | undefined;

	await updatePaneRegistry(runtimeRoot, async (registry) => {
		await cleanupPaneRegistry(registry);

		const existing = registry[agent.name];
		if (existing && (await paneExists(existing.paneId))) {
			await assertPaneCwdReusable(existing, cwd);
			entry = existing;
			reusedExisting = true;
			return;
		}

		const selectedModel = selectedModelForAgent(agent, parentModel, cwd);
		const selectedThinking = selectedThinkingLevelForAgent(parentThinkingLevel, cwd);
		const selectedEffort = selectedEffortForAgent(agent, selectedModel, selectedThinking);
		const paths = await writeLauncher(runtimeRoot, parentSessionId, cwd, agent, selectedModel, selectedThinking, activeTools);
		const windowName = `agent:${agent.name}`;
		primaryPaneId = await getPrimaryPaneId();
		layoutGroup = nextLayoutGroup(registry);
		const groupEntries = groupedPaneEntries(registry).get(layoutGroup) ?? [];
		const splitHorizontally = groupEntries.length === 0;
		const splitTarget = splitHorizontally ? primaryPaneId : groupEntries[0].paneId;
		const splitPercent = splitHorizontally ? "50" : String(Math.max(10, Math.floor(100 / (groupEntries.length + 1))));
		const result = await tmux([
			"split-window",
			splitHorizontally ? "-h" : "-v",
			"-d",
			"-P",
			"-F",
			"#{pane_id}",
			"-p",
			splitPercent,
			"-t",
			splitTarget,
			"-c",
			cwd,
			"bash",
			paths.launcherFile,
		]);
		if (result.code !== 0) throw new Error(`Failed to launch tmux pane for ${agent.name}: ${result.stderr || result.stdout}`.trim());
		const paneId = result.stdout.trim();
		await tmux(["select-pane", "-t", paneId, "-T", windowName]);
		await tmux(["set-window-option", "-t", paneId, "pane-border-status", "top"]);
		await tmux([
			"set-window-option",
			"-t",
			paneId,
			"pane-border-format",
			"#{?pane_active,#[bold],} #T #[default]",
		]);

		const created: PaneRegistryEntry = {
			agent: agent.name,
			paneId,
			windowName,
			cwd,
			sessionFile: paths.sessionFile,
			promptFile: paths.promptFile,
			launcherFile: paths.launcherFile,
			model: selectedModel,
			effort: selectedEffort,
			thinkingLevel: selectedThinking,
			startedAt: new Date().toISOString(),
			launcherVersion: PANE_LAUNCHER_VERSION,
			layoutGroup,
			primaryPaneId,
		};
		registry[agent.name] = created;
		entry = created;
	});

	if (!entry) throw new Error(`ensurePersistentPane failed for ${agent.name}`);
	if (reusedExisting) return entry;

	const bridge = await discoverBridgeMetadataForPane(entry, 5000);
	if (bridge?.pid || bridge?.socket) {
		await updatePaneRegistry(runtimeRoot, (registry) => {
			const current = registry[agent.name];
			if (current && current.paneId === entry!.paneId) {
				if (bridge.pid) current.bridgePid = bridge.pid;
				if (bridge.socket) current.bridgeSocket = bridge.socket;
				entry = current;
			}
		});
	}

	if (layoutGroup !== undefined && primaryPaneId) {
		const snapshot = await readPaneRegistry(runtimeRoot);
		await rebalanceColumn([...(groupedPaneEntries(snapshot).get(layoutGroup) ?? [])]);
		await rebalanceColumns(snapshot, primaryPaneId);
	}
	return entry;
}

function buildDelegation(agent: AgentConfig, task: string, outboxFile: string, taskId: string): string {
	const compactTask = task.trim();
	const schema = JSON.stringify({
		agent: agent.name,
		taskId,
		status: "completed|blocked|failed",
		summary: "1-3 sentence result",
		filesChanged: ["path/or empty"],
		validation: ["command/result or empty"],
		notes: "optional",
	});
	return [
		`Task for ${agent.name}`,
		`Task ID: ${taskId}`,
		"",
		compactTask,
		"",
		"When done, first print one brief final message describing what you produced. Then call complete_subagent with status, summary, filesChanged, validation, and optional notes, and go idle.",
		`If complete_subagent is unavailable, write exactly one JSON object to ${outboxFile} using this schema: ${schema}`,
		"Do not complete before the work is actually done.",
	].join("\n");
}

export async function queuePersistentPaneTask(
	runtimeRoot: string,
	parentSessionId: string,
	defaultCwd: string,
	agent: AgentConfig,
	task: string,
	cwd: string | undefined,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	pi: ExtensionAPI,
	activeTools?: string[],
): Promise<QueuedPaneTask> {
	const effectiveCwd = cwd ?? defaultCwd;
	const existingRegistry = await readPaneRegistry(runtimeRoot);
	const existing = existingRegistry[agent.name];
	const liveExisting = existing && (await paneExists(existing.paneId)) ? existing : undefined;
	const activeDuplicate = Object.values(await readTaskRegistry(runtimeRoot))
		.filter((record) => record.agent === agent.name && (record.status === "queued" || record.status === "running"))
		.find((record) => normalizedTaskForDedup(record.task) === normalizedTaskForDedup(task));
	const ensureReusablePane = async () => {
		try {
			return await ensurePersistentPane(runtimeRoot, parentSessionId, effectiveCwd, agent, parentModel, parentThinkingLevel, activeTools);
		} catch (error) {
			if (error instanceof PaneCwdStaleError && liveExisting) emitPaneCwdStale(pi, runtimeRoot, task, liveExisting, error.details, error.message);
			throw error;
		}
	};
	if (activeDuplicate && liveExisting) {
		const pane = await ensureReusablePane();
		return {
			pane,
			taskId: activeDuplicate.taskId,
			outboxFile: activeDuplicate.outboxFile ?? completionPath(runtimeRoot, agent.name, activeDuplicate.taskId),
			taskFile: activeDuplicate.inboxFile ?? activeDuplicate.processingFile ?? path.join(inboxDir(runtimeRoot, agent.name), `${safeFileName(activeDuplicate.taskId)}.md`),
			sessionMode: "live",
			duplicate: true,
		};
	}
	const hadLivePane = Boolean(liveExisting);
	const hadSavedSession = hasSavedPaneSession(runtimeRoot, agent.name);
	const pane = await ensureReusablePane();
	const effort = pane.effort ?? selectedEffortForAgent(agent, pane.model, pane.thinkingLevel);
	const sessionMode: "live" | "resumed" | "new" = hadLivePane ? "live" : hadSavedSession ? "resumed" : "new";
	if (!hadLivePane) {
		emitSubagentEvent(pi, "subagents:created", {
			mode: "pane",
			agent: agent.name,
			paneId: pane.paneId,
			runtimeRoot,
			transcriptPath: pane.sessionFile,
			model: pane.model,
			effort,
		});
	}

	const taskId = createTaskId(agent.name);
	const outboxFile = completionPath(runtimeRoot, agent.name, taskId);
	await fs.promises.mkdir(path.dirname(outboxFile), { recursive: true, mode: 0o700 });
	const delegation = buildDelegation(agent, task, outboxFile, taskId);
	const taskFile = path.join(inboxDir(runtimeRoot, agent.name), `${safeFileName(taskId)}.md`);
	await fs.promises.mkdir(path.dirname(taskFile), { recursive: true, mode: 0o700 });
	await fs.promises.writeFile(taskFile, delegation, { encoding: "utf-8", mode: 0o600 });
	const now = new Date().toISOString();
	await updatePaneRegistry(runtimeRoot, (registry) => {
		if (registry[agent.name]) {
			registry[agent.name].lastTaskAt = now;
			registry[agent.name].lastTaskId = taskId;
		}
	});
	await upsertTaskRecord(runtimeRoot, {
		taskId,
		agent: agent.name,
		task,
		status: "queued",
		sessionMode: paneSessionModeToRecordMode(sessionMode),
		kind: "pane",
		paneId: pane.paneId,
		model: pane.model,
		effort,
		inboxFile: taskFile,
		outboxFile,
		transcriptPath: pane.sessionFile,
		createdAt: now,
		updatedAt: now,
	});
	emitSubagentEvent(pi, "subagents:queued", {
		mode: "pane",
		agent: agent.name,
		taskId,
		task,
		status: "queued",
		paneId: pane.paneId,
		runtimeRoot,
		transcriptPath: pane.sessionFile,
		completionPath: outboxFile,
		sessionMode: paneSessionModeToRecordMode(sessionMode),
		model: pane.model,
		effort,
	});
	return { pane, taskId, outboxFile, taskFile, sessionMode };
}

export async function stopPersistentPane(runtimeRoot: string, agentName: string): Promise<PaneRegistryEntry> {
	let stopped: PaneRegistryEntry | undefined;
	await updatePaneRegistry(runtimeRoot, async (registry) => {
		const entry = registry[agentName];
		if (!entry) throw new Error(`No pane registry entry for agent: ${agentName || "(missing)"}`);
		if (await paneExists(entry.paneId)) await tmux(["kill-pane", "-t", entry.paneId]);
		stopped = entry;
		delete registry[entry.agent];
	});
	if (!stopped) throw new Error(`No pane registry entry for agent: ${agentName || "(missing)"}`);
	const now = new Date().toISOString();
	await updateTaskRegistry(runtimeRoot, (records) => {
		for (const record of Object.values(records)) {
			if (record.agent !== stopped!.agent || isTerminalTaskStatus(record.status)) continue;
			record.status = "blocked";
			record.completedAt = record.completedAt ?? now;
			record.updatedAt = now;
			record.summary = record.summary ?? `Pane for ${stopped!.agent} was stopped before the task completed.`;
			record.diagnostics = appendUniqueDiagnostic(record.diagnostics, `Pane stopped at ${now}.`);
		}
	});
	return stopped;
}

export async function resetPersistentPaneSession(runtimeRoot: string, agentName: string): Promise<string | undefined> {
	const sessionFile = paneSessionPath(runtimeRoot, agentName);
	try {
		await fs.promises.access(sessionFile);
	} catch {
		return undefined;
	}
	const archiveDir = path.join(runtimeRoot, "sessions", "archived");
	await fs.promises.mkdir(archiveDir, { recursive: true, mode: 0o700 });
	const archived = path.join(archiveDir, `${safeFileName(agentName)}-${Date.now()}.jsonl`);
	await fs.promises.rename(sessionFile, archived);
	return archived;
}

export async function restoreArchivedPaneSession(runtimeRoot: string, agentName: string, selector = "latest"): Promise<string> {
	const archives = archivedPaneSessions(runtimeRoot, agentName);
	if (archives.length === 0) throw new Error(`No archived pane sessions found for ${agentName}.`);
	const wanted = selector.trim() || "latest";
	const selected = wanted === "latest" || wanted === "latest-archived"
		? archives[0]
		: archives.find((file) => file === wanted || path.basename(file) === wanted || path.basename(file).includes(wanted));
	if (!selected) throw new Error(`No archived pane session for ${agentName} matched "${wanted}". Available: ${archives.map((file) => path.basename(file)).join(", ")}`);
	await resetPersistentPaneSession(runtimeRoot, agentName);
	await fs.promises.mkdir(path.dirname(paneSessionPath(runtimeRoot, agentName)), { recursive: true, mode: 0o700 });
	await fs.promises.copyFile(selected, paneSessionPath(runtimeRoot, agentName));
	return selected;
}

async function stopLegacyPanes(legacyRoot: string): Promise<void> {
	try {
		const content = await fs.promises.readFile(path.join(legacyRoot, "panes.json"), "utf-8");
		const registry = JSON.parse(content) as PaneRegistry;
		for (const entry of Object.values(registry)) {
			if (entry.paneId) await tmux(["kill-pane", "-t", entry.paneId]);
		}
	} catch {
		// Best-effort only. The migration still moves files out of the project.
	}
}

export async function migrateLegacyProjectRuntime(cwd: string, runtimeRoot: string): Promise<void> {
	for (const legacyRoot of legacyProjectRuntimeDirs(cwd)) {
		if (legacyRoot === path.resolve(runtimeRoot) || !fs.existsSync(legacyRoot)) continue;
		await stopLegacyPanes(legacyRoot);
		await fs.promises.mkdir(runtimeRoot, { recursive: true, mode: 0o700 });
		const target = path.join(runtimeRoot, `legacy-project-runtime-${Date.now()}-${randomHex(8)}`);
		try {
			await fs.promises.rename(legacyRoot, target);
		} catch {
			try {
				await fs.promises.cp(legacyRoot, target, { recursive: true, force: false });
				await fs.promises.rm(legacyRoot, { recursive: true, force: true });
			} catch {
				// If the filesystem refuses migration, leave the legacy tree in place
				// rather than breaking startup. New runtime state still uses runtimeRoot.
			}
		}
	}
}

// Migrate from the per-package layout `vstack/pi-agents-tmux/sessions/<id>/`
// to the per-session layout `vstack/sessions/<id>/pi-agents-tmux/`. Lazy: runs
// on session_start so live sessions keep their pane registry/inbox/transcripts.
export async function migrateLegacyPackageRuntime(sessionId: string, runtimeRoot: string): Promise<void> {
	const legacyRoot = legacyPackageSessionRuntimeDir(sessionId);
	if (legacyRoot === path.resolve(runtimeRoot) || !fs.existsSync(legacyRoot)) return;
	if (fs.existsSync(runtimeRoot) && fs.readdirSync(runtimeRoot).length > 0) return;
	await fs.promises.mkdir(path.dirname(runtimeRoot), { recursive: true, mode: 0o700 });
	try {
		await fs.promises.rename(legacyRoot, runtimeRoot);
	} catch {
		try {
			await fs.promises.cp(legacyRoot, runtimeRoot, { recursive: true, force: false });
			await fs.promises.rm(legacyRoot, { recursive: true, force: true });
		} catch {
			// Leave legacy tree alone if filesystem refuses migration; new state still
			// lands at runtimeRoot.
		}
	}
}

export async function runPersistentPaneAgent(
	defaultCwd: string,
	runtimeRoot: string,
	parentSessionId: string,
	agents: AgentConfig[],
	agentName: string,
	task: string,
	cwd: string | undefined,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	step: number | undefined,
	pi: ExtensionAPI,
	forceSpawn = false,
	resumeSession?: string,
	onAgentStopped?: (agentName: string) => void,
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

	if (resumeSession?.trim()) {
		if (forceSpawn) {
			const stderr = "Cannot use resumeSession with forceSpawn: resumeSession restores an archived pane session, while forceSpawn starts fresh.";
			return {
				agent: agent.name,
				agentSource: agent.source,
				task,
				exitCode: 1,
				messages: [],
				stderr,
				stopReason: "error",
				errorMessage: stderr,
				usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
				step,
			};
		}
		const registry = await readPaneRegistry(runtimeRoot);
		const existing = registry[agent.name];
		if (existing && (await paneExists(existing.paneId))) {
			await stopPersistentPane(runtimeRoot, agent.name);
			onAgentStopped?.(agent.name);
		}
		await restoreArchivedPaneSession(runtimeRoot, agent.name, resumeSession);
	} else if (forceSpawn) {
		const registry = await readPaneRegistry(runtimeRoot);
		const existing = registry[agent.name];
		if (existing && (await paneExists(existing.paneId))) {
			const stderr = [
				`Cannot forceSpawn ${agent.name}: a live pane already exists for this agent.`,
				"vstack does not support multiple live panes for the same agent. Either:",
				`  - Drop forceSpawn and the call will reuse the existing pane (queue this task into ${existing.windowName}), or`,
				`  - Use stop_subagent or /agents stop ${agent.name} first, then retry with forceSpawn for a fresh session.`,
			].join("\n");
			return {
				agent: agent.name,
				agentSource: agent.source,
				task,
				exitCode: 1,
				messages: [],
				stderr,
				stopReason: "error",
				errorMessage: stderr,
				usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
				step,
			};
		}
		await resetPersistentPaneSession(runtimeRoot, agent.name);
	}

	let queued: QueuedPaneTask;
	try {
		queued = await queuePersistentPaneTask(runtimeRoot, parentSessionId, defaultCwd, agent, task, cwd, parentModel, parentThinkingLevel, pi, pi.getActiveTools());
	} catch (error) {
		if (!(error instanceof PaneCwdStaleError)) throw error;
		const stderr = error.message;
		return {
			agent: agent.name,
			agentSource: agent.source,
			task,
			exitCode: 1,
			messages: [],
			stderr,
			stopReason: "pane-cwd-stale",
			errorMessage: stderr,
			errorEnvelope: paneCwdStaleEnvelope(error.details, stderr),
			diagnostics: [paneCwdStaleEnvelope(error.details, stderr)],
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
			paneId: error.details.paneId,
			transcriptPath: (await readPaneRegistry(runtimeRoot))[agent.name]?.sessionFile,
			step,
		};
	}
	const sessionText = queued.sessionMode === "live" ? "reused live pane" : queued.sessionMode === "resumed" ? "resumed saved pane session" : "started new pane session";
	// Surface the taskId in the assistant-visible content so the orchestrator
	// can persist it without an extra get_subagent_result round-trip. The
	// structured `taskId` field on the return is preserved for tool callers
	// that read it directly; this text exists for harnesses that only see the
	// content text of a tool result.
	const text = queued.duplicate
		? `Duplicate task for ${agent.name} already queued; reused existing task ${queued.taskId}. Task ID: ${queued.taskId}`
		: `Queued task for ${agent.name} (${sessionText}). Task ID: ${queued.taskId}`;
	return {
		agent: agent.name,
		agentSource: agent.source,
		task,
		sessionMode: paneSessionModeToRecordMode(queued.sessionMode),
		exitCode: 0,
		messages: [{ role: "assistant", content: [{ type: "text", text }], timestamp: Date.now() } as Message],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		model: queued.pane.model,
		taskId: queued.taskId,
		paneId: queued.pane.paneId,
		queuedTaskFile: queued.taskFile,
		queuedOutboxFile: queued.outboxFile,
		paneSessionMode: queued.sessionMode,
		duplicateQueued: queued.duplicate,
		transcriptPath: queued.pane.sessionFile,
		step,
	};
}

export { archivedPaneSessionDir, archivedPaneSessions, hasSavedPaneSession };
