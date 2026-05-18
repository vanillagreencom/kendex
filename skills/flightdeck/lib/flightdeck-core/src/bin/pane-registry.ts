#!/usr/bin/env bun
// CLI for tracked-entry pane registry. Handles 5-harness spawn
// discovery, freshness-gated adapter-args resolution, and live-pane
// reconciliation against tmux.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, unlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ocAdapterIsFresh, ocReleasePort, ocSpawnFile } from "../paths/oc.ts";
import { ccAdapterIsFresh, ccMcpDir, ccReleasePort, ccSpawnFile } from "../paths/cc.ts";
import { piBridgeIsFresh, piSpawnFile } from "../paths/pi.ts";
import { emitActivity } from "../activity/emit.ts";
import { emitCloseIssue, emitMergeAction, emitWorkflowDecision } from "../activity/workflow-emit.ts";
import type { ActivityEventInput } from "../activity/types.ts";
import type { CloseIssueOutcome } from "../activity/workflow-emit.ts";
import { cxAdapterIsFresh, cxSpawnFile } from "../paths/codex.ts";
import { decideShellAdhocWake } from "../daemon/shell-adhoc-wake.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FD_STATE_SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");

function die(msg: string, code = 2): never {
	process.stderr.write(`${msg}\n`);
	process.exit(code);
}

