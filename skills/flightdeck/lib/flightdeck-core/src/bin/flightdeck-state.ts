#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/flightdeck-state.
//
// Subcommands: init | get | set | append | increment | tracked-entries | write-entry | path | phase | archive | activity | master-busy | run

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { appendActivityEvent } from "../activity/append.ts";
import { emitActivity } from "../activity/emit.ts";
import { formatActivityJsonl, formatActivityLine, formatActivityMarkdown } from "../activity/format.ts";
import { activityPathForSession, activityPathFromStatePath } from "../activity/paths.ts";
import { emitMergePlanUpdated, emitSessionStarted } from "../activity/workflow-emit.ts";
import { ActivityFilterError, readActivityEvents, readActivityJsonlLines, tailActivityEvents } from "../activity/read.ts";
import {
	archiveState,
	getField,
	initState,
	normalizePath,
	resolveSession,
	resolveStateBase,
	statePath,
	updateState,
} from "../state/master-state.ts";
import { resolveProjectRoot } from "../shared/project.ts";
import {
	readTrackedEntries,
	validateDomainIssueId,
	validateEntryId,
	validateTrackedEntryDomain,
} from "../state/tracked-entry.ts";
import {
	createRun,
	ensureActiveRun,
	importLegacyArchives,
	listRuns,
	readActiveRun,
	showRun,
	terminateActiveRun,
	terminateRun,
} from "../state/run-store.ts";
import { ActivityValidationError } from "../activity/types.ts";
import type { FlightdeckStateLike, TrackedEntry } from "../state/types.ts";
import {
	fdBusyFile,
	fdResolveStateDir,
	fdSessionKeyFromId,
	fdSessionLock,
	fdWakePending,
} from "../paths/daemon.ts";
import { lockedAtomicWriteAndUnlink, lockedUnlink } from "../state/locking.ts";

function die(msg: string, code = 2): never {
	process.stderr.write(`${msg}\n`);
	process.exit(code);
}

function parseGlobalAndArgs(): { action: string; session: string; rest: string[] } {
	const args = process.argv.slice(2);
	const action = args.shift();
	if (!action) die("Usage: flightdeck-state <action> [args]");
	let session = "";
	const rest: string[] = [];
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i]!;
		if (a === "--session") { session = args[++i] ?? ""; continue; }
		if (a.startsWith("--session=")) { session = a.slice("--session=".length); continue; }
		rest.push(a);
	}
	return { action: action!, rest, session };
}

const { action, session: rawSession, rest } = parseGlobalAndArgs();
const session = action === "run" && !rawSession ? "" : resolveSession(rawSession);
const file = session ? statePath(session) : "";

