import { spawnSync } from "node:child_process";
import { readlinkSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";

import { piResolveBridgeBin } from "../paths/pi.ts";

export interface PiSubscriberBindingInput {
	paneId: string;
	piPid?: string;
	piSocket?: string;
	expectedCwd?: string;
	expectedSessionId?: string;
}

export interface PiBridgeStateInfo {
	sessionId?: string;
	socketPath?: string;
}

export interface PiBridgeListRow {
	pid?: unknown;
	cwd?: unknown;
	sessionId?: unknown;
	session_id?: unknown;
	socketPath?: unknown;
	socket?: unknown;
	startedAt?: unknown;
	started_at?: unknown;
}

export interface PiSubscriberBindingDeps {
	readProcCwd?: (pid: string) => string | null;
	bridgeState?: (pid: string, socket?: string) => PiBridgeStateInfo | null;
	listBridgeRows?: () => PiBridgeListRow[];
}

export type PiSubscriberBindingResult =
	| { ok: true; pid: string; socket: string; sessionId: string; procCwd: string; source: "stored" | "discovered" }
	| { ok: false; reason: string; pid?: string; socket?: string; sessionId?: string; procCwd?: string; source?: "stored" | "discovered" };

interface Candidate {
	pid: string;
	socket: string;
	sessionId?: string;
	cwd?: string;
	startedAt?: number;
	source: "stored" | "discovered";
}

export function resolvePiSubscriberBinding(input: PiSubscriberBindingInput, deps: PiSubscriberBindingDeps = {}): PiSubscriberBindingResult {
	const expectedCwd = nonEmpty(input.expectedCwd);
	const expectedSessionId = nonEmpty(input.expectedSessionId);
	if (!expectedCwd) return { ok: false, reason: "missing-entry-cwd" };
	if (!expectedSessionId) return { ok: false, reason: "missing-pi-session-id" };

	const storedPid = numericString(input.piPid);
	const storedSocket = nonEmpty(input.piSocket) ?? "";
	let storedFailure: PiSubscriberBindingResult | null = null;
	if (storedPid) {
		const stored = validateCandidate({ pid: storedPid, socket: storedSocket, source: "stored" }, expectedCwd, expectedSessionId, deps);
		if (stored.ok) return stored;
		storedFailure = stored;
	}

	const candidates = (deps.listBridgeRows ?? defaultListBridgeRows)()
		.map(rowToCandidate)
		.filter((candidate): candidate is Candidate => candidate !== null)
		.filter((candidate) => candidate.sessionId === expectedSessionId)
		.filter((candidate) => !candidate.cwd || cwdInside(expectedCwd, candidate.cwd));
	candidates.sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0));
	for (const candidate of candidates) {
		const checked = validateCandidate(candidate, expectedCwd, expectedSessionId, deps);
		if (checked.ok) return checked;
	}

	return {
		ok: false,
		reason: candidates.length > 0 ? "no-valid-pi-bridge-candidate" : "no-matching-pi-bridge",
		pid: storedFailure?.ok === false ? storedFailure.pid : storedPid,
		socket: storedFailure?.ok === false ? storedFailure.socket : storedSocket,
		sessionId: storedFailure?.ok === false ? storedFailure.sessionId : undefined,
		procCwd: storedFailure?.ok === false ? storedFailure.procCwd : undefined,
		source: storedFailure?.ok === false ? storedFailure.source : undefined,
	};
}

export function piSessionConnectedMismatch(expectedSessionId: string | undefined, connectedSessionId: string | undefined): boolean {
	const expected = nonEmpty(expectedSessionId);
	if (!expected) return false;
	return (nonEmpty(connectedSessionId) ?? "") !== expected;
}

