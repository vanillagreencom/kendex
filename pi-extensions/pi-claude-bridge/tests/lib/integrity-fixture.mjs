// Debug paths must be isolated before a bridge module captures them.
import "./debug-env.mjs";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { __testSetBridgeIntegrityState } from "../../src/index.js";
import { setExtensionApi } from "../../src/bridge-state.js";

/** A session and diagnostic destinations with no failed tool calls. */
export function integrityWorld(t) {
	const previousDiagPath = process.env.CLAUDE_BRIDGE_DIAG_PATH;
	const dir = mkdtempSync(join(tmpdir(), "claude-bridge-integrity-"));
	const diagPath = join(dir, "diag.log");
	const notifications = [];
	const sessionEntries = [];
	process.env.CLAUDE_BRIDGE_DIAG_PATH = diagPath;
	__testSetBridgeIntegrityState({
		ui: { notify: (message, level) => notifications.push({ message, level }) },
		sharedSession: { sessionId: "session-12345678", cursor: 4, cwd: "/repo" },
	});
	setExtensionApi({ appendEntry: (customType, data) => sessionEntries.push({ customType, data }) });
	t.after(() => {
		setExtensionApi(undefined);
		__testSetBridgeIntegrityState({ ui: null, sharedSession: null });
		if (previousDiagPath === undefined) delete process.env.CLAUDE_BRIDGE_DIAG_PATH;
		else process.env.CLAUDE_BRIDGE_DIAG_PATH = previousDiagPath;
		rmSync(dir, { recursive: true, force: true });
	});
	return {
		diagPath, notifications, sessionEntries,
		readDiagEntries: () => readFileSync(diagPath, "utf8").trim().split("\n").map((line) => JSON.parse(line)),
	};
}