switch (action) {
	case "path": {
		process.stdout.write(`${file}\n`);
		break;
	}
	case "init": {
		initState(file);
		emitSessionStarted({ sessionId: session, stateFile: file, tmuxSession: session });
		break;
	}
	case "get": {
		if (rest.length < 1) die("Usage: get <jq-path>");
		if (!existsSync(file)) process.exit(1);
		process.stdout.write(getField(file, rest[0]!));
		break;
	}
	case "set": {
		if (rest.length < 2) die("Usage: set <field> <json-value>");
		const field = normalizePath(rest[0]!);
		const before = readDirectStateEntry(field);
		validateDomainSetMutation(field, rest[1]!);
		updateState(file, `${field} = (${rest[1]})`);
		emitDirectStateChange(field, before);
		emitMergePlanChange(field);
		break;
	}
	case "append": {
		if (rest.length < 2) die("Usage: append <field> <json-value>");
		const field = normalizePath(rest[0]!);
		updateState(file, `${field} += [(${rest[1]})]`);
		break;
	}
	case "increment": {
		if (rest.length < 1) die("Usage: increment <field>");
		const field = normalizePath(rest[0]!);
		updateState(file, `${field} = ((${field} // 0) + 1)`);
		break;
	}
	case "tracked-entries": {
		if (!existsSync(file)) process.exit(1);
		const state = readStateJson();
		try {
			process.stdout.write(`${JSON.stringify(readTrackedEntries(state, { strictPlanItemDomain: true, warn: warnLine }))}\n`);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			die(`Error: ${message}`);
		}
		break;
	}
	case "write-entry": {
		if (rest.length < 2) die("Usage: write-entry <ENTRY_ID> <json-entry>");
		let entry: TrackedEntry;
		try {
			entry = JSON.parse(rest[1]!) as TrackedEntry;
		} catch {
			die("Error: invalid json-entry");
		}
		const entryId = validateEntryIdOrDie(rest[0]!, "entry id");
		const jsonEntryId = validateEntryIdOrDie(entry.id, "entry.id");
		if (jsonEntryId !== entryId) die(`Error: invalid entry.id: must match entry id ${entryId}`);
		const domainIssueId = validateDomainIssueIdOrDie(entry);
		entry.id = jsonEntryId;
		if (domainIssueId && entry.domain?.issue) entry.domain.issue.id = domainIssueId;
		updateState(file, writeTrackedEntryFilter(entryId, entry));
		break;
	}
	case "archive": {
		appendSessionCompletedForArchive();
		terminateActiveRunForArchive();
		const ap = archiveState(file);
		if (ap) process.stdout.write(`${ap}\n`);
		break;
	}
	case "activity": {
		runActivity(rest);
		break;
	}
	case "phase": {
		if (rest.length < 1) die("Usage: phase <ISSUE_ID>");
		runPhase(rest[0]!);
		break;
	}
	case "master-busy": {
		if (rest.length < 1) die("Usage: master-busy <lock|unlock|check> [--master-pane <%N>] [--owner-pid <PID>]");
		runMasterBusy(rest);
		break;
	}
	case "run": {
		runRun(rest, rawSession);
		break;
	}
	default:
		die(`Unknown action: ${action}\nActions: init | get | set | append | increment | tracked-entries | write-entry | archive | activity | master-busy | run | path | phase`);
}

function writeTrackedEntryFilter(id: string, entry: TrackedEntry): string {
	const idJson = JSON.stringify(id);
	const entryJson = JSON.stringify(entry);
	return `.entries = ((.entries // {}) + {(${idJson}): ${entryJson}})`;
}

function parseDomainSetField(field: string): { id: string; path: string[] } | null {
	const bracket = field.match(/^\.entries\[(.+)]\.domain(?:\.(.*))?$/);
	if (bracket) {
		try {
			const parsed = JSON.parse(bracket[1]!);
			if (typeof parsed !== "string" || !parsed) return null;
			const rest = bracket[2] ? bracket[2]!.split(".").filter(Boolean) : [];
			return { id: parsed, path: rest };
		} catch {
			return null;
		}
	}
	const dotted = field.match(/^\.entries\.([A-Za-z0-9._-]+)\.domain(?:\.(.*))?$/);
	if (!dotted) return null;
	return { id: dotted[1]!, path: dotted[2] ? dotted[2]!.split(".").filter(Boolean) : [] };
}

function cloneRecord(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) return {};
	return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

function applyDomainPath(domain: Record<string, unknown>, path: string[], value: unknown): Record<string, unknown> {
	if (path.length === 0) {
		if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("domain must be an object or null");
		return cloneRecord(value);
	}
	if (!new Set(["issue", "github_issue", "plan_item"]).has(path[0]!)) return domain;
	let cursor: Record<string, unknown> = domain;
	for (let i = 0; i < path.length - 1; i += 1) {
		const key = path[i]!;
		const next = cursor[key];
		if (!next || typeof next !== "object" || Array.isArray(next)) cursor[key] = {};
		cursor = cursor[key] as Record<string, unknown>;
	}
	cursor[path[path.length - 1]!] = value;
	return domain;
}

