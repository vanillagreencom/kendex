import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

function diagnosticPath(): string {
	const configured = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG?.trim();
	return configured ? resolve(configured) : join(tmpdir(), "kendex-pi-task-panel", "diagnostics.log");
}

export function logTaskPanelDiagnostic(message: string, details?: Record<string, unknown>): void {
	try {
		const path = diagnosticPath();
		mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
		const suffix = details === undefined ? "" : ` ${JSON.stringify(details)}`;
		appendFileSync(path, `${new Date().toISOString()} ${message}${suffix}\n`, { encoding: "utf8", mode: 0o600 });
	} catch {
		// Diagnostics must never affect task-panel control flow.
	}
}

const SESSION_HISTORY_FALLBACK = "Task panel state persistence failed. Falling back to session history where available.";

/** The explanation each failing store gets under its `persistence_failure=<where>` line. */
const PERSISTENCE_FAILURE_EXPLANATIONS = {
	"sidecar-read": SESSION_HISTORY_FALLBACK,
	"sidecar-write": SESSION_HISTORY_FALLBACK,
	"session-entry":
		"The task panel session history entry was not written. The sidecar file holds this change, but a session restart can restore the older state in session history instead. The next successful task panel save records it.",
	"session-entry-no-sidecar":
		"The task panel session history entry was not written, and neither was the sidecar file. A session restart loses this change. The next successful task panel save records it.",
} as const;

export type TaskPanelPersistenceFailure = keyof typeof PERSISTENCE_FAILURE_EXPLANATIONS;

export function reportTaskPanelPersistenceFailure(where: TaskPanelPersistenceFailure, error: unknown, ctx?: ExtensionContext): void {
	const msg = error instanceof Error ? error.message : String(error);
	logTaskPanelDiagnostic("persistence failed", { where, error: msg });
	try {
		ctx?.ui.notify?.(`persistence_failure=${where}\n${PERSISTENCE_FAILURE_EXPLANATIONS[where]}`, "warning");
	} catch {
		// UI notification is best-effort only.
	}
}
