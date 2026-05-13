#!/usr/bin/env bun
// CLI parity port of skills/flightdeck/scripts/flightdeck-state.
//
// Subcommands: init | get | set | append | increment | tracked-entries | write-entry | path | phase | archive | master-busy

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
	archiveState,
	getField,
	initState,
	normalizePath,
	resolveSession,
	statePath,
	updateState,
} from "../state/master-state.ts";
import { resolveProjectRoot } from "../shared/project.ts";
import {
	assertWritableSchemaVersion,
	readTrackedEntries,
	unknownSchemaWarning,
	validateDomainIssueId,
	validateEntryId,
} from "../state/tracked-entry.ts";
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
const session = resolveSession(rawSession);
const file = statePath(session);

switch (action) {
	case "path": {
		process.stdout.write(`${file}\n`);
		break;
	}
	case "init": {
		assertWritableSchemaFromFile();
		initState(file);
		break;
	}
	case "get": {
		if (rest.length < 1) die("Usage: get <jq-path>");
		if (!existsSync(file)) process.exit(1);
		warnUnknownSchemaFromFile();
		process.stdout.write(getField(file, rest[0]!));
		break;
	}
	case "set": {
		if (rest.length < 2) die("Usage: set <field> <json-value>");
		assertWritableSchemaFromFile();
		const field = normalizePath(rest[0]!);
		updateState(file, `${field} = (${rest[1]})`);
		break;
	}
	case "append": {
		if (rest.length < 2) die("Usage: append <field> <json-value>");
		assertWritableSchemaFromFile();
		const field = normalizePath(rest[0]!);
		updateState(file, `${field} += [(${rest[1]})]`);
		break;
	}
	case "increment": {
		if (rest.length < 1) die("Usage: increment <field>");
		assertWritableSchemaFromFile();
		const field = normalizePath(rest[0]!);
		updateState(file, `${field} = ((${field} // 0) + 1)`);
		break;
	}
	case "tracked-entries": {
		if (!existsSync(file)) process.exit(1);
		const state = readStateJson();
		warnUnknownSchema(state);
		process.stdout.write(`${JSON.stringify(readTrackedEntries(state, { warn: warnLine }))}\n`);
		break;
	}
	case "write-entry": {
		if (rest.length < 2) die("Usage: write-entry <ENTRY_ID> <json-entry>");
		assertWritableSchemaFromFile();
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
		assertWritableSchemaFromFile();
		const ap = archiveState(file);
		if (ap) process.stdout.write(`${ap}\n`);
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
	default:
		die(`Unknown action: ${action}\nActions: init | get | set | append | increment | tracked-entries | write-entry | archive | master-busy | path | phase`);
}

function writeTrackedEntryFilter(id: string, entry: TrackedEntry): string {
	const idJson = JSON.stringify(id);
	const entryJson = JSON.stringify(entry);
	// NOTE: projection jq is intentionally duplicated with the bash sibling for parity;
	// next size increase here should move it to a shared jq fixture/heredoc.
	return `(${idJson}) as $id | (${entryJson}) as $entry | def s($v): if ($v | type) == "string" then $v else null end; def n($v): if ($v | type) == "number" then $v else null end; def b($v): if ($v | type) == "boolean" then $v else null end; def arr($v): if ($v | type) == "array" then $v else [] end; .entries = ((.entries // {}) + {($id): $entry}) | (($entry.domain.issue.id // (if $entry.kind == "issue" then $entry.id else null end)) as $issue_id | if $issue_id == null then . else .issues = ((.issues // {}) + {($issue_id): ((.issues[$issue_id] // {}) + {window: s($entry.window), pane_target: s($entry.pane_target), pane_id: s($entry.pane_id), harness: s($entry.harness), launch: (if ($entry.launch | type) == "object" then $entry.launch else null end), worktree: (s($entry.domain.issue.worktree) // s($entry.cwd)), pr_number: n($entry.domain.issue.pr_number), oc_url: s($entry.adapter.oc_url), oc_session_id: s($entry.adapter.oc_session_id), oc_port: n($entry.adapter.oc_port), cc_url: s($entry.adapter.cc_url), cc_session_uuid: s($entry.adapter.cc_session_uuid), cc_port: n($entry.adapter.cc_port), cc_transcript: s($entry.adapter.cc_transcript), pi_bridge_pid: n($entry.adapter.pi_bridge_pid), pi_bridge_socket: s($entry.adapter.pi_bridge_socket), pi_session_id: s($entry.adapter.pi_session_id), cx_ws: s($entry.adapter.cx_ws), cx_thread_id: s($entry.adapter.cx_thread_id), state: s($entry.state), substate: s($entry.substate), unknown_since: s($entry.unknown_since), last_capture_hash: s($entry.last_capture_hash), last_response_at: s($entry.last_response_at), spawned_at: s($entry.spawned_at), last_polled_at: s($entry.last_polled_at), orchestration_started: b($entry.domain.issue.orchestration_started), scope_files_declared: n($entry.domain.issue.scope_files_declared), scope_files_actual: n($entry.domain.issue.scope_files_actual), decisions_log: arr($entry.decisions_log), merge_commit: (s($entry.merge_commit) // s($entry.domain.issue.merge_commit))})}) end)`;
}

function readStateJson(): FlightdeckStateLike {
	return JSON.parse(readFileSync(file, "utf8")) as FlightdeckStateLike;
}

function tryReadStateJson(): FlightdeckStateLike | undefined {
	try {
		return readStateJson();
	} catch {
		// Preserve legacy jq-driven error semantics for corrupt files: callers
		// like pane-registry distinguish read failure from not-found by jq's exit
		// status, so schema preflight must not collapse malformed JSON to exit 1.
		return undefined;
	}
}

function warnLine(message: string): void {
	process.stderr.write(`${message}\n`);
}

function warnUnknownSchema(state: FlightdeckStateLike): void {
	const warning = unknownSchemaWarning(state);
	if (warning) warnLine(warning);
}

function warnUnknownSchemaFromFile(): void {
	if (!existsSync(file)) return;
	const state = tryReadStateJson();
	if (state) warnUnknownSchema(state);
}

function assertWritableSchemaFromFile(): void {
	if (!existsSync(file)) return;
	const state = tryReadStateJson();
	if (!state) return;
	const warning = unknownSchemaWarning(state);
	const allowFuture = process.env.FLIGHTDECK_ALLOW_FUTURE_SCHEMA === "1";
	if (warning && allowFuture) warnLine(warning);
	try {
		assertWritableSchemaVersion(state, allowFuture);
	} catch (error) {
		die(`Error: ${error instanceof Error ? error.message : String(error)}`);
	}
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
		warnUnknownSchemaFromFile();
		const fd = getField(file, `.issues["${issue}"].state // empty`).trim();
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
				const r = spawnSync("tmux", ["display-message", "-p", "#{pane_id}"], { encoding: "utf8" });
				masterPane = (r.stdout ?? "").trim();
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