function validateDomainSetMutation(field: string, jsonValue: string): void {
	const parsedField = parseDomainSetField(field);
	if (!parsedField || !existsSync(file)) return;
	let value: unknown;
	try {
		value = JSON.parse(jsonValue);
	} catch {
		die(`Error: invalid domain mutation for entry ${parsedField.id}: json-value must be valid JSON`);
	}
	let state: FlightdeckStateLike;
	try {
		state = readStateJson();
	} catch {
		return;
	}
	const entries = state.entries;
	if (!entries || typeof entries !== "object" || Array.isArray(entries)) return;
	const entry = (entries as Record<string, unknown>)[parsedField.id];
	if (!entry || typeof entry !== "object" || Array.isArray(entry)) return;
	const candidateDomain = applyDomainPath(cloneRecord((entry as Record<string, unknown>).domain), parsedField.path, value);
	try {
		validateTrackedEntryDomain({ domain: candidateDomain });
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		die(`Error: invalid domain mutation for entry ${parsedField.id}: ${message}`);
	}
}

function readStateJson(): FlightdeckStateLike {
	return JSON.parse(readFileSync(file, "utf8")) as FlightdeckStateLike;
}

function entryIdFromStateField(field: string): string | null {
	const bracket = field.match(/^\.entries\[(.+)]\.state$/);
	if (bracket) {
		try {
			const parsed = JSON.parse(bracket[1]!);
			return typeof parsed === "string" && parsed ? parsed : null;
		} catch {
			return null;
		}
	}
	const dotted = field.match(/^\.entries\.([A-Za-z0-9_-]+)\.state$/);
	return dotted?.[1] ?? null;
}

function readDirectStateEntry(field: string): Record<string, unknown> | null {
	const entryId = entryIdFromStateField(field);
	if (!entryId || !existsSync(file)) return null;
	try {
		const state = JSON.parse(readFileSync(file, "utf8")) as unknown;
		if (!state || typeof state !== "object" || Array.isArray(state)) return null;
		const entries = (state as { entries?: unknown }).entries;
		if (!entries || typeof entries !== "object" || Array.isArray(entries)) return null;
		const entry = (entries as Record<string, unknown>)[entryId];
		return entry && typeof entry === "object" && !Array.isArray(entry) ? entry as Record<string, unknown> : null;
	} catch {
		return null;
	}
}

function emitDirectStateChange(field: string, before: Record<string, unknown> | null): void {
	if (!before) return;
	const entryId = entryIdFromStateField(field);
	if (!entryId) return;
	let after: Record<string, unknown> | null = null;
	try { after = readDirectStateEntry(field); } catch { return; }
	const nextState = after?.state;
	if (typeof nextState !== "string" || before.state === nextState) return;
	const domain = before.domain && typeof before.domain === "object" && !Array.isArray(before.domain) ? before.domain as Record<string, unknown> : {};
	const issue = domain.issue && typeof domain.issue === "object" && !Array.isArray(domain.issue) ? domain.issue as Record<string, unknown> : {};
	const githubIssue = domain.github_issue && typeof domain.github_issue === "object" && !Array.isArray(domain.github_issue) ? domain.github_issue as Record<string, unknown> : {};
	const planItem = domain.plan_item && typeof domain.plan_item === "object" && !Array.isArray(domain.plan_item) ? domain.plan_item as Record<string, unknown> : {};
	const refs: Record<string, unknown> = {};
	if (typeof before.task_id === "string" && before.task_id) refs.task_id = before.task_id;
	else if (typeof planItem.item_id === "string" && planItem.item_id) refs.task_id = planItem.item_id;
	if (typeof issue.id === "string" && issue.id) refs.issue_id = issue.id;
	else if (typeof githubIssue.number === "number" && Number.isFinite(githubIssue.number)) refs.issue_id = `#${Math.trunc(githubIssue.number)}`;
	const prNumber = typeof issue.pr_number === "number" && Number.isFinite(issue.pr_number) ? issue.pr_number
		: typeof githubIssue.pr_number === "number" && Number.isFinite(githubIssue.pr_number) ? githubIssue.pr_number
		: typeof planItem.pr_number === "number" && Number.isFinite(planItem.pr_number) ? planItem.pr_number : undefined;
	if (typeof prNumber === "number") refs.pr_number = Math.trunc(prNumber);
	emitActivity({ sessionId: session, stateFile: file, tmuxSession: session }, {
		details: { dedup_key: `${entryId}:entry.state_changed:state:${nextState}`, new: nextState, old: before.state ?? null },
		entry_id: typeof before.id === "string" && before.id ? before.id : entryId,
		entry_kind: typeof before.kind === "string" ? before.kind : undefined,
		entry_title: typeof before.title === "string" ? before.title : undefined,
		harness: typeof before.harness === "string" ? before.harness : undefined,
		importance: "normal",
		pane_id: typeof before.pane_id === "string" ? before.pane_id : undefined,
		refs: Object.keys(refs).length > 0 ? refs : undefined,
		severity: "info",
		source: "flightdeck",
		summary: `${entryId} state: ${String(before.state ?? "null")} → ${nextState}`,
		type: "entry.state_changed",
	});
}

