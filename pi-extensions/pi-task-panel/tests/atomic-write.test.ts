import { expect, test } from "bun:test";
import { closeSync, mkdtempSync, openSync, readdirSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { writeFileAtomic } from "../extensions/atomic-write.ts";

test("a reader holding the old file still reads it whole after a replace", async () => {
	const base = realpathSync(mkdtempSync(join(tmpdir(), "pi-task-panel-atomic-")));
	try {
		const file = join(base, "session", "state.json");
		await writeFileAtomic(file, "old\n");
		const reader = openSync(file, "r");
		try {
			await writeFileAtomic(file, "new\n");
			expect(readFileSync(reader, "utf8")).toBe("old\n");
		} finally {
			closeSync(reader);
		}
		expect(readFileSync(file, "utf8")).toBe("new\n");
		expect(statSync(file).mode & 0o777).toBe(0o600);
		expect(statSync(dirname(file)).mode & 0o777).toBe(0o700);
		expect(readdirSync(dirname(file))).toEqual(["state.json"]);
	} finally {
		rmSync(base, { recursive: true, force: true });
	}
});
