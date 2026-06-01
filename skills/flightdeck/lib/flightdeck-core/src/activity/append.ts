import { spawnSync } from "node:child_process";
import { chmodSync, closeSync, mkdirSync, openSync } from "node:fs";
import { dirname } from "node:path";

import {
	ActivityValidationError,
	DEFAULT_ACTIVITY_DETAILS_MAX_BYTES,
	DEFAULT_ACTIVITY_MAX_BYTES,
	DEFAULT_ACTIVITY_MAX_EVENTS,
	normalizeActivityEvent,
	type ActivityEventInput,
	type FlightdeckActivityEventV1,
	type NormalizeActivityOptions,
} from "./types.ts";

const RECENT_ID_CACHE_LIMIT = 512;
const SECURE_FILE_MODE = 0o600;
const recentIds = new Map<string, true>();

export interface AppendActivityOptions extends NormalizeActivityOptions {
	maxEvents?: number;
	maxBytes?: number;
}

export type TryAppendActivityReason = "duplicate" | "archived" | "lock-busy" | "timeout" | "error";

export interface AppendActivityResult {
	event: FlightdeckActivityEventV1;
	appended: boolean;
	archived?: boolean;
}

export interface TryAppendActivityResult {
	event?: FlightdeckActivityEventV1;
	appended: boolean;
	archived?: boolean;
	reason?: TryAppendActivityReason;
	error?: string;
}

export function appendActivityEvent(file: string, input: ActivityEventInput, opts: AppendActivityOptions = {}): AppendActivityResult {
	const prepared = prepareActivityAppend(file, input, opts);
	const status = lockedAppendJsonlDedup({
		file,
		id: prepared.event.id,
		knownDuplicate: recentIds.has(prepared.recentKey),
		line: prepared.line,
		maxBytes: prepared.maxBytes,
		maxEvents: opts.maxEvents ?? DEFAULT_ACTIVITY_MAX_EVENTS,
	});
	if (status === "appended") rememberId(prepared.recentKey);
	return { appended: status === "appended", archived: status === "archived" ? true : undefined, event: prepared.event };
}

interface PreparedActivityAppend {
	event: FlightdeckActivityEventV1;
	line: string;
	maxBytes: number;
	recentKey: string;
}

function prepareActivityAppend(file: string, input: ActivityEventInput, opts: AppendActivityOptions): PreparedActivityAppend {
	const event = normalizeActivityEvent(input, opts);
	const line = stringifyEventForAppend(event, opts.detailsMaxBytes ?? DEFAULT_ACTIVITY_DETAILS_MAX_BYTES);
	const maxBytes = opts.maxBytes ?? DEFAULT_ACTIVITY_MAX_BYTES;
	const lineBytes = Buffer.byteLength(`${line}\n`, "utf8");
	if (lineBytes > maxBytes) {
		throw new ActivityValidationError(`activity event exceeds session byte cap (${lineBytes} > ${maxBytes})`);
	}
	return { event, line, maxBytes, recentKey: `${file}\0${event.id}` };
}

export function tryAppendActivityEvent(file: string, input: ActivityEventInput, opts: AppendActivityOptions = {}): TryAppendActivityResult {
	let prepared: PreparedActivityAppend;
	try {
		prepared = prepareActivityAppend(file, input, opts);
	} catch (error) {
		return { appended: false, error: error instanceof Error ? error.message : String(error), reason: "error" };
	}
	let status: LockedAppendStatus;
	try {
		status = lockedAppendJsonlDedup({
			file,
			id: prepared.event.id,
			knownDuplicate: recentIds.has(prepared.recentKey),
			line: prepared.line,
			maxBytes: prepared.maxBytes,
			maxEvents: opts.maxEvents ?? DEFAULT_ACTIVITY_MAX_EVENTS,
			nonblocking: true,
		});
	} catch (error) {
		return { appended: false, error: error instanceof Error ? error.message : String(error), event: prepared.event, reason: "error" };
	}
	if (status === "appended") {
		rememberId(prepared.recentKey);
		return { appended: true, event: prepared.event };
	}
	if (status === "duplicate") return { appended: false, event: prepared.event, reason: "duplicate" };
	if (status === "archived") return { appended: false, archived: true, event: prepared.event, reason: "archived" };
	return { appended: false, error: status.error, event: prepared.event, reason: status.reason };
}