function emitMergePlanChange(field: string): void {
	if (!field.startsWith(".merge_queue") && !field.startsWith(".conflict_graph")) return;
	try {
		const state = readStateJson() as Record<string, unknown>;
		emitMergePlanUpdated(
			{ sessionId: session, stateFile: file, tmuxSession: session },
			state.merge_queue,
			state.conflict_graph,
		);
	} catch {
		// Best-effort activity must not break state writes.
	}
}

function warnLine(message: string): void {
	process.stderr.write(`${message}\n`);
}

function readStdinOrDie(usage: string): string {
	const text = readFileSync(0, "utf8").trim();
	if (!text) die(usage);
	return text;
}

function dieActivityError(error: unknown): never {
	if (error instanceof ActivityValidationError || error instanceof ActivityFilterError) die(`Error: ${error.message}`);
	if (error instanceof Error) die(`Error: ${error.message}`, 1);
	die(`Error: ${String(error)}`, 1);
}

function activityFile(overrides: { session?: string; stateFile?: string } = {}): string {
	if (overrides.stateFile) return activityPathFromStatePath(overrides.stateFile);
	if (overrides.session) return activityPathForSession(overrides.session, resolveStateBase());
	const envActivity = process.env.FLIGHTDECK_ACTIVITY_FILE;
	if (typeof envActivity === "string" && envActivity.trim()) return envActivity.trim();
	return activityPathForSession(session, resolveStateBase());
}

