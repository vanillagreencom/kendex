import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

function diagnosticPath(): string {
	const configured = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG?.trim();
	return configured ? resolve(configured) : join(tmpdir(), "vstack-pi-task-panel", "diagnostics.log");
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

export function reportTaskPanelPersistenceFailure(where: string, error: unknown, ctx?: ExtensionContext): void {
	const msg = error instanceof Error ? error.message : String(error);
	logTaskPanelDiagnostic("persistence failed", { where, error: msg });
	try {
		ctx?.ui.notify?.(
			`Task panel state persistence failed (${where}). Falling back to session history where available.`,
			"warning",
		);
	} catch {
		// UI notification is best-effort only.
	}
}
