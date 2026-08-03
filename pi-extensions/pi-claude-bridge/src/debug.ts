import { appendFileSync, chmodSync, mkdirSync } from "fs";
import { dirname, join } from "path";
import { piUserDir } from "./config.js";

// --- Debug logging ---
// CLAUDE_BRIDGE_DEBUG=1 enables debug logging to <piUserDir>/claude-bridge.log
// (~/.pi/agent/claude-bridge.log unless PI_CODING_AGENT_DIR points elsewhere).

export const DEBUG = process.env.CLAUDE_BRIDGE_DEBUG === "1";
export const DEBUG_LOG_PATH = process.env.CLAUDE_BRIDGE_DEBUG_PATH || join(piUserDir(), "claude-bridge.log");

export function diagLogPath(): string {
	return process.env.CLAUDE_BRIDGE_DIAG_PATH || join(piUserDir(), "claude-bridge-diag.log");
}

// Ensure log directories exist when debug is enabled. 0o700/0o600 throughout:
// these logs carry prompt previews and session metadata and belong to the user
// alone — same discipline as diagDump.
if (DEBUG) {
	try {
		mkdirSync(dirname(DEBUG_LOG_PATH), { recursive: true, mode: 0o700 });
		mkdirSync(dirname(diagLogPath()), { recursive: true, mode: 0o700 });
		// mode on mkdir/append applies only at CREATION — repair permissions on
		// dirs and logs that predate the 0o700/0o600 hardening.
		chmodSync(dirname(DEBUG_LOG_PATH), 0o700);
		chmodSync(DEBUG_LOG_PATH, 0o600);
	} catch {
		// If directory creation fails, debug functions will throw on first use
	}
}

// Unique per module evaluation — confirms whether subagents share module state
export const moduleInstanceId = Math.random().toString(36).slice(2, 8);

export function debug(...args: unknown[]) {
	if (!DEBUG) return;
	const ts = new Date().toISOString();
	const fmt = (a: unknown): string => {
		if (typeof a === "string") return a;
		if (a instanceof Error) return `${a.name}: ${a.message}${a.stack ? "\n" + a.stack : ""}`;
		// A function argument is a lazy payload: hot-path call sites (per-token
		// stream events) pass a thunk so the expensive formatting only runs when
		// DEBUG is on — fmt is only reached past the early return (VST-15).
		if (typeof a === "function") return fmt((a as () => unknown)());
		return JSON.stringify(a);
	};
	const msg = args.map(fmt).join(" ");
	try { appendFileSync(DEBUG_LOG_PATH, `[${ts}] [${moduleInstanceId}] ${msg}\n`, { mode: 0o600 }); } catch { /* debug is best effort */ }
}

// Per-query CLI debug capture. When CLAUDE_BRIDGE_DEBUG=1, ask the Claude Code
// CLI subprocess to write its own debug log to a file we choose, and also
// forward its stderr into our debug stream. Drops straight into the real SDK's
// Options — see @anthropic-ai/claude-agent-sdk sdk.d.ts:1245 (debug, debugFile,
// stderr). Without this, CC's internal view of the world is invisible to us
// and "No conversation found" / empty-error reports are unactionable.
let nextCliDebugSeq = 1;
export function makeCliDebugOptions(tag: string): { debug?: boolean; debugFile?: string; stderr?: (data: string) => void } {
	if (!DEBUG) return {};
	const seq = nextCliDebugSeq++;
	const ts = new Date().toISOString().replace(/[:.]/g, "-");
	const logDir = join(dirname(DEBUG_LOG_PATH), "cc-cli-logs");
	try { mkdirSync(logDir, { recursive: true, mode: 0o700 }); chmodSync(logDir, 0o700); } catch { /* ignore */ }
	const debugFile = join(logDir, `${ts}-${tag}-${seq}.log`);
	debug(`cli-debug: ${tag} #${seq} → ${debugFile}`);
	return {
		debug: true,
		debugFile,
		stderr: (data: string) => {
			for (const line of data.split(/\r?\n/)) {
				if (line) debug(`[cli-stderr ${tag}#${seq}] ${line}`);
			}
		},
	};
}

/** Diagnostic dump — for "should never happen" paths. Gated on the same
 *  CLAUDE_BRIDGE_DEBUG flag as debug(): the entries carry session metadata
 *  and land in a log outside any host app's retention/cleanup boundary, so
 *  a host that has not opted into debugging must get no disk write (VST-15). */
export function diagDump(label: string, data: Record<string, unknown>) {
	if (!DEBUG) return;
	try {
		const ts = new Date().toISOString();
		const entry = { ts, moduleInstanceId, label, ...data };
		const path = diagLogPath();
		try { mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); } catch { /* best effort */ }
		appendFileSync(path, JSON.stringify(entry) + "\n", { mode: 0o600 });
		try { chmodSync(path, 0o600); } catch { /* best effort */ }
		debug(`DIAG: ${label} (see ${path})`);
	} catch (error) {
		debug(`DIAG FAILED: ${label}`, error);
	}
}
