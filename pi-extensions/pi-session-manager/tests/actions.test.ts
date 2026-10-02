import { expect, mock, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-coding-agent", () => ({ SessionManager: {} }));

// Each row is the `trash` on PATH: a script body, or none for a PATH whose bin
// directory holds no `trash`, so spawn emits "error". The hung row's helper
// sleeps past the 5 s deadline and then writes its marker: alive after the
// deadline, it is the helper that could still move the file. The real wait
// after the delete gives a surviving helper time to write that marker.
const rows = [
	{
		name: "a hung trash and its helper are killed at the deadline; the delete fails and keeps the file",
		trash: (marker: string) => `#!/bin/sh\n(sleep 6; touch '${marker}') &\nwait\n`,
		expected: { ok: false, method: "trash" },
		kept: true,
		helper: true,
	},
	{ name: "a trash that exits 1 falls through to unlink", trash: () => "#!/bin/sh\nexit 1\n", expected: { ok: true, method: "unlink" }, kept: false },
	{ name: "no trash on PATH falls through to unlink", trash: undefined, expected: { ok: true, method: "unlink" }, kept: false },
];

for (const row of rows) {
	test(row.name, async () => {
		const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
		const { deleteSessionFile } = await import("../extensions/actions.ts");
		const root = sessionFixture();
		const bin = join(root, "bin");
		mkdirSync(bin);
		const marker = join(root, "helper-survived");
		if (row.trash) {
			writeFileSync(join(bin, "trash"), row.trash(marker));
			chmodSync(join(bin, "trash"), 0o755);
		}
		const sessionPath = join(root, "session.jsonl");
		writeFileSync(sessionPath, "{}\n");

		const saved = { PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
		process.env.PATH = row.trash ? `${bin}:${saved.PATH ?? ""}` : bin;
		process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
		clearPackageConfigCache();
		try {
			const started = performance.now();
			const result = await deleteSessionFile(sessionPath, root, "session-id");
			expect(performance.now() - started).toBeLessThan(9_000);
			expect(result).toMatchObject(row.expected);
			expect(existsSync(sessionPath)).toBe(row.kept);
			if (row.helper) {
				await new Promise((resolve) => setTimeout(resolve, Math.max(0, 8_000 - (performance.now() - started))));
				expect(existsSync(marker)).toBe(false);
			}
		} finally {
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
			clearPackageConfigCache();
		}
	}, 20_000);
}
