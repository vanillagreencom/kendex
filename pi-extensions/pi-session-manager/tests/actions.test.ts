import { expect, mock, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-coding-agent", () => ({ SessionManager: {} }));

// The fake trash sleeps for a minute; the delete's 5 s deadline returns well
// inside the 9 s bound, and the test's 15 s timeout fails a delete that waits.
test("a hung trash is killed at its deadline and the delete fails, keeping the file", async () => {
	const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
	const { deleteSessionFile } = await import("../extensions/actions.ts");
	const root = sessionFixture();
	const bin = join(root, "bin");
	mkdirSync(bin);
	writeFileSync(join(bin, "trash"), "#!/bin/sh\nexec sleep 60\n");
	chmodSync(join(bin, "trash"), 0o755);
	const sessionPath = join(root, "session.jsonl");
	writeFileSync(sessionPath, "{}\n");

	const saved = { PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
	process.env.PATH = `${bin}:${saved.PATH ?? ""}`;
	process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
	clearPackageConfigCache();
	try {
		const started = performance.now();
		const result = await deleteSessionFile(sessionPath, root, "session-id");
		expect(performance.now() - started).toBeLessThan(9_000);
		expect(result).toMatchObject({ ok: false, method: "trash" });
		expect(existsSync(sessionPath)).toBe(true);
	} finally {
		for (const [key, value] of Object.entries(saved)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		clearPackageConfigCache();
	}
}, 15_000);