function runActivity(args: string[]): void {
	const sub = args[0];
	if (!sub) die("Usage: activity <path|append|tail|export> [args]");
	switch (sub) {
		case "path": {
			const opts = parseActivityReadFlags(args.slice(1), { defaultFormat: "text" });
			process.stdout.write(`${activityFile({ session: opts.session, stateFile: opts.stateFile })}\n`);
			break;
		}
		case "append": {
			const { session: sessionOverride, stateFile: stateFileOverride, positionals } = parseActivityAppendArgs(args.slice(1));
			const jsonText = positionals.length >= 1 ? positionals[0]! : readStdinOrDie("Usage: activity append <json-event>");
			let payload: unknown;
			try {
				payload = JSON.parse(jsonText);
			} catch {
				die("Error: invalid json-event");
			}
			if (!payload || typeof payload !== "object" || Array.isArray(payload)) die("Error: json-event must be an object");
			const activity = activityFile({ session: sessionOverride, stateFile: stateFileOverride });
			try {
				const result = appendActivityEvent(activity, payload, { sessionId: sessionOverride || session });
				const output: { id: string; deduped: boolean; archived?: true } = {
					id: result.event.id,
					deduped: !result.appended && !result.archived,
				};
				if (result.archived) output.archived = true;
				process.stdout.write(`${JSON.stringify(output)}\n`);
			} catch (error) {
				dieActivityError(error);
			}
			break;
		}
		case "tail": {
			const opts = parseActivityReadFlags(args.slice(1), { defaultFormat: "text", defaultLimit: 300 });
			const activity = activityFile({ session: opts.session, stateFile: opts.stateFile });
			try {
				const events = tailActivityEvents(activity, opts.limit, { filter: opts.filter, warn: warnLine });
				if (opts.format === "json") process.stdout.write(formatActivityJsonl(events));
				else process.stdout.write(events.map(formatActivityLine).join("\n") + (events.length > 0 ? "\n" : ""));
			} catch (error) {
				dieActivityError(error);
			}
			break;
		}
		case "export": {
			const opts = parseActivityReadFlags(args.slice(1), { defaultFormat: "jsonl" });
			const activity = activityFile({ session: opts.session, stateFile: opts.stateFile });
			try {
				if (opts.format === "markdown") {
					const events = readActivityEvents(activity, { filter: opts.filter, warn: warnLine });
					process.stdout.write(formatActivityMarkdown(events));
				} else if (opts.filter) {
					const lines = readActivityJsonlLines(activity, { filter: opts.filter, warn: warnLine });
					process.stdout.write(lines.join("\n") + (lines.length > 0 ? "\n" : ""));
				} else if (existsSync(activity)) {
					process.stdout.write(readFileSync(activity, "utf8"));
				}
			} catch (error) {
				dieActivityError(error);
			}
			break;
		}
		default:
			die("Usage: activity <path|append|tail|export> [args]");
	}
}

function parseActivityAppendArgs(args: string[]): { session?: string; stateFile?: string; positionals: string[] } {
	let session: string | undefined;
	let stateFile: string | undefined;
	const positionals: string[] = [];
	for (let i = 0; i < args.length; i += 1) {
		const arg = args[i]!;
		if (arg === "--session") { session = args[++i] ?? ""; continue; }
		if (arg.startsWith("--session=")) { session = arg.slice("--session=".length); continue; }
		if (arg === "--state-file") { stateFile = args[++i] ?? ""; continue; }
		if (arg.startsWith("--state-file=")) { stateFile = arg.slice("--state-file=".length); continue; }
		positionals.push(arg);
	}
	return { positionals, session: session || undefined, stateFile: stateFile || undefined };
}

function parseActivityReadFlags(args: string[], defaults: { defaultFormat: "text" | "json" | "jsonl" | "markdown"; defaultLimit?: number }): { filter?: string; format: "text" | "json" | "jsonl" | "markdown"; limit: number; session?: string; stateFile?: string } {
	let format = defaults.defaultFormat;
	let limit = defaults.defaultLimit ?? Number.MAX_SAFE_INTEGER;
	let filter: string | undefined;
	let session: string | undefined;
	let stateFile: string | undefined;
	for (let i = 0; i < args.length; i += 1) {
		const arg = args[i]!;
		if (arg === "--json") { format = "json"; continue; }
		if (arg === "--limit") { limit = parsePositiveInt(args[++i], "--limit"); continue; }
		if (arg.startsWith("--limit=")) { limit = parsePositiveInt(arg.slice("--limit=".length), "--limit"); continue; }
		if (arg === "--format") { format = parseActivityFormat(args[++i]); continue; }
		if (arg.startsWith("--format=")) { format = parseActivityFormat(arg.slice("--format=".length)); continue; }
		if (arg === "--filter") { filter = args[++i] ?? ""; continue; }
		if (arg.startsWith("--filter=")) { filter = arg.slice("--filter=".length); continue; }
		if (arg === "--session") { session = args[++i] ?? ""; continue; }
		if (arg.startsWith("--session=")) { session = arg.slice("--session=".length); continue; }
		if (arg === "--state-file") { stateFile = args[++i] ?? ""; continue; }
		if (arg.startsWith("--state-file=")) { stateFile = arg.slice("--state-file=".length); continue; }
		die(`Unknown activity flag: ${arg}`);
	}
	return { filter, format, limit, session: session || undefined, stateFile: stateFile || undefined };
}