function validateCandidate(candidate: Candidate, expectedCwd: string, expectedSessionId: string, deps: PiSubscriberBindingDeps): PiSubscriberBindingResult {
	const readProcCwd = deps.readProcCwd ?? defaultReadProcCwd;
	const bridgeState = deps.bridgeState ?? defaultBridgeState;
	const procCwd = nonEmpty(readProcCwd(candidate.pid) ?? "");
	if (!procCwd) {
		return { ok: false, reason: "proc-cwd-unavailable", pid: candidate.pid, socket: candidate.socket, sessionId: candidate.sessionId, source: candidate.source };
	}
	if (!cwdInside(expectedCwd, procCwd)) {
		return { ok: false, reason: "cwd-mismatch", pid: candidate.pid, socket: candidate.socket, sessionId: candidate.sessionId, procCwd, source: candidate.source };
	}
	const state = bridgeState(candidate.pid, candidate.socket);
	const sessionId = nonEmpty(state?.sessionId) ?? nonEmpty(candidate.sessionId) ?? "";
	if (!sessionId) {
		return { ok: false, reason: "session-unavailable", pid: candidate.pid, socket: candidate.socket || state?.socketPath || "", procCwd, source: candidate.source };
	}
	if (sessionId !== expectedSessionId) {
		return { ok: false, reason: "session-mismatch", pid: candidate.pid, socket: candidate.socket || state?.socketPath || "", sessionId, procCwd, source: candidate.source };
	}
	return { ok: true, pid: candidate.pid, socket: candidate.socket || state?.socketPath || "", sessionId, procCwd, source: candidate.source };
}

function rowToCandidate(row: PiBridgeListRow): Candidate | null {
	const pid = numericString(row.pid);
	if (!pid) return null;
	return {
		pid,
		socket: nonEmpty(row.socketPath) ?? nonEmpty(row.socket) ?? "",
		sessionId: nonEmpty(row.sessionId) ?? nonEmpty(row.session_id),
		cwd: nonEmpty(row.cwd),
		startedAt: numericTime(row.startedAt) ?? numericTime(row.started_at),
		source: "discovered",
	};
}

function cwdInside(expectedCwd: string, actualCwd: string): boolean {
	const expected = normalizePath(expectedCwd);
	const actual = normalizePath(actualCwd);
	const rel = relative(expected, actual);
	return rel === "" || (!!rel && !rel.startsWith("..") && !isAbsolute(rel));
}

function normalizePath(path: string): string {
	return resolve(path.replace(/ \(deleted\)$/u, ""));
}

function numericString(value: unknown): string | undefined {
	if (typeof value === "number" && Number.isFinite(value) && value > 0) return String(Math.trunc(value));
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return /^[1-9][0-9]*$/u.test(trimmed) ? trimmed : undefined;
}

function numericTime(value: unknown): number | undefined {
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string" && value.trim()) {
		const parsed = Date.parse(value);
		if (Number.isFinite(parsed)) return parsed;
		const n = Number(value);
		if (Number.isFinite(n)) return n;
	}
	return undefined;
}

function nonEmpty(value: unknown): string | undefined {
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function defaultReadProcCwd(pid: string): string | null {
	try { return readlinkSync(`/proc/${pid}/cwd`); }
	catch { return null; }
}

function defaultListBridgeRows(): PiBridgeListRow[] {
	const bin = piResolveBridgeBin();
	if (!bin) return [];
	const r = spawnSync(bin, ["list", "--json"], { encoding: "utf8", timeout: 2_000 });
	if (r.status !== 0) return [];
	try {
		const parsed = JSON.parse(r.stdout ?? "[]") as unknown;
		const rows = Array.isArray(parsed) ? parsed : (parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>).data : undefined);
		const instances: unknown[] = Array.isArray(rows)
			? rows
			: rows && typeof rows === "object" && Array.isArray((rows as Record<string, unknown>).instances)
				? (rows as Record<string, unknown>).instances as unknown[]
				: [];
		return instances.filter((row): row is PiBridgeListRow => !!row && typeof row === "object" && !Array.isArray(row));
	} catch { return []; }
}

function defaultBridgeState(pid: string, socket?: string): PiBridgeStateInfo | null {
	const bin = piResolveBridgeBin();
	if (!bin) return null;
	const target = socket ? ["--socket", socket] : ["--pid", pid];
	const r = spawnSync(bin, ["state", ...target], { encoding: "utf8", timeout: 2_000 });
	if (r.status !== 0) return null;
	try {
		const parsed = JSON.parse(r.stdout ?? "{}") as unknown;
		if (!parsed || typeof parsed !== "object") return null;
		const root = parsed as Record<string, unknown>;
		const data = root.data && typeof root.data === "object" ? root.data as Record<string, unknown> : root;
		return {
			sessionId: nonEmpty(data.sessionId) ?? nonEmpty(data.session_id),
			socketPath: nonEmpty(data.socketPath) ?? nonEmpty(data.socket),
		};
	} catch { return null; }
}


