import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { liveInnerArgsForHandoff } from "../../src/daemon/pane-registry.ts";

function fakePaneRegistry(script: string): { bin: string; dir: string } {
	const dir = mkdtempSync(join(tmpdir(), "fd-handoff-registry-"));
	const bin = join(dir, "pane-registry");
	writeFileSync(bin, script);
	chmodSync(bin, 0o755);
	return { bin, dir };
}

describe("liveInnerArgsForHandoff", () => {
	test("uses atomic inner-live-json rows when query succeeds", () => {
		const { bin, dir } = fakePaneRegistry(`#!/usr/bin/env bash\ncat <<'JSON'\n[{"pane_id":"%1","harness":"pi"},{"pane_id":"%2","harness":"codex"}]\nJSON\n`);
		try {
			const result = liveInnerArgsForHandoff(bin, { innerTargets: ["%old"], innerHarnesses: ["claude"] });
			expect(result).toEqual({
				innerHarnesses: ["pi", "codex"],
				innerTargets: ["%1", "%2"],
				source: "live",
				warnings: [],
			});
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});

	test("falls back to current inner panes when live query fails", () => {
		const { bin, dir } = fakePaneRegistry(`#!/usr/bin/env bash\necho 'boom' >&2\nexit 7\n`);
		try {
			const result = liveInnerArgsForHandoff(bin, { innerTargets: ["%1", "%2"], innerHarnesses: ["pi", "codex"] });
			expect(result.innerTargets).toEqual(["%1", "%2"]);
			expect(result.innerHarnesses).toEqual(["pi", "codex"]);
			expect(result.source).toBe("fallback");
			expect(result.warnings.join("\n")).toContain("preserving current inner pane set");
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});

	test("empty live result is authoritative only after successful query", () => {
		const { bin, dir } = fakePaneRegistry(`#!/usr/bin/env bash\nprintf '[]\\n'\n`);
		try {
			const result = liveInnerArgsForHandoff(bin, { innerTargets: ["%old"], innerHarnesses: ["pi"] });
			expect(result.innerTargets).toEqual([]);
			expect(result.innerHarnesses).toEqual([]);
			expect(result.source).toBe("live");
			expect(result.warnings).toEqual([]);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
