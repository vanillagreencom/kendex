import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	piSessionConnectedMismatch,
	resolvePiSubscriberBinding,
	type PiSubscriberBindingDeps,
} from "../../src/daemon/pi-binding.ts";
import { listTrackedEntriesForReconcile } from "../../src/daemon/pane-registry.ts";

function depsForTwoPanes(): PiSubscriberBindingDeps {
	return {
		readProcCwd: (pid) => {
			if (pid === "1303233") return "/repo/trees/older-pi-pane";
			if (pid === "2169938") return "/repo/trees/current-workflow";
			return null;
		},
		bridgeState: (pid) => {
			if (pid === "1303233") return { sessionId: "pi-old", socketPath: "/tmp/pi-session-bridge-1000/pi-1303233.sock" };
			if (pid === "2169938") return { sessionId: "pi-new", socketPath: "/tmp/pi-session-bridge-1000/pi-2169938.sock" };
			return null;
		},
		listBridgeRows: () => [
			{
				pid: 1303233,
				cwd: "/repo/trees/older-pi-pane",
				sessionId: "pi-old",
				socketPath: "/tmp/pi-session-bridge-1000/pi-1303233.sock",
				startedAt: "2026-05-17T23:30:00.000Z",
			},
			{
				pid: 2169938,
				cwd: "/repo/trees/current-workflow",
				sessionId: "pi-new",
				socketPath: "/tmp/pi-session-bridge-1000/pi-2169938.sock",
				startedAt: "2026-05-17T23:39:53.000Z",
			},
		],
	};
}

describe("Pi subscriber binding guard", () => {
	test("wrong stored sibling pid is rejected and matching cwd+session bridge is selected", () => {
		const result = resolvePiSubscriberBinding({
			paneId: "%1312",
			piPid: "1303233",
			piSocket: "/tmp/pi-session-bridge-1000/pi-1303233.sock",
			expectedCwd: "/repo/trees/current-workflow",
			expectedSessionId: "pi-new",
		}, depsForTwoPanes());

		expect(result.ok).toBe(true);
		if (!result.ok) throw new Error(result.reason);
		expect(result.pid).toBe("2169938");
		expect(result.socket).toBe("/tmp/pi-session-bridge-1000/pi-2169938.sock");
		expect(result.sessionId).toBe("pi-new");
		expect(result.procCwd).toBe("/repo/trees/current-workflow");
		expect(result.source).toBe("discovered");
	});

	test("no cwd+session candidate means no binding is accepted", () => {
		const result = resolvePiSubscriberBinding({
			paneId: "%1312",
			piPid: "1303233",
			piSocket: "/tmp/pi-session-bridge-1000/pi-1303233.sock",
			expectedCwd: "/repo/trees/current-workflow",
			expectedSessionId: "pi-new",
		}, {
			...depsForTwoPanes(),
			listBridgeRows: () => [{ pid: 1303233, cwd: "/repo/trees/older-pi-pane", sessionId: "pi-old", socketPath: "/tmp/pi-session-bridge-1000/pi-1303233.sock" }],
		});

		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("expected rejection");
		expect(result.reason).toBe("no-matching-pi-bridge");
		expect(result.pid).toBe("1303233");
		expect(result.procCwd).toBe("/repo/trees/older-pi-pane");
	});

	test("connected session comparison treats missing or different session id as mismatch", () => {
		expect(piSessionConnectedMismatch("pi-new", "pi-new")).toBe(false);
		expect(piSessionConnectedMismatch("pi-new", "pi-old")).toBe(true);
		expect(piSessionConnectedMismatch("pi-new", "")).toBe(true);
		expect(piSessionConnectedMismatch("", "pi-old")).toBe(false);
	});

	test("registry JSON carries cwd + pi_session_id into reconcile binding input", () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-pi-binding-registry-"));
		try {
			const registry = join(dir, "pane-registry");
			const rows = [{
				cwd: "/repo/trees/current-workflow",
				harness: "pi",
				kind: "workflow",
				pane_id: "%1312",
				pi_bridge_pid: 2169938,
				pi_bridge_socket: "/tmp/pi-session-bridge-1000/pi-2169938.sock",
				pi_session_id: "pi-new",
			}];
			writeFileSync(registry, `#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
  printf '%s\n' '${JSON.stringify(rows)}'
  exit 0
fi
exit 1
`);
			chmodSync(registry, 0o755);

			const entries = listTrackedEntriesForReconcile(registry, "");
			expect(entries).toHaveLength(1);
			const entry = entries[0]!;
			expect(entry.cwd).toBe("/repo/trees/current-workflow");
			expect(entry.adapterMeta?.piPid).toBe("2169938");
			expect(entry.adapterMeta?.piSocket).toBe("/tmp/pi-session-bridge-1000/pi-2169938.sock");
			expect(entry.adapterMeta?.piSessionId).toBe("pi-new");

			const binding = resolvePiSubscriberBinding({
				paneId: entry.paneId,
				piPid: entry.adapterMeta?.piPid,
				piSocket: entry.adapterMeta?.piSocket,
				expectedCwd: entry.cwd,
				expectedSessionId: entry.adapterMeta?.piSessionId,
			}, depsForTwoPanes());
			expect(binding.ok).toBe(true);
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});
});