function parseActivityFormat(value: string | undefined): "jsonl" | "markdown" {
	if (value === "jsonl" || value === "markdown") return value;
	die("Error: --format must be jsonl or markdown");
}

function parsePositiveInt(value: string | undefined, label: string): number {
	if (!value || !/^[0-9]+$/.test(value)) die(`Error: ${label} must be a non-negative integer`);
	return Number.parseInt(value, 10);
}

function validateEntryIdOrDie(value: unknown, label: string): string {
	try {
		return validateEntryId(value, label);
	} catch (error) {
		die(`Error: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function validateDomainIssueIdOrDie(entry: TrackedEntry): string | undefined {
	try {
		return validateDomainIssueId(entry);
	} catch (error) {
		die(`Error: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function terminateActiveRunForArchive(): void {
	try {
		const result = terminateActiveRun(resolveProjectRoot(), session, { stateDir: process.env.FLIGHTDECK_STATE_DIR });
		if (result.reason === "session-mismatch" && result.active) {
			const diagnostic = result.diagnostic ? ` ${result.diagnostic}` : ` active_tmux_session=${result.active.tmux_session}`;
			if (result.active.tmux_session === session) {
				die(`Error: active Flightdeck run metadata mismatch before archive; durable active pointer unchanged.${diagnostic}`, 1);
			}
			process.stderr.write(`Warning: active Flightdeck run ${result.active.run_id} does not match archive tmux session ${session}; durable active pointer unchanged.${diagnostic}\n`);
		}
	} catch (error) {
		die(`Error: failed to terminate active Flightdeck run before archive: ${error instanceof Error ? error.message : String(error)}`, 1);
	}
}

function appendSessionCompletedForArchive(): void {
	const activityPath = activityPathFromStatePath(file);
	try {
		const result = appendActivityEvent(activityPath, {
			details: { dedup_key: `${session}:session.completed` },
			importance: "important",
			natural_key: `${session}:session.completed`,
			severity: "success",
			source: "flightdeck",
			summary: `Flightdeck session completed: ${session}`,
			type: "session.completed",
		}, { sessionId: session });
		if (result.archived) die(`Error: failed to append session.completed before archive: activity sidecar is already archived (${activityPath})`, 1);
	} catch (error) {
		die(`Error: failed to append session.completed before archive: ${error instanceof Error ? error.message : String(error)}`, 1);
	}
}

interface RunFlags {
	json: boolean;
	positionals: string[];
	projectRoot?: string;
	snapshot?: string;
	stateDir?: string;
	summaryPath?: string;
	tmuxSession?: string;
}

function runRun(args: string[], globalSession: string): void {
	const sub = args[0];
	if (!sub) die("Usage: run <active|list|show|create|ensure|terminate|terminate-active|import-legacy> [args]");
	const flags = parseRunFlags(args.slice(1));
	const projectRoot = flags.projectRoot || resolveProjectRoot();
	try {
		switch (sub) {
			case "active": {
				writeJson(readActiveRun(projectRoot));
				break;
			}
			case "create": {
				const tmuxSession = flags.tmuxSession || globalSession || resolveSession("");
				writeJson(createRun(projectRoot, tmuxSession, flags.stateDir));
				break;
			}
			case "ensure": {
				const tmuxSession = flags.tmuxSession || globalSession || resolveSession("");
				writeJson(ensureActiveRun(projectRoot, tmuxSession, flags.stateDir));
				break;
			}
			case "list": {
				const result = listRuns(projectRoot);
				if (flags.json) writeJson(result);
				else {
					for (const run of result.runs) {
						const status = run.terminated ? "terminated" : "active";
						process.stdout.write(`${run.run_id}\t${status}\t${run.started_at}\t${run.tmux_session}\n`);
					}
				}
				break;
			}
			case "show": {
				const runId = flags.positionals[0];
				if (!runId) die("Usage: run show <run-id> [--snapshot <timestamp>] [--project-root <path>]");
				writeJson(showRun(projectRoot, runId, flags.snapshot));
				break;
			}
			case "terminate": {
				const runId = flags.positionals[0];
				if (!runId) die("Usage: run terminate <run-id> [--project-root <path>]");
				writeJson(terminateRun(projectRoot, runId, { stateDir: flags.stateDir, summaryPath: flags.summaryPath, tmuxSession: flags.tmuxSession }));
				break;
			}
			case "terminate-active": {
				const tmuxSession = flags.tmuxSession || globalSession || resolveSession("");
				writeJson(terminateActiveRun(projectRoot, tmuxSession, { stateDir: flags.stateDir, summaryPath: flags.summaryPath }));
				break;
			}
			case "import-legacy": {
				writeJson(importLegacyArchives(projectRoot, flags.stateDir));
				break;
			}
			default:
				die("Usage: run <active|list|show|create|ensure|terminate|terminate-active|import-legacy> [args]");
		}
	} catch (error) {
		die(`Error: ${error instanceof Error ? error.message : String(error)}`, 1);
	}
}

function parseRunFlags(args: string[]): RunFlags {
	const flags: RunFlags = { json: false, positionals: [] };
	for (let i = 0; i < args.length; i += 1) {
		const arg = args[i]!;
		if (arg === "--json") { flags.json = true; continue; }
		if (arg === "--project-root") { flags.projectRoot = args[++i] ?? ""; continue; }
		if (arg.startsWith("--project-root=")) { flags.projectRoot = arg.slice("--project-root=".length); continue; }
		if (arg === "--tmux-session") { flags.tmuxSession = args[++i] ?? ""; continue; }
		if (arg.startsWith("--tmux-session=")) { flags.tmuxSession = arg.slice("--tmux-session=".length); continue; }
		if (arg === "--state-dir") { flags.stateDir = args[++i] ?? ""; continue; }
		if (arg.startsWith("--state-dir=")) { flags.stateDir = arg.slice("--state-dir=".length); continue; }
		if (arg === "--summary-path") {
			const value = args[i + 1];
			if (value === undefined || value.trim() === "" || value.startsWith("--")) die("Usage: --summary-path requires a non-empty value");
			flags.summaryPath = value;
			i += 1;
			continue;
		}
		if (arg.startsWith("--summary-path=")) {
			const value = arg.slice("--summary-path=".length);
			if (value.trim() === "") die("Usage: --summary-path requires a non-empty value");
			flags.summaryPath = value;
			continue;
		}
		if (arg === "--snapshot") { flags.snapshot = args[++i] ?? ""; continue; }
		if (arg.startsWith("--snapshot=")) { flags.snapshot = arg.slice("--snapshot=".length); continue; }
		if (arg.startsWith("--")) die(`Unknown run flag: ${arg}`);
		flags.positionals.push(arg);
	}
	return flags;
}

function writeJson(value: unknown): void {
	process.stdout.write(`${JSON.stringify(value)}\n`);
}

function runPhase(issue: string): void {
	const root = resolveProjectRoot();
	const orchDir = process.env.ORCH_STATE_DIR && process.env.ORCH_STATE_DIR.trim() ? process.env.ORCH_STATE_DIR.trim() : "tmp";
	const orchFile = join(root, orchDir, `workflow-state-${issue}.json`);
	if (existsSync(orchFile)) {
		let obj: Record<string, unknown> = {};
		try { obj = JSON.parse(readFileSync(orchFile, "utf8")); } catch { /* fall through */ }
		const cycles = toInt(obj.cycles, 0);
		const reviewers = Array.isArray(obj.review_agents) ? obj.review_agents.length : 0;
		const escalated = Array.isArray(obj.escalated_items) ? obj.escalated_items.length : 0;
		const prReview = toInt((obj.pr_comment_review as { iterations?: unknown } | undefined)?.iterations, 0);
		const childCount = obj.child_sessions && typeof obj.child_sessions === "object" ? Object.keys(obj.child_sessions as Record<string, unknown>).length : 0;
		const parts: string[] = [];
		if (cycles > 0) parts.push(`cycle=${cycles}`);
		if (reviewers > 0) parts.push(`reviewers=${reviewers}`);
		if (prReview > 0) parts.push(`pr-review=${prReview}`);
		if (childCount > 0) parts.push(`children=${childCount}`);
		if (escalated > 0) parts.push(`escalated=${escalated}`);
		process.stdout.write(`${parts.length === 0 ? "pre-cycle" : parts.join(" ")}\n`);
		return;
	}
	if (existsSync(file)) {
		const fd = getField(file, `.entries["${issue}"].state // empty`).trim();
		if (fd) {
			process.stdout.write(`fd:${fd}\n`);
			return;
		}
	}
	process.stdout.write("unknown\n");
}

function toInt(v: unknown, fallback: number): number {
	if (typeof v === "number" && Number.isFinite(v)) return Math.floor(v);
	if (typeof v === "string" && /^-?\d+$/.test(v)) return Number.parseInt(v, 10);
	return fallback;
}

function runMasterBusy(args: string[]): void {
	const sub = args[0]!;
	const sidRes = spawnSync("tmux", ["display-message", "-p", "-t", session, "#{session_id}"], { encoding: "utf8" });
	const sid = (sidRes.stdout ?? "").trim();
	if (!sid) die(`Error: cannot resolve session_id for ${session}`);
	const fdDir = fdResolveStateDir();
	const sidKey = fdSessionKeyFromId(sid);
	const busyFile = fdBusyFile(fdDir, sidKey);
	const sessionLock = fdSessionLock(fdDir, sidKey);
	switch (sub) {
		case "lock": {
			let masterPane = "";
			let ownerPid = "";
			for (let i = 1; i < args.length; i += 1) {
				if (args[i] === "--master-pane") masterPane = args[++i] ?? "";
				else if (args[i] === "--owner-pid") ownerPid = args[++i] ?? "";
			}
			if (!masterPane) {
				masterPane = (process.env.TMUX_PANE ?? "").trim();
				if (!masterPane) {
					const r = spawnSync("tmux", ["display-message", "-p", "#{pane_id}"], { encoding: "utf8" });
					masterPane = (r.stdout ?? "").trim();
				}
			}
			if (!masterPane) die("Error: cannot resolve master pane id");
			const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
			const wakePending = fdWakePending(fdDir, sidKey);
			const payload = ownerPid && /^[1-9][0-9]*$/.test(ownerPid)
				? { pid: Number.parseInt(ownerPid, 10), master_pane_id: masterPane, started_at: startedAt }
				: { master_pane_id: masterPane, started_at: startedAt };
			// Hold the daemon SESSION_LOCK across the busy-file publish AND
			// the WAKE_PENDING clear. This matches the bash contract that
			// keeps the daemon's append_event / wake_master paths from
			// racing master's turn-start handoff.
			const r = lockedAtomicWriteAndUnlink(sessionLock, busyFile, JSON.stringify(payload), wakePending);
			if (r.status !== 0) {
				process.stderr.write(r.stderr || "");
				process.exit(r.status ?? 1);
			}
			break;
		}
		case "unlock": {
			// Release matching the bash `rm -f $BUSY_FILE` under session lock.
			const r = lockedUnlink(sessionLock, busyFile);
			if (r.status !== 0) {
				process.stderr.write(r.stderr || "");
				process.exit(r.status ?? 1);
			}
			break;
		}
		case "check": {
			if (existsSync(busyFile)) {
				process.stdout.write(readFileSync(busyFile, "utf8"));
				break;
			}
			process.exit(1);
		}
		default:
			die("Usage: master-busy <lock|unlock|check>");
	}
}