function fdState(args: string[]): { status: number | null; stdout: string; stderr: string } {
	const r = spawnSync(FD_STATE_SCRIPT, args, { encoding: "utf8" });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function fdStateOrDie(args: string[]): string {
	const r = fdState(args);
	if (r.status !== 0) {
		process.stderr.write(r.stderr);
		process.exit(r.status ?? 1);
	}
	return r.stdout;
}

let cachedStateFile = "";
let cachedTmuxSession = "";

function registryStateFile(): string {
	if (!cachedStateFile) cachedStateFile = fdStateOrDie(["path"]).trim();
	return cachedStateFile;
}

function registryTmuxSession(): string {
	if (!cachedTmuxSession) cachedTmuxSession = tmuxCurrentSession();
	return cachedTmuxSession;
}

function nowIso(): string {
	return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function tmuxField(target: string, format: string): string {
	const r = spawnSync("tmux", ["display-message", "-t", target, "-p", format], { encoding: "utf8" });
	if (r.status !== 0) return "";
	return (r.stdout ?? "").trim();
}

function tmuxCurrentSession(): string {
	const r = spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" });
	return (r.stdout ?? "").trim() || "unknown";
}

function tmuxPaneExists(target: string): boolean {
	const r = spawnSync("tmux", ["list-panes", "-t", target], { encoding: "utf8" });
	return r.status === 0;
}

// vstack#85 F1: tmux probes return a tagged Result so callers that
// drive destructive transitions (cmdReconcile, cmdRemoveMerged,
// cmdTeardownWindow) can distinguish "verified empty" from "probe
// failed" instead of silently treating a momentary tmux hiccup as
// "every pane is gone".
type TmuxLivePaneIdsResult =
	| { ok: true; panes: Set<string> }
	| { ok: false; error: string };

function tmuxLivePaneIdsResult(): TmuxLivePaneIdsResult {
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	if (r.status !== 0) {
		const stderr = (r.stderr ?? "").trim();
		return { ok: false, error: `tmux list-panes -a failed (status=${r.status})${stderr ? `: ${stderr}` : ""}` };
	}
	const panes = new Set<string>();
	for (const line of (r.stdout ?? "").split("\n")) {
		if (line) panes.add(line);
	}
	return { ok: true, panes };
}

// Legacy adapter — preserves the historical empty-on-failure shape for
// non-destructive callers (find-by-pane, list --format inner-panes-live).
// Destructive callers must use tmuxLivePaneIdsResult() directly.
function tmuxLivePaneIds(): Set<string> {
	const r = tmuxLivePaneIdsResult();
	return r.ok ? r.panes : new Set<string>();
}

function paneMatchIsLive(paneId: string, paneTarget: string): boolean {
	if (paneId) return tmuxLivePaneIds().has(paneId);
	return !!paneTarget && tmuxPaneExists(paneTarget);
}

function warnStalePaneMatch(paneId: string, paneTarget: string): void {
	const lookup = paneId || paneTarget || "<none>";
	process.stderr.write(`Warning: find-by-pane match ${lookup} is stale (pane no longer exists); use pane-registry reconcile.\n`);
}

function tmuxPaneCountInWindow(windowId: string): number {
	const r = spawnSync("tmux", ["list-panes", "-t", windowId, "-F", "#{pane_id}"], { encoding: "utf8" });
	if (r.status !== 0) return 0;
	return (r.stdout ?? "").split("\n").filter(Boolean).length;
}

function tmuxBasePaneIndex(): string {
	const r = spawnSync("tmux", ["show-options", "-g", "pane-base-index"], { encoding: "utf8" });
	const out = (r.stdout ?? "").trim();
	const tok = out.split(/\s+/)[1] ?? "0";
	return tok || "0";
}

function readJsonIfExists<T>(path: string): T | null {
	if (!existsSync(path)) return null;
	try { return JSON.parse(readFileSync(path, "utf8")) as T; }
	catch { return null; }
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function lookupId(raw: string): string {
	if (!raw.trim().startsWith("{")) return raw;
	try {
		const obj = JSON.parse(raw) as unknown;
		return isRecord(obj) && typeof obj.id === "string" ? obj.id : raw;
	} catch {
		return raw;
	}
}

function lookupIdOrPane(raw: string, requireLivePane = false): string {
	const id = lookupId(raw);
	if (!id) return id;
	if (registryHasEntry(id)) return id;
	const matches = Object.entries(trackedEntries()).filter(([, entry]) => entry.pane_id === id || entry.pane_target === id);
	if (!matches.length) return id;
	if (!requireLivePane) return matches[0]![0];
	for (const [key, entry] of matches) {
		const paneId = typeof entry.pane_id === "string" ? entry.pane_id : "";
		const paneTarget = typeof entry.pane_target === "string" ? entry.pane_target : "";
		if (paneMatchIsLive(paneId, paneTarget)) return key;
	}
	const [, firstEntry] = matches[0]!;
	warnStalePaneMatch(
		typeof firstEntry.pane_id === "string" ? firstEntry.pane_id : "",
		typeof firstEntry.pane_target === "string" ? firstEntry.pane_target : "",
	);
	process.exit(1);
}

interface InitFields {
	branch: string;
	cc_port: string;
	cc_session_uuid: string;
	cc_transcript: string;
	cc_url: string;
	cwd: string;
	cx_thread_id: string;
	cx_ws: string;
	discovery_error: string;
	harness: string;
	github_url: string;
	kind: string;
	launch_cmd: string;
	launch_effort: string;
	launch_model: string;
	launch_argv_json: string;
	launch_effort_source: string;
	launch_model_source: string;
	launch_reasoning_status: string;
	launch_requested_effort: string;
	launch_requested_model: string;
	launch_resolved_effort: string;
	launch_resolved_model: string;
	launch_unsupported_reason: string;
	oc_port: string;
	oc_session_id: string;
	oc_url: string;
	pane_id: string;
	pane_index: string;
	pane_target: string;
	pi_bridge_pid: string;
	pi_bridge_socket: string;
	pi_session_id: string;
	pr: string;
	title: string;
	tracker: string;
	window: string;
	window_id: string;
	window_index: string;
	worktree: string;
}

function defaultInitFields(entryId: string, kind = "adhoc"): InitFields {
	return {
		branch: "",
		cc_port: "", cc_session_uuid: "", cc_transcript: "", cc_url: "",
		cwd: "",
		cx_thread_id: "", cx_ws: "",
		discovery_error: "",
		github_url: "",
		harness: "",
		kind,
		launch_argv_json: "", launch_cmd: "", launch_effort: "", launch_effort_source: "",
		launch_model: "", launch_model_source: "", launch_reasoning_status: "",
		launch_requested_effort: "", launch_requested_model: "",
		launch_resolved_effort: "", launch_resolved_model: "", launch_unsupported_reason: "",
		oc_port: "", oc_session_id: "", oc_url: "",
		pane_id: "", pane_index: tmuxBasePaneIndex() || "0", pane_target: "",
		pi_bridge_pid: "", pi_bridge_socket: "", pi_session_id: "",
		pr: "",
		title: entryId,
		tracker: "linear",
		window: "", window_id: "", window_index: "",
		worktree: "",
	};
}

const INIT_FLAG_MAP: Record<string, keyof InitFields> = {
	"--branch": "branch",
	"--cc-port": "cc_port",
	"--cc-session-uuid": "cc_session_uuid",
	"--cc-transcript": "cc_transcript",
	"--cc-url": "cc_url",
	"--cwd": "cwd",
	"--cx-thread-id": "cx_thread_id",
	"--cx-ws": "cx_ws",
	"--discovery-error": "discovery_error",
	"--github-issue-url": "github_url",
	"--github-url": "github_url",
	"--harness": "harness",
	"--kind": "kind",
	"--launch-argv-json": "launch_argv_json",
	"--launch-cmd": "launch_cmd",
	"--launch-effort": "launch_effort",
	"--launch-effort-source": "launch_effort_source",
	"--launch-model": "launch_model",
	"--launch-model-source": "launch_model_source",
	"--launch-reasoning-status": "launch_reasoning_status",
	"--launch-requested-effort": "launch_requested_effort",
	"--launch-requested-model": "launch_requested_model",
	"--launch-resolved-effort": "launch_resolved_effort",
	"--launch-resolved-model": "launch_resolved_model",
	"--launch-unsupported-reason": "launch_unsupported_reason",
	"--oc-port": "oc_port",
	"--oc-session-id": "oc_session_id",
	"--oc-url": "oc_url",
	"--pane-id": "pane_id",
	"--pane-index": "pane_index",
	"--pane-target": "pane_target",
	"--pi-bridge-pid": "pi_bridge_pid",
	"--pi-bridge-socket": "pi_bridge_socket",
	"--pi-session-id": "pi_session_id",
	"--pr": "pr",
	"--title": "title",
	"--tracker": "tracker",
	"--window": "window",
	"--window-id": "window_id",
	"--window-index": "window_index",
	"--worktree": "worktree",
};

function parseInitFlags(fields: InitFields, args: string[]): void {
	for (let i = 0; i < args.length; i += 1) {
		const key = INIT_FLAG_MAP[args[i] ?? ""];
		if (!key) die(`Unknown flag: ${args[i]}`);
		fields[key] = args[++i] ?? "";
	}
}

function hydrateLaunchFields(fields: InitFields, launch: Record<string, unknown> | undefined): void {
	if (!launch) return;
	if (!fields.launch_model) fields.launch_model = String(launch.model ?? "");
	if (!fields.launch_effort) fields.launch_effort = String(launch.effort ?? "");
	if (!fields.launch_requested_model) fields.launch_requested_model = String(launch.requested_model ?? "");
	if (!fields.launch_requested_effort) fields.launch_requested_effort = String(launch.requested_effort ?? "");
	if (!fields.launch_model_source) fields.launch_model_source = String(launch.model_source ?? launch.source ?? "");
	if (!fields.launch_effort_source) fields.launch_effort_source = String(launch.effort_source ?? launch.source ?? "");
	if (!fields.launch_resolved_model) fields.launch_resolved_model = String(launch.resolved_model ?? launch.model ?? "");
	if (!fields.launch_resolved_effort) fields.launch_resolved_effort = String(launch.resolved_effort ?? launch.effort ?? "");
	if (!fields.launch_reasoning_status) fields.launch_reasoning_status = String(launch.reasoning_status ?? "");
	if (!fields.launch_unsupported_reason) fields.launch_unsupported_reason = String(launch.unsupported_reason ?? "");
	if (!fields.launch_argv_json && Array.isArray(launch.argv)) fields.launch_argv_json = JSON.stringify(launch.argv);
}

function parseArgvJson(value: string): string[] | null {
	if (!value) return null;
	try {
		const parsed = JSON.parse(value) as unknown;
		return Array.isArray(parsed) && parsed.every((item) => typeof item === "string") ? parsed : null;
	} catch {
		return null;
	}
}

function hydrateSpawnMetadata(entryId: string, fields: InitFields): void {
	const harness = fields.harness;
	if (harness === "opencode" && !fields.oc_url) {
		const rec = readJsonIfExists<Record<string, unknown>>(ocSpawnFile(entryId));
		if (rec) {
			fields.oc_url = String(rec.url ?? "");
			fields.oc_session_id = String(rec.session_id ?? "");
			fields.oc_port = String(rec.port ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			hydrateLaunchFields(fields, launch);
		}
	}
	if (harness === "claude" && !fields.cc_url) {
		const rec = readJsonIfExists<Record<string, unknown>>(ccSpawnFile(entryId));
		if (rec) {
			fields.cc_url = String(rec.url ?? "");
			fields.cc_session_uuid = String(rec.session_uuid ?? "");
			fields.cc_port = String(rec.port ?? "");
			fields.cc_transcript = String(rec.transcript ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			hydrateLaunchFields(fields, launch);
		}
	}
	if (harness === "pi" && !fields.pi_bridge_pid) {
		const rec = readJsonIfExists<Record<string, unknown>>(piSpawnFile(entryId));
		if (rec) {
			fields.pi_bridge_pid = String(rec.pid ?? "");
			fields.pi_bridge_socket = String(rec.socket ?? "");
			fields.pi_session_id = String(rec.session_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			hydrateLaunchFields(fields, launch);
		}
	}
	if (harness === "codex" && !fields.cx_ws) {
		const rec = readJsonIfExists<Record<string, unknown>>(cxSpawnFile(entryId));
		if (rec) {
			fields.cx_ws = String(rec.url ?? "");
			fields.cx_thread_id = String(rec.thread_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			hydrateLaunchFields(fields, launch);
		}
	}
}

function cmdInitEntry(entryId: string, args: string[], mode: "entry" | "issue" = "entry"): void {
	if (!entryId) die(mode === "issue" ? "Usage: pane-registry init <ISSUE> [flags]" : "Usage: pane-registry init-entry <ENTRY_ID> [flags]");
	const fields = defaultInitFields(entryId, mode === "issue" ? "issue" : "adhoc");
	parseInitFlags(fields, args);
	if (!fields.title) fields.title = entryId;
	if (mode === "issue") fields.kind = "issue";
	if (!["adhoc", "issue", "workflow"].includes(fields.kind)) die("init-entry requires --kind adhoc|issue|workflow");
	if (!["linear", "github"].includes(fields.tracker)) die("init-entry requires --tracker linear|github");
	if (mode === "issue" && !fields.worktree) die("init requires --window, --harness, --worktree");
	if (fields.kind === "issue" && !fields.worktree) fields.worktree = fields.cwd;
	if (!fields.cwd) fields.cwd = fields.worktree;
	if (!fields.window || !fields.harness || !fields.cwd) die(mode === "issue" ? "init requires --window, --harness, --worktree" : "init-entry requires --title, --kind, --cwd, --window, --harness");
	if (fields.kind === "issue" && fields.tracker === "github") {
		if (!/^\d+$/.test(entryId)) die("github tracker requires a numeric entry id");
		if (!fields.github_url) die("github tracker requires --github-url");
	}

	hydrateSpawnMetadata(entryId, fields);
	fdStateOrDie(["init"]);
	const session = tmuxCurrentSession();
	const paneTarget = fields.pane_target || `${session}:${fields.window}.${fields.pane_index}`;
	let paneId = fields.pane_id;
	if (!paneId && tmuxPaneExists(paneTarget)) paneId = tmuxField(paneTarget, "#{pane_id}");

	const launchArgv = parseArgvJson(fields.launch_argv_json);
	const launch = (fields.launch_model || fields.launch_effort || fields.launch_cmd || fields.launch_requested_model || fields.launch_requested_effort || fields.launch_resolved_model || fields.launch_resolved_effort || fields.launch_reasoning_status || fields.launch_unsupported_reason || launchArgv)
		? {
			argv: launchArgv,
			cmd: fields.launch_cmd || null,
			effort: fields.launch_effort || null,
			effort_source: fields.launch_effort_source || null,
			model: fields.launch_model || null,
			model_source: fields.launch_model_source || null,
			reasoning_status: fields.launch_reasoning_status || null,
			requested_effort: fields.launch_requested_effort || null,
			requested_model: fields.launch_requested_model || null,
			resolved_effort: fields.launch_resolved_effort || fields.launch_effort || null,
			resolved_model: fields.launch_resolved_model || fields.launch_model || null,
			unsupported_reason: fields.launch_unsupported_reason || null,
		}
		: null;
	const adapter = {
		cc_port: numOrNull(fields.cc_port),
		cc_session_uuid: strOrNull(fields.cc_session_uuid),
		cc_transcript: strOrNull(fields.cc_transcript),
		cc_url: strOrNull(fields.cc_url),
		cx_thread_id: strOrNull(fields.cx_thread_id),
		cx_ws: strOrNull(fields.cx_ws),
		oc_port: numOrNull(fields.oc_port),
		oc_session_id: strOrNull(fields.oc_session_id),
		oc_url: strOrNull(fields.oc_url),
		pi_bridge_pid: numOrNull(fields.pi_bridge_pid),
		pi_bridge_socket: strOrNull(fields.pi_bridge_socket),
		pi_session_id: strOrNull(fields.pi_session_id),
	};
	const domain = fields.kind === "issue"
		? fields.tracker === "github"
			? {
				github_issue: {
					merge_commit: null,
					number: Number.parseInt(entryId, 10),
					pr_number: numOrNull(fields.pr),
					scope_files_actual: null,
					url: fields.github_url,
					worktree: fields.worktree,
				},
			}
			: {
				issue: {
					id: entryId,
					orchestration_started: false,
					pr_number: numOrNull(fields.pr),
					scope_files_actual: null,
					scope_files_declared: null,
					worktree: strOrNull(fields.worktree),
				},
			}
		: null;
	const ts = nowIso();
	const entry: Record<string, unknown> = {
		adapter,
		branch: strOrNull(fields.branch),
		cwd: fields.cwd,
		decisions_log: [],
		discovery_error: strOrNull(fields.discovery_error),
		domain,
		harness: fields.harness,
		id: entryId,
		kind: fields.kind,
		last_capture_hash: null,
		// Stays null until the daemon actually polls the pane. Seeding
		// this with `ts` (spawn time) made fresh sessions look like
		// they'd been polled, which caused the dashboard's stale-state
		// detector to start the age clock from spawn-time and surface
		// alarming "stale from Xm ago" copy before any polling occurred.
		last_polled_at: null,
		last_response_at: null,
		launch,
		pane_id: paneId || null,
		pane_target: paneTarget || null,
		spawned_at: ts,
		state: "waiting",
		substate: null,
		title: fields.title,
		unknown_since: null,
		window: fields.window,
		window_id: strOrNull(fields.window_id),
		window_index: numOrNull(fields.window_index),
	};
	if (fields.kind !== "issue") {
		const pr = numOrNull(fields.pr);
		if (pr !== null) entry.pr_number = pr;
		if (fields.worktree) entry.worktree = strOrNull(fields.worktree);
	}

	fdStateOrDie(["write-entry", entryId, JSON.stringify(entry)]);
	emitEntryRegistered(entry);
}

// ----- init ----------------------------------------------------------------

function cmdInit(issue: string, args: string[]): void {
	cmdInitEntry(issue, args, "issue");
}
function strOrNull(s: string): string | null {
	return s ? s : null;
}

function numOrNull(s: string): number | null {
	if (!s) return null;
	const n = Number(s);
	return Number.isFinite(n) ? n : null;
}

function trackedEntries(): Record<string, Record<string, unknown>> {
	const out = fdStateOrDie(["tracked-entries"]);
	try {
		const parsed = JSON.parse(out || "{}") as unknown;
		if (!isRecord(parsed)) return {};
		const entries: Record<string, Record<string, unknown>> = {};
		for (const [key, value] of Object.entries(parsed)) if (isRecord(value)) entries[key] = value;
		return entries;
	} catch {
		return {};
	}
}

function registryHasEntry(id: string): boolean {
	const idJson = JSON.stringify(id);
	const r = fdState(["get", `.entries[${idJson}] != null`]);
	const status = r.status ?? 0;
	if (status >= 2 || r.stderr.trim()) {
		process.stderr.write(`pane-registry: registry read failed (flightdeck-state exit=${status}): ${r.stderr}`);
		if (!r.stderr.endsWith("\n")) process.stderr.write("\n");
		process.exit(6);
	}
	return r.status === 0 && r.stdout.trim() === "true";
}

type EntryRecord = Record<string, unknown>;

function entryById(id: string): EntryRecord | null {
	const idJson = JSON.stringify(id);
	const r = fdState(["get", `.entries[${idJson}] // empty`]);
	const status = r.status ?? 0;
	if (status >= 2 || r.stderr.trim()) {
		process.stderr.write(`pane-registry: registry read failed (flightdeck-state exit=${status}): ${r.stderr}`);
		if (!r.stderr.endsWith("\n")) process.stderr.write("\n");
		process.exit(6);
	}
	const raw = (r.stdout ?? "").trim();
	if (r.status === 1 || !raw || raw === "null") return null;
	try {
		const parsed = JSON.parse(raw) as unknown;
		return isRecord(parsed) ? parsed : null;
	} catch {
		process.stderr.write(`pane-registry: malformed registry entry for '${id}'\n`);
		process.exit(6);
	}
}

function entryByIdOrDie(id: string): EntryRecord {
	const entry = entryById(id);
	if (!entry) die(`pane-registry: entry '${id}' not found in .entries`);
	return entry;
}

function entryString(entry: EntryRecord, key: string): string | undefined {
	const value = entry[key];
	return typeof value === "string" && value ? value : undefined;
}

function entryIssue(entry: EntryRecord): Record<string, unknown> {
	const domain = isRecord(entry.domain) ? entry.domain : {};
	return isRecord(domain.issue) ? domain.issue : {};
}

function entryGithubIssue(entry: EntryRecord): Record<string, unknown> {
	const domain = isRecord(entry.domain) ? entry.domain : {};
	return isRecord(domain.github_issue) ? domain.github_issue : {};
}

function entryRefs(entry: EntryRecord): Record<string, unknown> | undefined {
	const refs: Record<string, unknown> = {};
	const issue = entryIssue(entry);
	const githubIssue = entryGithubIssue(entry);
	const taskId = entryString(entry, "task_id");
	if (taskId) refs.task_id = taskId;
	const issueId = typeof issue.id === "string" && issue.id ? issue.id
		: typeof githubIssue.number === "number" && Number.isFinite(githubIssue.number) ? `#${Math.trunc(githubIssue.number)}` : undefined;
	if (issueId) refs.issue_id = issueId;
	const prNumber = typeof issue.pr_number === "number" && Number.isFinite(issue.pr_number)
		? issue.pr_number
		: typeof githubIssue.pr_number === "number" && Number.isFinite(githubIssue.pr_number) ? githubIssue.pr_number
		: typeof entry.pr_number === "number" && Number.isFinite(entry.pr_number) ? entry.pr_number : undefined;
	if (typeof prNumber === "number") refs.pr_number = Math.trunc(prNumber);
	return Object.keys(refs).length > 0 ? refs : undefined;
}

function activityEntryFields(entry: EntryRecord, fallbackId?: string): Pick<ActivityEventInput, "entry_id" | "entry_title" | "entry_kind" | "harness" | "pane_id" | "refs"> {
	const out: Pick<ActivityEventInput, "entry_id" | "entry_title" | "entry_kind" | "harness" | "pane_id" | "refs"> = {};
	const id = entryString(entry, "id") ?? fallbackId;
	if (id) out.entry_id = id;
	const title = entryString(entry, "title");
	if (title) out.entry_title = title;
	const kind = entryString(entry, "kind");
	if (kind) out.entry_kind = kind;
	const harness = entryString(entry, "harness");
	if (harness) out.harness = harness;
	const paneId = entryString(entry, "pane_id");
	if (paneId) out.pane_id = paneId;
	const refs = entryRefs(entry);
	if (refs) out.refs = refs as ActivityEventInput["refs"];
	return out;
}

function emitRegistryActivity(entry: EntryRecord | null, event: ActivityEventInput, fallbackId?: string): void {
	emitActivity({ sessionId: registryTmuxSession(), stateFile: registryStateFile(), tmuxSession: registryTmuxSession() }, {
		...activityEntryFields(entry ?? {}, fallbackId),
		...event,
		source: event.source ?? "flightdeck",
	});
}

function registryWorkflowContext(entry: EntryRecord | null): { entry: EntryRecord | null; sessionId: string; stateFile: string; tmuxSession: string } {
	return { entry, sessionId: registryTmuxSession(), stateFile: registryStateFile(), tmuxSession: registryTmuxSession() };
}

function emitIssueMergeState(entry: EntryRecord, state: string): void {
	const issue = entryIssue(entry);
	const githubIssue = entryGithubIssue(entry);
	const pr = typeof issue.pr_number === "number" && Number.isFinite(issue.pr_number) ? Math.trunc(issue.pr_number)
		: typeof githubIssue.pr_number === "number" && Number.isFinite(githubIssue.pr_number) ? Math.trunc(githubIssue.pr_number) : undefined;
	if (state === "merge-ready") emitMergeAction(registryWorkflowContext(entry), pr, "queued");
	else if (state === "merged") emitMergeAction(registryWorkflowContext(entry), pr, "merged", { commit: entryString(issue, "merge_commit") ?? entryString(githubIssue, "merge_commit") ?? entryString(entry, "merge_commit") ?? "" });
	else if (state === "aborted") emitMergeAction(registryWorkflowContext(entry), pr, "blocked", { reason: "aborted" });
}

function emitEntryRegistered(entry: EntryRecord): void {
	const id = entryString(entry, "id") ?? "unknown";
	const kind = entryString(entry, "kind") ?? "entry";
	const title = entryString(entry, "title") ?? id;
	emitRegistryActivity(entry, {
		details: { dedup_key: `${id}:entry.registered:${kind}:${title}` },
		importance: "important",
		severity: "info",
		summary: `${kind} ${id} registered: ${title}`,
		type: "entry.registered",
	}, id);
}

function emitEntryStateChanged(entry: EntryRecord, oldState: unknown, newState: string): void {
	const id = entryString(entry, "id") ?? "unknown";
	emitRegistryActivity(entry, {
		details: { dedup_key: `${id}:entry.state_changed:state:${newState}`, new: newState, old: oldState ?? null },
		importance: "normal",
		severity: "info",
		summary: `${id} state: ${String(oldState ?? "null")} → ${newState}`,
		type: "entry.state_changed",
	}, id);
}

function emitEntrySubstateChanged(entry: EntryRecord, substate: string): void {
	const id = entryString(entry, "id") ?? "unknown";
	const parentState = entry.state ?? null;
	emitRegistryActivity(entry, {
		details: { dedup_key: `${id}:entry.state_changed:substate:${substate}`, parentState, substate },
		importance: "noisy",
		severity: "info",
		summary: `${id} substate: ${substate}`,
		type: "entry.state_changed",
	}, id);
}

function decisionSummary(answer: string): string {
	return answer.length <= 120 ? answer : `${answer.slice(0, 119)}…`;
}

function emitDecisionRecorded(entry: EntryRecord, tag: string, answer: string, sequence: number): void {
	emitWorkflowDecision(registryWorkflowContext(entry), tag, {
		answer,
		sequence,
		summary: decisionSummary(answer),
	});
}

function terminalActivity(state: string): { importance: "important"; severity: "success" | "warning" | "error"; summaryWord: string; type: string } | null {
	if (state === "merged" || state === "complete") return { importance: "important", severity: "success", summaryWord: "completed", type: "entry.completed" };
	if (state === "cancelled") return { importance: "important", severity: "warning", summaryWord: "cancelled", type: "entry.cancelled" };
	if (state === "aborted" || state === "dead") return { importance: "important", severity: "error", summaryWord: "dead", type: "entry.dead" };
	return null;
}

function emitTerminalEntry(entry: EntryRecord, state: string, details: Record<string, unknown> = {}): void {
	const terminal = terminalActivity(state);
	if (!terminal) return;
	const id = entryString(entry, "id") ?? "unknown";
	const outcome = state === terminal.summaryWord ? "" : ` (${state})`;
	emitCloseIssue(registryWorkflowContext(entry), state as CloseIssueOutcome, {
		details,
		severity: terminal.severity,
		summary: `${id} ${terminal.summaryWord}${outcome}`,
	});
}

function emitReconcileDrift(entry: EntryRecord, description: string, kind: string): void {
	emitRegistryActivity(entry, {
		details: { dedup_key: `${entryString(entry, "id") ?? "unknown"}:daemon.warning:reconcile:${kind}:${description}`, description, drift_kind: kind },
		importance: "important",
		severity: "warning",
		summary: `reconcile drift: ${description}`,
		type: "daemon.warning",
	});
}

function emitReconcileDrop(entry: EntryRecord): void {
	const id = entryString(entry, "id") ?? "unknown";
	emitRegistryActivity(entry, {
		details: { dedup_key: `${id}:entry.dead:reconcile-stale-pane`, reason: "reconcile-stale-pane" },
		importance: "important",
		severity: "warning",
		summary: `${id} dead (reconcile stale pane)`,
		type: "entry.dead",
	}, id);
}

function emitReconcileShellComplete(entry: EntryRecord): void {
	emitCloseIssue(registryWorkflowContext(entry), "complete", {
		details: { reason: "reconcile-pane-gone", teardown: "shell-pane-gone" },
		severity: "success",
	});
}

// Issue-mode metadata lives under `entry.domain.issue` (Linear) or
// `entry.domain.github_issue` (GitHub). If a caller
// passes one of those field names as a top-level set, redirect into the
// nested object so downstream readers (`pane-registry list --format json`,
// pi-flightdeck, merge planning) see the value where they look for it.
const ISSUE_DOMAIN_FIELDS = new Set([
	"pr_number",
	"worktree",
	"merge_commit",
	"scope_files_declared",
	"scope_files_actual",
	"orchestration_started",
]);

function setEntryField(id: string, field: string, value: string): void {
	if (!registryHasEntry(id)) die(`pane-registry: entry '${id}' not found in .entries`);
	const idJson = JSON.stringify(id);
	const entry = entryById(id);
	const kind = typeof entry?.kind === "string" ? entry.kind : "";
	if (ISSUE_DOMAIN_FIELDS.has(field) && kind === "issue") {
		const domain = isRecord(entry?.domain) ? entry.domain : {};
		const target = isRecord(domain.github_issue) ? "github_issue" : "issue";
		fdStateOrDie(["set", `.entries[${idJson}].domain.${target}.${field}`, value]);
		return;
	}
	fdStateOrDie(["set", `.entries[${idJson}].${field}`, value]);
}

function nestedRecord(obj: Record<string, unknown>, key: string): Record<string, unknown> {
	const value = obj[key];
	return isRecord(value) ? value : {};
}

function entryRows(): Record<string, unknown>[] {
	const entries = trackedEntries();
	return Object.entries(entries).map(([key, entry]) => {
		const adapter = nestedRecord(entry, "adapter");
		const domain = nestedRecord(entry, "domain");
		const issue = nestedRecord(domain, "issue");
		const githubIssue = nestedRecord(domain, "github_issue");
		const topLevelPr = typeof entry.pr_number === "number" && Number.isFinite(entry.pr_number) ? Math.trunc(entry.pr_number) : null;
		const topLevelWorktree = typeof entry.worktree === "string" && entry.worktree ? entry.worktree : null;
		const id = typeof entry.id === "string" ? entry.id : key;
		const kind = typeof entry.kind === "string" ? entry.kind : "issue";
		const githubNumber = typeof githubIssue.number === "number" && Number.isFinite(githubIssue.number) ? Math.trunc(githubIssue.number) : null;
		return {
			...entry,
			cc_port: adapter.cc_port ?? null,
			cc_session_uuid: adapter.cc_session_uuid ?? null,
			cc_transcript: adapter.cc_transcript ?? null,
			cc_url: adapter.cc_url ?? null,
			cx_thread_id: adapter.cx_thread_id ?? null,
			cx_ws: adapter.cx_ws ?? null,
			id,
			issue: kind === "issue" ? (issue.id ?? githubNumber ?? id) : null,
			oc_port: adapter.oc_port ?? null,
			oc_session_id: adapter.oc_session_id ?? null,
			oc_url: adapter.oc_url ?? null,
			orchestration_started: issue.orchestration_started ?? null,
			pi_bridge_pid: adapter.pi_bridge_pid ?? null,
			pi_bridge_socket: adapter.pi_bridge_socket ?? null,
			pi_session_id: adapter.pi_session_id ?? null,
			pr_number: issue.pr_number ?? githubIssue.pr_number ?? topLevelPr,
			scope_files_actual: issue.scope_files_actual ?? githubIssue.scope_files_actual ?? null,
			scope_files_declared: issue.scope_files_declared ?? null,
			worktree: issue.worktree ?? githubIssue.worktree ?? topLevelWorktree ?? entry.cwd ?? null,
		};
	});
}

// ----- list ----------------------------------------------------------------

function cmdList(args: string[]): void {
	let format = "json";
	for (let i = 0; i < args.length; i += 1) {
		if (args[i] === "--format") format = args[++i] ?? "json";
		else die(`Unknown flag: ${args[i]}`);
	}
	const rows = entryRows();
	const liveRows = (): Record<string, unknown>[] => {
		const live = tmuxLivePaneIds();
		return rows.filter((row) => typeof row.pane_id === "string" && live.has(row.pane_id));
	};
	switch (format) {
		case "json":
			process.stdout.write(`${JSON.stringify(rows)}\n`);
			break;
		case "inner-panes":
			process.stdout.write(`${rows.map((row) => row.pane_id ?? row.pane_target ?? "").filter(Boolean).join(",")}\n`);
			break;
		case "inner-panes-live":
			process.stdout.write(`${liveRows().map((row) => row.pane_id ?? "").filter(Boolean).join(",")}\n`);
			break;
		case "inner-harnesses":
			process.stdout.write(`${rows.map((row) => String(row.harness ?? "")).join(",")}\n`);
			break;
		case "inner-harnesses-live":
			process.stdout.write(`${liveRows().map((row) => String(row.harness ?? "")).join(",")}\n`);
			break;
		default:
			die(`Unknown format: ${format} (supported: json, inner-panes, inner-harnesses, inner-panes-live, inner-harnesses-live)`);
	}
}

// ----- get / set-state / set-substate / set / log-decision -----------------

function cmdGet(issue: string): void {
	if (!issue) die("Usage: pane-registry get <ENTRY_ID>");
	const out = fdStateOrDie(["get", `.entries["${issue}"] // empty`]);
	if (!out.trim() || out.trim() === "null") process.exit(1);
	process.stdout.write(out);
}

// Tracked entry states. Generic lifecycle plus issue-mode lifecycle states
// (merge-ready/merged/aborted) which still write here when issue-mode
// workflows tag a kind=issue entry.
const VALID_STATES = new Set(["waiting", "prompting", "submitting", "ready", "merge-ready", "merged", "aborted", "complete", "cancelled", "dead"]);

function cmdSetState(issue: string, state: string): void {
	if (!issue || !state) die("Usage: set-state <ENTRY_ID> <state>");
	if (!VALID_STATES.has(state)) die(`Unknown state: ${state}`);
	const before = entryByIdOrDie(issue);
	if (before.state === state) return;
	setEntryField(issue, "state", JSON.stringify(state));
	emitEntryStateChanged(before, before.state, state);
	emitIssueMergeState(before, state);
}

function cmdSetSubstate(issue: string, sub: string): void {
	if (!issue || !sub) die("Usage: set-substate <ENTRY_ID> <substate>");
	const before = entryByIdOrDie(issue);
	if (before.substate === sub) return;
	setEntryField(issue, "substate", JSON.stringify(sub));
	emitEntrySubstateChanged(before, sub);
}

function cmdSetField(issue: string, field: string, value: string): void {
	if (!issue || !field || !value) die("Usage: set <ENTRY_ID> <field> <json-value>");
	const before = field === "state" ? entryByIdOrDie(issue) : null;
	setEntryField(issue, field, value);
	if (field === "state" && before) {
		const after = entryById(issue);
		const nextState = after?.state;
		if (typeof nextState === "string" && before.state !== nextState) emitEntryStateChanged(before, before.state, nextState);
	}
}

function cmdLogDecision(issue: string, tag: string, answer: string): void {
	if (!issue || !tag || !answer) die("Usage: log-decision <ENTRY_ID> <prompt-tag> <answer>");
	const before = entryByIdOrDie(issue);
	const decisions = Array.isArray(before.decisions_log) ? before.decisions_log : [];
	const sequence = decisions.length + 1;
	const entry = { answer, prompt_tag: tag, ts: nowIso() };
	fdStateOrDie(["append", `.entries["${issue}"].decisions_log`, JSON.stringify(entry)]);
	emitDecisionRecorded(before, tag, answer, sequence);
}

// ----- remove --------------------------------------------------------------

function cmdRemove(issue: string): void {
	if (!issue) die("Usage: remove <ISSUE>");
	// OC: kill server (pgid), release port, drop spawn file
	const ocSpawn = ocSpawnFile(issue);
	const ocRec = readJsonIfExists<Record<string, unknown>>(ocSpawn);
	const serverPid = Number(ocRec?.server_pid);
	if (Number.isFinite(serverPid) && serverPid > 0 && pidAlive(serverPid)) {
		try { process.kill(-serverPid, "SIGTERM"); } catch { try { process.kill(serverPid, "SIGTERM"); } catch { /* ignore */ } }
		for (let i = 0; i < 5; i += 1) {
			if (!pidAlive(serverPid)) break;
			spawnSync("sleep", ["0.2"]);
		}
		if (pidAlive(serverPid)) {
			try { process.kill(-serverPid, "SIGKILL"); } catch { try { process.kill(serverPid, "SIGKILL"); } catch { /* ignore */ } }
		}
	}
	const ocPort = readField(issue, "oc_port");
	if (ocPort) { try { ocReleasePort(Number(ocPort)); } catch { /* ignore */ } }
	safeUnlink(ocSpawn);
	// CC: release port + drop spawn/mcp dir
	const ccPort = readField(issue, "cc_port");
	if (ccPort) { try { ccReleasePort(Number(ccPort)); } catch { /* ignore */ } }
	safeUnlink(ccSpawnFile(issue));
	try { rmSync(ccMcpDir(issue), { force: true, recursive: true }); } catch { /* ignore */ }
	// PI: drop spawn (server is user's tmux pane, not ours)
	safeUnlink(piSpawnFile(issue));
	// CX: drop spawn (server is per-session; terminate.md handles it)
	safeUnlink(cxSpawnFile(issue));
	fdStateOrDie(["set", ".entries", `(.entries | del(.["${issue}"]))`]);
}

function readField(issue: string, field: string): string {
	const id = lookupId(issue);
	const idJson = JSON.stringify(id);
	const r = fdState(["get", `(.entries[${idJson}].adapter.${field} // .entries[${idJson}].${field} // empty)`]);
	return r.stdout.replace(/\n$/, "").replace(/^"|"$/g, "");
}

function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

function safeUnlink(p: string): void {
	try { unlinkSync(p); } catch { /* ignore */ }
}

// ----- adapter-args (oc / cc / pi / cx) ------------------------------------

function cmdOcAttachArgs(issue: string): void {
	if (!issue) die("Usage: oc-attach-args <ISSUE>");
	issue = lookupIdOrPane(issue, true);
	const url = readField(issue, "oc_url");
	const sid = readField(issue, "oc_session_id");
	if (url && sid && url !== "null" && sid !== "null") {
		if (ocAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --session ${sid}\n`);
	}
}

function cmdCcChannelArgs(issue: string): void {
	if (!issue) die("Usage: cc-channel-args <ISSUE>");
	issue = lookupIdOrPane(issue, true);
	const url = readField(issue, "cc_url");
	const transcript = readField(issue, "cc_transcript");
	if (url && transcript && url !== "null" && transcript !== "null") {
		if (ccAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --transcript ${transcript}\n`);
	}
}

function cmdPiBridgeArgs(issue: string): void {
	if (!issue) die("Usage: pi-bridge-args <ISSUE>");
	issue = lookupIdOrPane(issue, true);
	const pid = readField(issue, "pi_bridge_pid");
	const socket = readField(issue, "pi_bridge_socket");
	if (pid && socket && pid !== "null" && socket !== "null") {
		if (piBridgeIsFresh(Number(pid), socket)) process.stdout.write(`--pid ${pid} --socket ${socket}\n`);
	}
}

function cmdCxBridgeArgs(issue: string): void {
	if (!issue) die("Usage: cx-bridge-args <ISSUE>");
	issue = lookupIdOrPane(issue, true);
	const url = readField(issue, "cx_ws");
	const thread = readField(issue, "cx_thread_id");
	if (url && thread && url !== "null" && thread !== "null") {
		if (cxAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --thread ${thread}\n`);
	}
}

// ----- find-by-pane --------------------------------------------------------

function cmdFindByPane(target: string): void {
	if (!target) die("Usage: find-by-pane <pane-target-or-pane-id>");
	const hits = Object.entries(trackedEntries()).filter(([, entry]) => entry.pane_target === target || entry.pane_id === target);
	if (!hits.length) process.exit(1);
	for (const [key, entry] of hits) {
		const paneId = typeof entry.pane_id === "string" ? entry.pane_id : "";
		const paneTarget = typeof entry.pane_target === "string" ? entry.pane_target : "";
		if (!paneMatchIsLive(paneId, paneTarget)) continue;
		process.stdout.write(`${JSON.stringify({ id: typeof entry.id === "string" ? entry.id : key, kind: typeof entry.kind === "string" ? entry.kind : "issue" })}\n`);
		return;
	}
	const [, entry] = hits[0]!;
	warnStalePaneMatch(
		typeof entry.pane_id === "string" ? entry.pane_id : "",
		typeof entry.pane_target === "string" ? entry.pane_target : "",
	);
	process.exit(1);
}

// ----- reconcile / remove-merged -------------------------------------------

interface IssueRec extends EntryRecord {
	state?: string;
	pane_id?: string | null;
	pane_target?: string | null;
	window?: string | null;
}

function readEntriesJson(): Record<string, IssueRec> {
	const rows = entryRows();
	const out: Record<string, IssueRec> = {};
	for (const row of rows) {
		const id = typeof row.id === "string" ? row.id : "";
		if (!id) continue;
		out[id] = row as IssueRec;
	}
	return out;
}

// vstack#85 F1: see tmuxLivePaneIdsResult above. cmdReconcile and
// cmdRemoveMerged must bail on probe failure instead of mass-
// transitioning every entry as "pane gone".
type LivePanesAndWindowsResult =
	| { ok: true; panes: Set<string>; windows: Set<string> }
	| { ok: false; error: string };

function livePanesAndWindowsResult(): LivePanesAndWindowsResult {
	const session = tmuxCurrentSession();
	const pp = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	if (pp.status !== 0) {
		const stderr = (pp.stderr ?? "").trim();
		return { ok: false, error: `tmux list-panes -a failed (status=${pp.status})${stderr ? `: ${stderr}` : ""}` };
	}
	const ww = spawnSync("tmux", ["list-windows", "-t", session, "-F", "#{window_name}"], { encoding: "utf8" });
	if (ww.status !== 0) {
		const stderr = (ww.stderr ?? "").trim();
		return { ok: false, error: `tmux list-windows -t ${session} failed (status=${ww.status})${stderr ? `: ${stderr}` : ""}` };
	}
	const panes = new Set<string>();
	const windows = new Set<string>();
	for (const line of (pp.stdout ?? "").split("\n")) if (line) panes.add(line);
	for (const line of (ww.stdout ?? "").split("\n")) if (line) windows.add(line);
	return { ok: true, panes, windows };
}

function cmdRemoveMerged(): void {
	const probe = livePanesAndWindowsResult();
	if (!probe.ok) {
		// vstack#85 F1: transient tmux probe failure must not mass-drop
		// terminal-state entries (a hiccup would otherwise wipe every
		// pane-gone row from the registry on a single tick).
		process.stderr.write(`remove-merged: tmux probe failed; skipping tick (${probe.error})\n`);
		return;
	}
	const live = { panes: probe.panes, windows: probe.windows };
	const entries = readEntriesJson();
	const dropped: string[] = [];
	for (const [issue, rec] of Object.entries(entries)) {
		const state = String(rec.state ?? "");
		if (state !== "merged" && state !== "aborted" && state !== "dead" && state !== "complete" && state !== "cancelled") continue;
		const paneId = String(rec.pane_id ?? "");
		const win = String(rec.window ?? "");
		const alive = paneId ? live.panes.has(paneId) : !win || live.windows.has(win);
		if (!alive) {
			fdStateOrDie(["set", ".entries", `(.entries | del(.["${issue}"]))`]);
			dropped.push(`${issue}:${state}`);
		}
	}
	if (dropped.length > 0) {
		process.stdout.write(`remove-merged: dropped ${dropped.length} entr${dropped.length === 1 ? "y" : "ies"} (${dropped.join(",")})\n`);
	}
}

function cmdReconcile(): void {
	const probe = livePanesAndWindowsResult();
	if (!probe.ok) {
		// vstack#85 F1: transient tmux probe failure (SIGSTOP, SIGPIPE,
		// EAGAIN, mid-session restart, momentary socket loss) must not
		// be treated as "every pane is gone". A silent empty-set would
		// mass-transition adhoc-shell rows to `complete` AND drop every
		// other entry as `entry.dead` in a single tick. Bail early so
		// the next tick can reconcile against a healthy probe.
		process.stderr.write(`reconcile: tmux probe failed; skipping tick (${probe.error})\n`);
		return;
	}
	const live = { panes: probe.panes, windows: probe.windows };
	const entries = readEntriesJson();
	const dropped: string[] = [];
	const completed: string[] = [];
	const backfilled: string[] = [];
	const drift: string[] = [];
	for (const [issue, rec] of Object.entries(entries)) {
		let paneId = String(rec.pane_id ?? "");
		const paneTarget = String(rec.pane_target ?? "");
		const win = String(rec.window ?? "");
		const worktree = String((rec as { worktree?: string }).worktree ?? "");
		let driftedThis = false;
		if (!paneId && paneTarget) {
			if (tmuxPaneExists(paneTarget)) {
				// #16 backfill guard. tmux reassigns destroyed window indices,
				// so a stale pane_target may now point at an unrelated window
				// (daemon, editor, ...). Window-name alone is mutable and can
				// collide; require AND of:
				//   (a) #{window_name} == registered window
				//   (b) #{pane_current_path} prefix-matches registered worktree
				// If either has hard evidence of mismatch → emit drift and
				// LEAVE the entry untouched (no adopt, no drop). Strong
				// invariant per reviewer BLOCK #3.
				const currentWindow = tmuxField(paneTarget, "#{window_name}");
				const currentPath = tmuxField(paneTarget, "#{pane_current_path}");
				const windowMismatch = !!(win && currentWindow && currentWindow !== win);
				const pathMismatch = !!(
					worktree &&
					currentPath &&
					currentPath !== worktree &&
					!currentPath.startsWith(`${worktree}/`)
				);
				if (windowMismatch || pathMismatch) {
					const description = `${issue} (window:'${win}'→'${currentWindow}' worktree:'${worktree}'→'${currentPath}')`;
					drift.push(description);
					emitReconcileDrift(rec, description, windowMismatch ? "window-mismatch" : "worktree-mismatch");
					driftedThis = true;
				} else {
					const resolved = tmuxField(paneTarget, "#{pane_id}");
					if (resolved) {
						fdStateOrDie(["set", `.entries["${issue}"].pane_id`, JSON.stringify(resolved)]);
						paneId = resolved;
						backfilled.push(issue);
					}
				}
			}
		}
		if (driftedThis) continue;
		const alive = paneId ? live.panes.has(paneId) : !win || live.windows.has(win);
		if (!alive) {
			const droppedEntry = rec;
			const stateStr = String(rec.state ?? "");
			// vstack#85: adhoc shell entries have no idle subscriber, so
			// pane-gone IS their terminal signal. Transition state to
			// `complete` and emit `entry.completed` instead of dropping +
			// `entry.dead`. Non-shell-adhoc entries keep the legacy drop.
			const terminalEmittedAt = typeof rec.terminal_emitted_at === "string"
				? rec.terminal_emitted_at
				: null;
			const wake = decideShellAdhocWake({
				kind: String(rec.kind ?? ""),
				harness: String(rec.harness ?? ""),
				state: stateStr,
				paneAlive: false,
				terminalEmittedAt,
			});
			if (wake.transition) {
				const idJson = JSON.stringify(issue);
				fdStateOrDie(["set", `.entries[${idJson}].state`, JSON.stringify(wake.nextState)]);
				const emittedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
				fdStateOrDie([
					"set",
					`.entries[${idJson}].terminal_emitted_at`,
					JSON.stringify(emittedAt),
				]);
				emitReconcileShellComplete(droppedEntry);
				completed.push(issue);
				continue;
			}
			fdStateOrDie(["set", ".entries", `(.entries | del(.["${issue}"]))`]);
			// Already-terminal entries (e.g. an adhoc-shell row that was
			// transitioned to `complete` on a prior reconcile tick, then
			// observed pane-gone again on the next sweep) drop silently
			// — the terminal-event was emitted at the original
			// transition and re-emitting `entry.dead` would lie about the
			// outcome.
			if (!TERMINAL_STATES.has(stateStr.toLowerCase())) emitReconcileDrop(droppedEntry);
			dropped.push(issue);
		}
	}
	if (completed.length > 0) {
		process.stdout.write(`reconciled: completed ${completed.length} adhoc shell entr${completed.length === 1 ? "y" : "ies"} (${completed.join(",")})\n`);
	}
	if (dropped.length > 0) {
		process.stdout.write(`reconciled: dropped ${dropped.length} stale entr${dropped.length === 1 ? "y" : "ies"} (${dropped.join(",")})\n`);
	}
	if (backfilled.length > 0) {
		process.stdout.write(`reconciled: backfilled pane_id for ${backfilled.length} entr${backfilled.length === 1 ? "y" : "ies"} (${backfilled.join(",")})\n`);
	}
	if (drift.length > 0) {
		process.stderr.write(
			`reconciled: drift detected for ${drift.length} entr${drift.length === 1 ? "y" : "ies"}, left untouched (${drift.join("|")})\n`,
		);
	}
}

// ----- teardown-window -----------------------------------------------------
//
// pane-registry teardown-window
// (see tests/parity/pane-registry.test.ts).
//
// Exit codes:
//   0 - window/pane killed, or already closed (terminal + dead pane)
//   1 - issue not registered (caller may treat as idempotent no-op)
//   2 - bad arguments
//   3 - registry drift: pane_id gone but state not terminal
//   4 - policy: pane_id alive but state non-terminal (rerun with --force)
//   5 - tmux kill failed: pane still alive after kill attempt
//   6 - registry read failure

// Terminal states across both adhoc and issue-mode lifecycles. Issue mode
// keeps the {merged, aborted} states for PR-flow semantics; the generic
// lifecycle uses {complete, cancelled}; both share {dead} for force-kill.
const TERMINAL_STATES = new Set(["merged", "aborted", "dead", "complete", "cancelled"]);

function cmdTeardownWindow(args: string[]): void {
	let issue = "";
	let force = false;
	for (const a of args) {
		if (a === "--force") force = true;
		else if (a === "--") continue;
		else if (a.startsWith("-")) die(`teardown-window: unknown flag: ${a}`);
		else if (!issue) issue = a;
		else die(`teardown-window: extra argument: ${a}`);
	}
	if (!issue) die("Usage: teardown-window <ISSUE> [--force]");
	// Read registry through flightdeck-state. The script returns:
	//   exit 0 + empty stdout — state file present, lookup miss (idempotent)
	//   exit 1                — state file does not exist (registry never initialized; idempotent)
	//   exit >= 2             — usage error or genuine read failure
	// Treat 0+empty and 1 as "not found" (exit 1); only exit >= 2 escalates
	// to exit 6 (registry read failure) per BLOCK #2.
	const r = fdState(["get", `.entries["${issue}"] // empty`]);
	const status = r.status ?? 0;
	if (status >= 2) {
		process.stderr.write(
			`teardown-window: registry read failed (flightdeck-state exit=${status}): ${r.stderr}`,
		);
		if (!r.stderr.endsWith("\n")) process.stderr.write("\n");
		process.exit(6);
	}
	const raw = (r.stdout ?? "").trim();
	if (status === 1 || !raw || raw === "null") {
		process.stderr.write(`teardown-window: issue '${issue}' not found in registry\n`);
		process.exit(1);
	}
	let rec: IssueRec;
	try { rec = JSON.parse(raw) as IssueRec; }
	catch {
		process.stderr.write(`teardown-window: malformed registry entry for '${issue}'\n`);
		process.exit(6);
	}
	const state = String(rec.state ?? "");
	const paneId = String(rec.pane_id ?? "");
	const windowName = String(rec.window ?? "");
	// vstack#85 F1: probe panes AND windows in one shot so the F2 empty-
	// paneId window fallback shares the same atomic snapshot. Probe
	// failure aborts before any destructive branch.
	const probe = livePanesAndWindowsResult();
	if (!probe.ok) {
		process.stderr.write(
			`teardown-window: tmux probe failed; refusing to act (state of pane_id '${paneId || "<none>"}' / window '${windowName || "<none>"}' unknown): ${probe.error}\n`,
		);
		process.exit(5);
	}
	const paneAlive = paneId ? probe.panes.has(paneId) : false;
	if (paneAlive) {
		if (!TERMINAL_STATES.has(state) && !force) {
			process.stderr.write(
				`teardown-window: policy refusal — pane_id '${paneId}' is alive but state is '${state}' (not merged|aborted|dead|complete|cancelled); set a terminal state first or rerun with --force\n`,
			);
			process.exit(4);
		}
		const windowId = tmuxField(paneId, "#{window_id}");
		const paneCount = windowId ? tmuxPaneCountInWindow(windowId) : 0;
		let kind: string;
		let killResult;
		if (windowId && paneCount === 1) {
			killResult = spawnSync("tmux", ["kill-window", "-t", windowId], { encoding: "utf8" });
			kind = `window ${windowId}`;
		} else {
			killResult = spawnSync("tmux", ["kill-pane", "-t", paneId], { encoding: "utf8" });
			kind = `pane ${paneId}`;
		}
		// Post-kill liveness check is authoritative — not the exit code
		// (BLOCK #1). tmux can return non-zero for benign reasons such as
		// the pane vanishing between the alive-check and the kill.
		const stillProbe = tmuxLivePaneIdsResult();
		if (!stillProbe.ok) {
			process.stderr.write(
				`teardown-window: post-kill tmux probe failed (status of pane_id '${paneId}' unknown after kill of ${kind}): ${stillProbe.error}\n`,
			);
			process.exit(5);
		}
		if (stillProbe.panes.has(paneId)) {
			process.stderr.write(
				`teardown-window: kill of ${kind} failed (status=${killResult.status}, pane_id=${paneId} still alive): ${killResult.stderr ?? ""}`,
			);
			if (!(killResult.stderr ?? "").endsWith("\n")) process.stderr.write("\n");
			process.exit(5);
		}
		emitTerminalEntry(rec, state, { force, pane_id: paneId, teardown: "killed" });
		process.stdout.write(
			`teardown-window: killed ${kind} (pane_id=${paneId}, window=${windowName}, force=${force ? 1 : 0})\n`,
		);
		return;
	}
	// vstack#85 F2: when paneId is empty, fall back to the recorded
	// window name. If tmux still lists the window, the pane state is
	// unverifiable — refuse even with --force so the operator can
	// reconcile/backfill instead of dropping a row whose pane may be
	// alive. Empty paneId + empty/gone window is the operator's call
	// (no way to verify; --force proceeds, non-force still hits drift).
	if (!paneId && windowName && probe.windows.has(windowName)) {
		process.stderr.write(
			`teardown-window: refusing to drop '${issue}' — pane_id is empty but recorded window '${windowName}' is still alive in tmux; cannot verify pane state. Run \`pane-registry reconcile\` to backfill pane_id, then retry${force ? " (--force refused for safety)" : ""}\n`,
		);
		process.exit(3);
	}
	if (TERMINAL_STATES.has(state)) {
		emitTerminalEntry(rec, state, { pane_id: paneId || null, teardown: "already-closed" });
		process.stdout.write(`teardown-window: window already closed (pane_id=${paneId || "<none>"} gone, state=${state})\n`);
		return;
	}
	if (force) {
		// vstack#85: --force is the operator explicitly saying "I know this
		// entry is stuck and the pane is verifiably gone — drop it". The
		// non-force path keeps the #16 drift refusal intact.
		const outcome: "cancelled" | "dead" = state === "waiting" || state === "" ? "cancelled" : "dead";
		fdStateOrDie(["set", ".entries", `(.entries | del(.["${issue}"]))`]);
		emitTerminalEntry(rec, outcome, {
			force: true,
			pane_id: paneId || null,
			prior_state: state || null,
			reason: "force-gone-pane",
			teardown: "force-gone-pane",
		});
		process.stdout.write(`teardown-window: removed stale entry '${issue}' (pane_id=${paneId || "<none>"} gone, prior_state=${state || "<none>"}, force=1, outcome=${outcome})\n`);
		return;
	}
	process.stderr.write(
		`teardown-window: registry drift — pane_id '${paneId || "<none>"}' is gone but state is '${state}' (not merged|aborted|dead|complete|cancelled); refusing to derive kill target from pane_target (#16); rerun with --force to drop the stale entry\n`,
	);
	process.exit(3);
}

// ----- main ----------------------------------------------------------------

const argv = process.argv.slice(2);
const action = argv.shift();
if (!action) die("Usage: pane-registry <action> [args]");
switch (action) {
	case "init":          cmdInit(argv.shift() ?? "", argv); break;
	case "init-entry":    cmdInitEntry(argv.shift() ?? "", argv); break;
	case "list":          cmdList(argv); break;
	case "get":           cmdGet(argv[0] ?? ""); break;
	case "set-state":     cmdSetState(argv[0] ?? "", argv[1] ?? ""); break;
	case "set-substate":  cmdSetSubstate(argv[0] ?? "", argv[1] ?? ""); break;
	case "set":           cmdSetField(argv[0] ?? "", argv[1] ?? "", argv[2] ?? ""); break;
	case "log-decision":  cmdLogDecision(argv[0] ?? "", argv[1] ?? "", argv[2] ?? ""); break;
	case "remove":        cmdRemove(argv[0] ?? ""); break;
	case "remove-merged": cmdRemoveMerged(); break;
	case "reconcile":     cmdReconcile(); break;
	case "oc-attach-args":  cmdOcAttachArgs(argv[0] ?? ""); break;
	case "cc-channel-args": cmdCcChannelArgs(argv[0] ?? ""); break;
	case "pi-bridge-args":  cmdPiBridgeArgs(argv[0] ?? ""); break;
	case "cx-bridge-args":  cmdCxBridgeArgs(argv[0] ?? ""); break;
	case "find-by-pane":    cmdFindByPane(argv[0] ?? ""); break;
	case "teardown-window":
	case "teardown-entry":  cmdTeardownWindow(argv); break;
	default:
		die(`Unknown action: ${action}\nActions: init-entry | init | list | get | set-state | set-substate | set | log-decision | remove | remove-merged | reconcile | teardown-window | teardown-entry | oc-attach-args | cc-channel-args | pi-bridge-args | cx-bridge-args | find-by-pane`);
}
