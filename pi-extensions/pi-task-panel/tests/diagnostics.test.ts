import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { reportTaskPanelPersistenceFailure } from "../extensions/diagnostics.ts";

for (const operation of ["sidecar-read", "sidecar-write"]) {
	test(`persistence notice identifies ${operation}`, () => {
		const root = mkdtempSync(join(tmpdir(), "task-panel-diagnostics-"));
		const previous = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		try {
			process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(root, "diagnostics.log");
			const notices: Array<{ message: string; level: string }> = [];
			reportTaskPanelPersistenceFailure(operation, new Error("fixture failure"), {
				ui: { notify: (message: string, level: string) => notices.push({ message, level }) },
			} as never);
			expect(notices.map(({ message, level }) => ({ key: message.split("\n")[0], level }))).toEqual([
				{ key: `persistence_failure=${operation}`, level: "warning" },
			]);
		} finally {
			if (previous === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
			else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previous;
			rmSync(root, { recursive: true, force: true });
		}
	});
}
