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

// ----- init ----------------------------------------------------------------

function cmdInit(issue: string, args: string[]): void {
	if (!issue) die("Usage: pane-registry init <ISSUE> [flags]");
	const defaultIdx = tmuxBasePaneIndex() || "0";
	const fields: Record<string, string> = {
		cc_port: "", cc_session_uuid: "", cc_transcript: "", cc_url: "",
		cx_thread_id: "", cx_ws: "",
		harness: "",
		launch_effort: "", launch_model: "",
		oc_port: "", oc_session_id: "", oc_url: "",
		pane_index: defaultIdx,
		pi_bridge_pid: "", pi_bridge_socket: "", pi_session_id: "",
		pr: "",
		window: "",
		worktree: "",
	};
	const flagMap: Record<string, keyof typeof fields> = {
		"--cc-port": "cc_port",
		"--cc-session-uuid": "cc_session_uuid",
		"--cc-transcript": "cc_transcript",
		"--cc-url": "cc_url",
		"--cx-thread-id": "cx_thread_id",
		"--cx-ws": "cx_ws",
		"--harness": "harness",
		"--oc-port": "oc_port",
		"--oc-session-id": "oc_session_id",
		"--oc-url": "oc_url",
		"--pane-index": "pane_index",
		"--pi-bridge-pid": "pi_bridge_pid",
		"--pi-bridge-socket": "pi_bridge_socket",
		"--pi-session-id": "pi_session_id",
		"--pr": "pr",
		"--window": "window",
		"--worktree": "worktree",
	};
	for (let i = 0; i < args.length; i += 1) {
		const key = flagMap[args[i] ?? ""];
		if (!key) die(`Unknown flag: ${args[i]}`);
		fields[key] = args[++i] ?? "";
	}
	if (!fields.window || !fields.harness || !fields.worktree) die("init requires --window, --harness, --worktree");

	// Auto-hydrate spawn discovery files.
	const harness = fields.harness;
	const issueId = issue;
	if (harness === "opencode" && !fields.oc_url) {
		const rec = readJsonIfExists<Record<string, unknown>>(ocSpawnFile(issueId));
		if (rec) {
			fields.oc_url = String(rec.url ?? "");
			fields.oc_session_id = String(rec.session_id ?? "");
			fields.oc_port = String(rec.port ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			fields.launch_model = String(launch?.model ?? "");
			fields.launch_effort = String(launch?.effort ?? "");
		}
	}
	if (harness === "claude" && !fields.cc_url) {
		const rec = readJsonIfExists<Record<string, unknown>>(ccSpawnFile(issueId));
		if (rec) {
			fields.cc_url = String(rec.url ?? "");
			fields.cc_session_uuid = String(rec.session_uuid ?? "");
			fields.cc_port = String(rec.port ?? "");
			fields.cc_transcript = String(rec.transcript ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			fields.launch_model = String(launch?.model ?? "");
			fields.launch_effort = String(launch?.effort ?? "");
		}
	}
	if (harness === "pi" && !fields.pi_bridge_pid) {
		const rec = readJsonIfExists<Record<string, unknown>>(piSpawnFile(issueId));
		if (rec) {
			fields.pi_bridge_pid = String(rec.pid ?? "");
			fields.pi_bridge_socket = String(rec.socket ?? "");
			fields.pi_session_id = String(rec.session_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			fields.launch_model = String(launch?.model ?? "");
			fields.launch_effort = String(launch?.effort ?? "");
		}
	}
	if (harness === "codex" && !fields.cx_ws) {
		const rec = readJsonIfExists<Record<string, unknown>>(cxSpawnFile(issueId));
		if (rec) {
			fields.cx_ws = String(rec.url ?? "");
			fields.cx_thread_id = String(rec.thread_id ?? "");
			const launch = rec.launch as Record<string, unknown> | undefined;
			fields.launch_model = String(launch?.model ?? "");
			fields.launch_effort = String(launch?.effort ?? "");
		}
	}

	fdStateOrDie(["init"]);
	const session = tmuxCurrentSession();
	const paneTarget = `${session}:${fields.window}.${fields.pane_index}`;
	let paneId = "";
	if (tmuxPaneExists(paneTarget)) {
		paneId = tmuxField(paneTarget, "#{pane_id}");
	}

	const launch = (fields.launch_model || fields.launch_effort)
		? { effort: fields.launch_effort || null, model: fields.launch_model || null }
		: null;

	const issueObj = {
		cc_port: numOrNull(fields.cc_port),
		cc_session_uuid: strOrNull(fields.cc_session_uuid),
		cc_transcript: strOrNull(fields.cc_transcript),
		cc_url: strOrNull(fields.cc_url),
		cx_thread_id: strOrNull(fields.cx_thread_id),
		cx_ws: strOrNull(fields.cx_ws),
		decisions_log: [],
		harness: fields.harness,
		last_capture_hash: null,
		last_polled_at: nowIso(),
		last_response_at: null,
		launch,
		oc_port: numOrNull(fields.oc_port),
		oc_session_id: strOrNull(fields.oc_session_id),
		oc_url: strOrNull(fields.oc_url),
		orchestration_started: false,
		pane_id: paneId || null,
		pane_target: paneTarget,
		pi_bridge_pid: numOrNull(fields.pi_bridge_pid),
		pi_bridge_socket: strOrNull(fields.pi_bridge_socket),
		pi_session_id: strOrNull(fields.pi_session_id),
		pr_number: numOrNull(fields.pr),
		scope_files_actual: null,
		scope_files_declared: null,
		spawned_at: nowIso(),
		state: "waiting",
		substate: null,
		unknown_since: null,
		window: fields.window,
		worktree: fields.worktree,
	};

	fdStateOrDie(["set", `.issues["${issueId}"]`, JSON.stringify(issueObj)]);
}

function strOrNull(s: string): string | null {
	return s ? s : null;
}

function numOrNull(s: string): number | null {
	if (!s) return null;
	const n = Number(s);
	return Number.isFinite(n) ? n : null;
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
			process.stdout.write(fdStateOrDie(["get", ".issues // {} | to_entries | map({issue: .key} + .value)"]));
			break;
		case "inner-panes":
			process.stdout.write(fdStateOrDie(["get", ".issues // {} | to_entries | map(.value.pane_id // .value.pane_target // empty) | join(\",\")"]));
			break;
		case "inner-harnesses":
			process.stdout.write(fdStateOrDie(["get", ".issues // {} | to_entries | map(.value.harness // \"\") | join(\",\")"]));
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
	const r = fdState(["get", `.issues["${issue}"].${field} // empty`]);
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
	const url = readField(issue, "oc_url");
	const sid = readField(issue, "oc_session_id");
	if (url && sid && url !== "null" && sid !== "null") {
		if (ocAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --session ${sid}\n`);
	}
}

function cmdCcChannelArgs(issue: string): void {
	if (!issue) die("Usage: cc-channel-args <ISSUE>");
	const url = readField(issue, "cc_url");
	const transcript = readField(issue, "cc_transcript");
	if (url && transcript && url !== "null" && transcript !== "null") {
		if (ccAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --transcript ${transcript}\n`);
	}
}

function cmdPiBridgeArgs(issue: string): void {
	if (!issue) die("Usage: pi-bridge-args <ISSUE>");
	const pid = readField(issue, "pi_bridge_pid");
	const socket = readField(issue, "pi_bridge_socket");
	if (pid && socket && pid !== "null" && socket !== "null") {
		if (piBridgeIsFresh(Number(pid), socket)) process.stdout.write(`--pid ${pid} --socket ${socket}\n`);
	}
}

function cmdCxBridgeArgs(issue: string): void {
	if (!issue) die("Usage: cx-bridge-args <ISSUE>");
	const url = readField(issue, "cx_ws");
	const thread = readField(issue, "cx_thread_id");
	if (url && thread && url !== "null" && thread !== "null") {
		if (cxAdapterIsFresh(issue)) process.stdout.write(`--url ${url} --thread ${thread}\n`);
	}
}

// ----- find-by-pane --------------------------------------------------------

function cmdFindByPane(target: string): void {
	if (!target) die("Usage: find-by-pane <pane-target-or-pane-id>");
	const out = fdStateOrDie([
		"get",
		`.issues // {} | to_entries[] | select(.value.pane_target == "${target}" or .value.pane_id == "${target}") | .key`,
	]).trim().split("\n").filter(Boolean)[0] ?? "";
	if (!out) process.exit(1);
	process.stdout.write(`${out}\n`);
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
	const r = fdState(["get", `.issues["${issue}"] // empty`]);
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
		die(`Unknown action: ${action}\nActions: init | list | get | set-state | set-substate | set | log-decision | remove | remove-merged | reconcile | teardown-window | teardown-entry | oc-attach-args | cc-channel-args | pi-bridge-args | cx-bridge-args | find-by-pane`);
}
