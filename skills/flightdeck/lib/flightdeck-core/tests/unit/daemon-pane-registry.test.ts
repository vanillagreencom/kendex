import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { refreshTrackedWindowNames } from "../../src/daemon/pane-registry.ts";

function script(body: string): { dir: string; path: string } {
	const dir = mkdtempSync(join(tmpdir(), "fd-refresh-helper-"));
	const path = join(dir, "pane-registry-shim");
	writeFileSync(path, body);
	chmodSync(path, 0o755);
	return { dir, path };
}

describe("refreshTrackedWindowNames helper", () => {
	test("empty command path returns tagged error", () => {
		const result = refreshTrackedWindowNames("");
		expect(result.ok).toBe(false);
		if (!result.ok) expect(result.reason).toBe("missing-command");
	});

	test("missing command returns spawn-failed", () => {
		const result = refreshTrackedWindowNames("/no/such/pane-registry-command");
		expect(result.ok).toBe(false);
		if (!result.ok) expect(result.reason).toBe("spawn-failed");
	});

	test("nonzero command exit is surfaced", () => {
		const { dir, path } = script(`#!/usr/bin/env bash\necho boom >&2\nexit 7\n`);
		try {
			const result = refreshTrackedWindowNames(path);
			expect(result.ok).toBe(false);
			if (!result.ok) {
				expect(result.reason).toBe("command-failed");
				expect(result.message).toContain("status=7");
				expect(result.message).toContain("boom");
			}
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});

	test("invalid JSON is surfaced", () => {
		const { dir, path } = script(`#!/usr/bin/env bash\necho not-json\n`);
		try {
			const result = refreshTrackedWindowNames(path);
			expect(result.ok).toBe(false);
			if (!result.ok) expect(result.reason).toBe("invalid-json");
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});

	test("valid output carries updates and warnings", () => {
		const payload = JSON.stringify({
			cleared: ["gone"],
			updated: ["live"],
			warnings: [{ id: "warned", reason: "tmux-display-message-failed", message: "probe failed" }],
		});
		const { dir, path } = script(`#!/usr/bin/env bash\nprintf '%s\\n' '${payload}'\n`);
		try {
			const result = refreshTrackedWindowNames(path);
			expect(result.ok).toBe(true);
			if (result.ok) {
				expect(result.updated).toEqual(["live"]);
				expect(result.cleared).toEqual(["gone"]);
				expect(result.warnings).toEqual([{ id: "warned", reason: "tmux-display-message-failed", message: "probe failed" }]);
			}
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});
});
