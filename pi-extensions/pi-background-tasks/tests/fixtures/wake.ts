import { DEFAULT_OUTPUT_ALERT_MAX_CHARS } from "../../extensions/constants.js";
import { tailText } from "../../extensions/format.js";
import { taskSnapshot } from "../../extensions/snapshot.js";
import type { ManagedTask, WakeDiagnostic } from "../../extensions/types.js";

export interface SendRecord {
	message: Record<string, unknown>;
	options: Record<string, unknown>;
}

export function sendDeps(output = "ready\n", diagnostics: WakeDiagnostic[] = []) {
	const messages: SendRecord[] = [];
	return {
		deps: {
			isShuttingDown: () => false,
			logDiagnostic: (diagnostic: WakeDiagnostic) => diagnostics.push(diagnostic),
			messageType: "pi-bg-task",
			now: () => 2_000,
			outputTail: () => tailText(output, DEFAULT_OUTPUT_ALERT_MAX_CHARS),
			rememberSnapshot: (task: ManagedTask) => taskSnapshot(task),
			sendMessage: (message: Record<string, unknown>, options: Record<string, unknown>) => {
				messages.push({ message, options });
			},
		},
		messages,
	};
}
