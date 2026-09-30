import * as fs from "node:fs";
import * as path from "node:path";
import { openLaneDir } from "../../scripts/lane-retention.js";
import { safeFileName } from "./names.js";
import { piUserDir } from "./package-config.js";
import type { PaneTaskRecord, TaskArtifactPaths } from "./types.js";

export function registryPath(runtimeRoot: string): string {
	return path.join(runtimeRoot, "panes.json");
}

export function taskRegistryPath(runtimeRoot: string): string {
	return path.join(runtimeRoot, "tasks.json");
}

export function transcriptDir(runtimeRoot: string): string {
	return path.join(runtimeRoot, "transcripts");
}

/** Where a result too long for the tool result is saved in full. */
export function fullOutputDir(runtimeRoot: string): string {
	return path.join(runtimeRoot, "outputs");
}

/** The runtime-root folders that follow the lane retention rule. */
export const RUNTIME_LANE_FOLDERS = ["transcripts", "outputs"] as const;

/** How often the live owning session rewrites its lane records. Well inside
 *  LANE_FILE_MAX_AGE_MS, so a live owner's record is never old enough for a
 *  prune to remove the lane, and a lane only a child writes to keeps it. */
export const RUNTIME_LANE_REFRESH_MS = 6 * 60 * 60 * 1000;

/** The working directory recorded for this process's runtime lanes; set only
 *  while the session that owns the runtime root is live. That session records
 *  every lane at session_start and every RUNTIME_LANE_REFRESH_MS after it, so a
 *  lane a child writes to holds its record. A child agent shares its parent's
 *  root and never sets this, so it never writes a record. */
let runtimeLaneCwd: string | undefined;

export function setRuntimeLaneCwd(cwd: string | undefined): void {
	runtimeLaneCwd = cwd;
}

/** Record `dir` as a live lane before a file is written into it. The record is
 *  rewritten on each write, so a lane the prune removed while idle is marked
 *  again, and a lane in use is never removed as empty and old. */
export function openRuntimeLane(dir: string): void {
	if (runtimeLaneCwd !== undefined) openLaneDir(dir, runtimeLaneCwd);
}

export function paneSessionPath(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "sessions", `${safeFileName(agentName)}.jsonl`);
}

export function hasSavedPaneSession(runtimeRoot: string, agentName: string): boolean {
	try {
		const stat = fs.statSync(paneSessionPath(runtimeRoot, agentName));
		return stat.isFile() && stat.size > 0;
	} catch {
		return false;
	}
}

export function archivedPaneSessionDir(runtimeRoot: string): string {
	return path.join(runtimeRoot, "sessions", "archived");
}

export function archivedPaneSessions(runtimeRoot: string, agentName: string): string[] {
	const safeName = safeFileName(agentName);
	const dir = archivedPaneSessionDir(runtimeRoot);
	try {
		return fs.readdirSync(dir)
			.filter((file) => file.startsWith(`${safeName}-`) && file.endsWith(".jsonl"))
			.map((file) => path.join(dir, file))
			.filter((file) => fs.statSync(file).isFile())
			.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
	} catch {
		return [];
	}
}

export function oneShotTranscriptPath(runtimeRoot: string, agentName: string, label: string): string {
	return path.join(transcriptDir(runtimeRoot), safeFileName(agentName), `${safeFileName(label)}.jsonl`);
}

export function outboxRoot(runtimeRoot: string): string {
	return path.join(runtimeRoot, "outbox");
}

export function completionPath(runtimeRoot: string, agentName: string, taskId: string): string {
	return path.join(outboxRoot(runtimeRoot), safeFileName(agentName), `${safeFileName(taskId)}.json`);
}

export function inboxDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "inbox", safeFileName(agentName));
}

export function processingDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "processing", safeFileName(agentName));
}

export function doneDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "done", safeFileName(agentName));
}

export function taskMarkdownPath(runtimeRoot: string, dirName: "inbox" | "processing" | "done", agentName: string, taskId: string): string {
	return path.join(runtimeRoot, dirName, safeFileName(agentName), `${safeFileName(taskId)}.md`);
}

export function completionArchiveDir(runtimeRoot: string, agentName: string): string {
	return path.join(runtimeRoot, "processed", safeFileName(agentName));
}

export function taskArtifactPaths(runtimeRoot: string, record: Pick<PaneTaskRecord, "agent" | "taskId" | "inboxFile" | "processingFile" | "doneFile" | "outboxFile" | "completionArchivePath" | "transcriptPath">): TaskArtifactPaths {
	return {
		inboxFile: record.inboxFile ?? taskMarkdownPath(runtimeRoot, "inbox", record.agent, record.taskId),
		processingFile: record.processingFile ?? taskMarkdownPath(runtimeRoot, "processing", record.agent, record.taskId),
		doneFile: record.doneFile ?? taskMarkdownPath(runtimeRoot, "done", record.agent, record.taskId),
		outboxFile: record.outboxFile ?? completionPath(runtimeRoot, record.agent, record.taskId),
		completionArchivePath: record.completionArchivePath,
		transcriptPath: record.transcriptPath,
	};
}

export function piPackageRuntimeRoots(): string[] {
	return [path.join(piUserDir(), "kendex", "sessions")];
}