function stringifyEventForAppend(event: FlightdeckActivityEventV1, detailsMaxBytes: number): string {
	let line = JSON.stringify(event);
	const maxEventBytes = detailsMaxBytes * 2;
	if (line.length <= maxEventBytes) return line;
	if (event.details) {
		const detailsBytes = Buffer.byteLength(JSON.stringify(event.details), "utf8");
		event.details = { original_bytes: detailsBytes, truncated: true };
		line = JSON.stringify(event);
	}
	if (line.length <= maxEventBytes) return line;
	if (event.body) {
		delete event.body;
		line = JSON.stringify(event);
	}
	if (line.length <= maxEventBytes) return line;
	throw new ActivityValidationError(`activity event exceeds maximum size (${line.length} > ${maxEventBytes})`);
}

function rememberId(key: string): void {
	recentIds.set(key, true);
	while (recentIds.size > RECENT_ID_CACHE_LIMIT) {
		const first = recentIds.keys().next().value;
		if (!first) break;
		recentIds.delete(first);
	}
}

interface LockedAppendOpts {
	file: string;
	id: string;
	knownDuplicate: boolean;
	line: string;
	maxEvents: number;
	maxBytes: number;
	nonblocking?: boolean;
}

type LockedAppendStatus = "appended" | "duplicate" | "archived" | { error?: string; reason: "lock-busy" | "timeout" | "error" };

function ensureSecureLockFile(lockFile: string): void {
	mkdirSync(dirname(lockFile), { mode: 0o700, recursive: true });
	const fd = openSync(lockFile, "a", SECURE_FILE_MODE);
	try {
		chmodSync(lockFile, SECURE_FILE_MODE);
	} finally {
		closeSync(fd);
	}
}

function lockedAppendJsonlDedup(opts: LockedAppendOpts): LockedAppendStatus {
	mkdirSync(dirname(opts.file), { mode: 0o700, recursive: true });
	const lockFile = `${opts.file}.lock`;
	ensureSecureLockFile(lockFile);
	const idNeedle = `"id":${JSON.stringify(opts.id)}`;
	const script = `
		set -euo pipefail
		umask 0077
		file="$1"; needle="$2"; max_events="$3"; max_bytes="$4"; known_duplicate="$5"
		mkdir -p "$(dirname "$file")"
		if [[ -e "$file.archived" ]]; then
			echo "activity file is archived; skipping append" >&2
			exit 11
		fi
		if [[ "$known_duplicate" == "1" ]]; then
			exit 10
		fi
		touch "$file"
		chmod 0600 "$file"
		if grep -Fq -- "$needle" "$file"; then
			exit 10
		fi
		cat >> "$file"
		chmod 0600 "$file"
		bytes=$(wc -c < "$file" | tr -d ' ')
		lines=$(wc -l < "$file" | tr -d ' ')
		if (( lines > max_events )); then
			tmp="$file.tmp.$$"
			tail -n "$max_events" "$file" > "$tmp"
			chmod 0600 "$tmp"
			mv "$tmp" "$file"
			chmod 0600 "$file"
		fi
		bytes=$(wc -c < "$file" | tr -d ' ')
		if (( bytes > max_bytes )); then
			tmp="$file.tmp.$$"
			LC_ALL=C awk -v max_bytes="$max_bytes" '
				{
					lines[NR] = $0
					sizes[NR] = length($0) + 1
				}
				END {
					bytes = 0
					start = NR + 1
					for (i = NR; i >= 1; i--) {
						if (bytes + sizes[i] > max_bytes) break
						bytes += sizes[i]
						start = i
					}
					for (i = start; i <= NR; i++) print lines[i]
				}
			' "$file" > "$tmp"
			chmod 0600 "$tmp"
			mv "$tmp" "$file"
			chmod 0600 "$file"
		fi
	`;
	const flockArgs = opts.nonblocking ? ["-w", "1", lockFile] : ["-x", lockFile];
	const r = spawnSync("flock", [
		...flockArgs, "bash", "-c", script, "_",
		opts.file, idNeedle, String(opts.maxEvents), String(opts.maxBytes), opts.knownDuplicate ? "1" : "0",
	], { encoding: "utf8", input: `${opts.line}\n`, timeout: opts.nonblocking ? 2000 : undefined });
	if (r.status === 10) return "duplicate";
	if (r.status === 11) {
		process.stderr.write(r.stderr || "activity file is archived; skipping append\n");
		return "archived";
	}
	if (r.error && (r.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
		if (opts.nonblocking) return { error: r.error.message, reason: "timeout" };
		throw new Error(`activity append failed: ${r.error.message}`);
	}
	if (r.status !== 0) {
		const error = r.stderr || `exit ${r.status ?? "unknown"}`;
		if (opts.nonblocking) return { error, reason: r.status === 1 ? "lock-busy" : "error" };
		throw new Error(`activity append failed: ${error}`);
	}
	return "appended";
}
