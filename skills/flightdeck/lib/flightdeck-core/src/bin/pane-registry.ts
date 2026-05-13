#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/pane-registry.
// Wraps flightdeck-state for the .issues map; handles 5-harness spawn
// discovery, freshness-gated adapter-args resolution, and live-pane
// reconciliation against tmux.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, unlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ocAdapterIsFresh, ocReleasePort, ocSpawnFile } from "../paths/oc.ts";
import { ccAdapterIsFresh, ccMcpDir, ccReleasePort, ccSpawnFile } from "../paths/cc.ts";
import { piBridgeIsFresh, piSpawnFile } from "../paths/pi.ts";
import { cxAdapterIsFresh, cxSpawnFile } from "../paths/codex.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
// The bash trampoline lives at scripts/<name>; the .bash sibling is the
// legacy bash flightdeck-state. We invoke the trampoline so the same
// FLIGHTDECK_USE_TS_* gates apply.
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

function tmuxLivePaneIds(): Set<string> {
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	const panes = new Set<string>();
	if (r.status !== 0) return panes;
	for (const line of (r.stdout ?? "").split("\n")) {
		if (line) panes.add(line);
	}
	return panes;
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

interface InitFields {
	cc_port: string;
	cc_session_uuid: string;
	cc_transcript: string;
	cc_url: string;
	cwd: string;
	cx_thread_id: string;
	cx_ws: string;
	discovery_error: string;
	harness: string;
	kind: string;
	launch_cmd: string;
	launch_effort: string;
	launch_model: string;
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
	window: string;
	window_id: string;
	window_index: string;
	worktree: string;
}

function defaultInitFields(entryId: string, kind = "adhoc"): InitFields {
	return {
		cc_port: "", cc_session_uuid: "", cc_transcript: "", cc_url: "",
		cwd: "",
		cx_thread_id: "", cx_ws: "",
		discovery_error: "",
		harness: "",
		kind,
		launch_cmd: "", launch_effort: "", launch_model: "",
		oc_port: "", oc_session_id: "", oc_url: "",
		pane_id: "", pane_index: tmuxBasePaneIndex() || "0", pane_target: "",
		pi_bridge_pid: "", pi_bridge_socket: "", pi_session_id: "",
		pr: "",
		title: entryId,
		window: "", window_id: "", window_index: "",
		worktree: "",
	};
}

const INIT_FLAG_MAP: Record<string, keyof InitFields> = {
	"--cc-port": "cc_port",
	"--cc-session-uuid": "cc_session_uuid",
	"--cc-transcript": "cc_transcript",
	"--cc-url": "cc_url",
	"--cwd": "cwd",
	"--cx-thread-id": "cx_thread_id",
	"--cx-ws": "cx_ws",
	"--discovery-error": "discovery_error",
	"--harness": "harness",
	"--kind": "kind",
	"--launch-cmd": "launch_cmd",
	"--launch-effort": "launch_effort",
	"--launch-model": "launch_model",
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

function hydrateSpawnMetadata(entryId: string, fields: InitFields): void {
	const harness = fields.harness;
	if (harness === "opencode" && !fields.oc_url) {
		const rec = readJsonIfExists<Record<string, unknown>>(ocSpawnFile(entryId));
		if (rec) {
			fields.oc_url = String(rec.url ?? "");
			fields.oc_session_id = String(rec.session_id ?? "");
			fields.oc_port = String(rec.port ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			if (!fields.launch_model) fields.launch_model = String(launch?.model ?? "");
			if (!fields.launch_effort) fields.launch_effort = String(launch?.effort ?? "");
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
			if (!fields.launch_model) fields.launch_model = String(launch?.model ?? "");
			if (!fields.launch_effort) fields.launch_effort = String(launch?.effort ?? "");
		}
	}
	if (harness === "pi" && !fields.pi_bridge_pid) {
		const rec = readJsonIfExists<Record<string, unknown>>(piSpawnFile(entryId));
		if (rec) {
			fields.pi_bridge_pid = String(rec.pid ?? "");
			fields.pi_bridge_socket = String(rec.socket ?? "");
			fields.pi_session_id = String(rec.session_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			if (!fields.launch_model) fields.launch_model = String(launch?.model ?? "");
			if (!fields.launch_effort) fields.launch_effort = String(launch?.effort ?? "");
		}
	}
	if (harness === "codex" && !fields.cx_ws) {
		const rec = readJsonIfExists<Record<string, unknown>>(cxSpawnFile(entryId));
		if (rec) {
			fields.cx_ws = String(rec.url ?? "");
			fields.cx_thread_id = String(rec.thread_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			if (!fields.launch_model) fields.launch_model = String(launch?.model ?? "");
			if (!fields.launch_effort) fields.launch_effort = String(launch?.effort ?? "");
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
	if (mode === "issue" && !fields.worktree) die("init requires --window, --harness, --worktree");
	if (fields.kind === "issue" && !fields.worktree) fields.worktree = fields.cwd;
	if (!fields.cwd) fields.cwd = fields.worktree;
	if (!fields.window || !fields.harness || !fields.cwd) die(mode === "issue" ? "init requires --window, --harness, --worktree" : "init-entry requires --title, --kind, --cwd, --window, --harness");

	hydrateSpawnMetadata(entryId, fields);
	fdStateOrDie(["init"]);
	const session = tmuxCurrentSession();
	const paneTarget = fields.pane_target || `${session}:${fields.window}.${fields.pane_index}`;
	let paneId = fields.pane_id;
	if (!paneId && tmuxPaneExists(paneTarget)) paneId = tmuxField(paneTarget, "#{pane_id}");

	const launch = (fields.launch_model || fields.launch_effort || fields.launch_cmd)
		? { cmd: fields.launch_cmd || null, effort: fields.launch_effort || null, model: fields.launch_model || null }
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
	const issueDomain = fields.kind === "issue" ? {
		id: entryId,
		orchestration_started: false,
		pr_number: numOrNull(fields.pr),
		scope_files_actual: null,
		scope_files_declared: null,
		worktree: strOrNull(fields.worktree),
	} : undefined;
	const ts = nowIso();
	const entry = {
		adapter,
		cwd: fields.cwd,
		decisions_log: [],
		discovery_error: strOrNull(fields.discovery_error),
		domain: issueDomain ? { issue: issueDomain } : null,
		harness: fields.harness,
		id: entryId,
		kind: fields.kind,
		last_capture_hash: null,
		last_polled_at: ts,
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

	fdStateOrDie(["write-entry", entryId, JSON.stringify(entry)]);
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
		const id = typeof entry.id === "string" ? entry.id : key;
		const kind = typeof entry.kind === "string" ? entry.kind : "issue";
		return {
			...entry,
			cc_port: adapter.cc_port ?? null,
			cc_session_uuid: adapter.cc_session_uuid ?? null,
			cc_transcript: adapter.cc_transcript ?? null,
			cc_url: adapter.cc_url ?? null,
			cx_thread_id: adapter.cx_thread_id ?? null,
			cx_ws: adapter.cx_ws ?? null,
			id,
			issue: kind === "issue" ? (issue.id ?? id) : null,
			oc_port: adapter.oc_port ?? null,
			oc_session_id: adapter.oc_session_id ?? null,
			oc_url: adapter.oc_url ?? null,
			orchestration_started: issue.orchestration_started ?? null,
			pi_bridge_pid: adapter.pi_bridge_pid ?? null,
			pi_bridge_socket: adapter.pi_bridge_socket ?? null,
			pi_session_id: adapter.pi_session_id ?? null,
			pr_number: issue.pr_number ?? null,
			scope_files_actual: issue.scope_files_actual ?? null,
			scope_files_declared: issue.scope_files_declared ?? null,
			worktree: issue.worktree ?? entry.cwd ?? null,
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
	switch (format) {
		case "json":
			process.stdout.write(`${JSON.stringify(entryRows())}\n`);
			break;
		case "inner-panes":
			process.stdout.write(`${entryRows().map((row) => row.pane_id ?? row.pane_target ?? "").filter(Boolean).join(",")}\n`);
			break;
		case "inner-harnesses":
			process.stdout.write(`${entryRows().map((row) => String(row.harness ?? "")).join(",")}\n`);
			break;
		default:
			die(`Unknown format: ${format} (supported: json, inner-panes, inner-harnesses)`);
	}
}

// ----- get / set-state / set-substate / set / log-decision -----------------

function cmdGet(issue: string): void {
	if (!issue) die("Usage: pane-registry get <ISSUE>");
	const out = fdStateOrDie(["get", `.issues["${issue}"] // empty`]);
	if (!out.trim() || out.trim() === "null") process.exit(1);
	process.stdout.write(out);
}

const VALID_STATES = new Set(["waiting", "prompting", "submitting", "merge-ready", "merged", "aborted", "dead"]);

function cmdSetState(issue: string, state: string): void {
	if (!issue || !state) die("Usage: set-state <ISSUE> <state>");
	if (!VALID_STATES.has(state)) die(`Unknown state: ${state}`);
	fdStateOrDie(["set", `.issues["${issue}"].state`, JSON.stringify(state)]);
}

function cmdSetSubstate(issue: string, sub: string): void {
	if (!issue || !sub) die("Usage: set-substate <ISSUE> <substate>");
	fdStateOrDie(["set", `.issues["${issue}"].substate`, JSON.stringify(sub)]);
}

function cmdSetField(issue: string, field: string, value: string): void {
	if (!issue || !field || !value) die("Usage: set <ISSUE> <field> <json-value>");
	fdStateOrDie(["set", `.issues["${issue}"].${field}`, value]);
}

function cmdLogDecision(issue: string, tag: string, answer: string): void {
	if (!issue || !tag || !answer) die("Usage: log-decision <ISSUE> <prompt-tag> <answer>");
	const entry = { answer, prompt_tag: tag, ts: nowIso() };
	fdStateOrDie(["append", `.issues["${issue}"].decisions_log`, JSON.stringify(entry)]);
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
	fdStateOrDie(["set", ".issues", `(.issues | del(.["${issue}"]))`]);
}

function readField(issue: string, field: string): string {
	const id = lookupId(issue);
	const idJson = JSON.stringify(id);
	const r = fdState(["get", `(.issues[${idJson}].${field} // .entries[${idJson}].adapter.${field} // .entries[${idJson}].${field} // empty)`]);
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
	issue = lookupId(issue);
	const url = readField(issue, "oc_url");
	const sid = readField(issue, "oc_session_id");
	if (url && sid && url !== "null" && sid !== "null") {
		if (ocAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --session ${sid}\n`);
	}
}

function cmdCcChannelArgs(issue: string): void {
	if (!issue) die("Usage: cc-channel-args <ISSUE>");
	issue = lookupId(issue);
	const url = readField(issue, "cc_url");
	const transcript = readField(issue, "cc_transcript");
	if (url && transcript && url !== "null" && transcript !== "null") {
		if (ccAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --transcript ${transcript}\n`);
	}
}

function cmdPiBridgeArgs(issue: string): void {
	if (!issue) die("Usage: pi-bridge-args <ISSUE>");
	issue = lookupId(issue);
	const pid = readField(issue, "pi_bridge_pid");
	const socket = readField(issue, "pi_bridge_socket");
	if (pid && socket && pid !== "null" && socket !== "null") {
		if (piBridgeIsFresh(Number(pid), socket)) process.stdout.write(`--pid ${pid} --socket ${socket}\n`);
	}
}

function cmdCxBridgeArgs(issue: string): void {
	if (!issue) die("Usage: cx-bridge-args <ISSUE>");
	issue = lookupId(issue);
	const url = readField(issue, "cx_ws");
	const thread = readField(issue, "cx_thread_id");
	if (url && thread && url !== "null" && thread !== "null") {
		if (cxAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --thread ${thread}\n`);
	}
}

// ----- find-by-pane --------------------------------------------------------

function cmdFindByPane(target: string): void {
	if (!target) die("Usage: find-by-pane <pane-target-or-pane-id>");
	const hit = Object.entries(trackedEntries()).find(([, entry]) => entry.pane_target === target || entry.pane_id === target);
	if (!hit) process.exit(1);
	const [key, entry] = hit;
	const paneId = typeof entry.pane_id === "string" ? entry.pane_id : "";
	const paneTarget = typeof entry.pane_target === "string" ? entry.pane_target : "";
	if (!paneMatchIsLive(paneId, paneTarget)) {
		warnStalePaneMatch(paneId, paneTarget);
		process.exit(1);
	}
	process.stdout.write(`${JSON.stringify({ id: typeof entry.id === "string" ? entry.id : key, kind: typeof entry.kind === "string" ? entry.kind : "issue" })}\n`);
}

// ----- reconcile / remove-merged -------------------------------------------

interface IssueRec {
	state?: string;
	pane_id?: string | null;
	pane_target?: string | null;
	window?: string | null;
}

function readIssuesJson(): Record<string, IssueRec> {
	const out = fdState(["get", ".issues // {}"]);
	try { return JSON.parse(out.stdout || "{}") as Record<string, IssueRec>; }
	catch { return {}; }
}

function livePanesAndWindows(): { panes: Set<string>; windows: Set<string> } {
	const panes = new Set<string>();
	const windows = new Set<string>();
	const session = tmuxCurrentSession();
	const pp = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	if (pp.status === 0) for (const line of (pp.stdout ?? "").split("\n")) { if (line) panes.add(line); }
	const ww = spawnSync("tmux", ["list-windows", "-t", session, "-F", "#{window_name}"], { encoding: "utf8" });
	if (ww.status === 0) for (const line of (ww.stdout ?? "").split("\n")) { if (line) windows.add(line); }
	return { panes, windows };
}

function cmdRemoveMerged(): void {
	const live = livePanesAndWindows();
	const issues = readIssuesJson();
	const dropped: string[] = [];
	for (const [issue, rec] of Object.entries(issues)) {
		const state = String(rec.state ?? "");
		if (state !== "merged" && state !== "aborted" && state !== "dead") continue;
		const paneId = String(rec.pane_id ?? "");
		const win = String(rec.window ?? "");
		const alive = paneId ? live.panes.has(paneId) : !win || live.windows.has(win);
		if (!alive) {
			fdStateOrDie(["set", ".issues", `(.issues | del(.["${issue}"]))`]);
			dropped.push(`${issue}:${state}`);
		}
	}
	if (dropped.length > 0) {
		process.stdout.write(`remove-merged: dropped ${dropped.length} entr${dropped.length === 1 ? "y" : "ies"} (${dropped.join(",")})\n`);
	}
}

function cmdReconcile(): void {
	const live = livePanesAndWindows();
	const issues = readIssuesJson();
	const dropped: string[] = [];
	const backfilled: string[] = [];
	const drift: string[] = [];
	for (const [issue, rec] of Object.entries(issues)) {
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
					drift.push(
						`${issue} (window:'${win}'→'${currentWindow}' worktree:'${worktree}'→'${currentPath}')`,
					);
					driftedThis = true;
				} else {
					const resolved = tmuxField(paneTarget, "#{pane_id}");
					if (resolved) {
						fdStateOrDie(["set", `.issues["${issue}"].pane_id`, JSON.stringify(resolved)]);
						paneId = resolved;
						backfilled.push(issue);
					}
				}
			}
		}
		if (driftedThis) continue;
		const alive = paneId ? live.panes.has(paneId) : !win || live.windows.has(win);
		if (!alive) {
			fdStateOrDie(["set", ".issues", `(.issues | del(.["${issue}"]))`]);
			dropped.push(issue);
		}
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
// Parity: scripts/pane-registry.bash cmd_teardown_window
// (see tests/parity/pane-registry.test.ts).
//
// Exit codes (mirror the bash sibling):
//   0 - window/pane killed, or already closed (terminal + dead pane)
//   1 - issue not registered (caller may treat as idempotent no-op)
//   2 - bad arguments
//   3 - registry drift: pane_id gone but state not terminal
//   4 - policy: pane_id alive but state non-terminal (rerun with --force)
//   5 - tmux kill failed: pane still alive after kill attempt
//   6 - registry read failure

const TERMINAL_STATES = new Set(["merged", "aborted", "dead"]);

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
	const r = fdState(["get", `.issues["${issue}"] // .entries["${issue}"] // empty`]);
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
	let paneAlive = false;
	if (paneId) {
		const live = tmuxLivePaneIds();
		paneAlive = live.has(paneId);
	}
	if (paneAlive) {
		if (!TERMINAL_STATES.has(state) && !force) {
			process.stderr.write(
				`teardown-window: policy refusal — pane_id '${paneId}' is alive but state is '${state}' (not merged|aborted|dead); set a terminal state first or rerun with --force\n`,
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
		const stillAlive = tmuxLivePaneIds().has(paneId);
		if (stillAlive) {
			process.stderr.write(
				`teardown-window: kill of ${kind} failed (status=${killResult.status}, pane_id=${paneId} still alive): ${killResult.stderr ?? ""}`,
			);
			if (!(killResult.stderr ?? "").endsWith("\n")) process.stderr.write("\n");
			process.exit(5);
		}
		process.stdout.write(
			`teardown-window: killed ${kind} (pane_id=${paneId}, window=${windowName}, force=${force ? 1 : 0})\n`,
		);
		return;
	}
	if (TERMINAL_STATES.has(state)) {
		process.stdout.write(`teardown-window: window already closed (pane_id=${paneId || "<none>"} gone, state=${state})\n`);
		return;
	}
	process.stderr.write(
		`teardown-window: registry drift — pane_id '${paneId || "<none>"}' is gone but state is '${state}' (not merged|aborted|dead); refusing to derive kill target from pane_target (#16)\n`,
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
