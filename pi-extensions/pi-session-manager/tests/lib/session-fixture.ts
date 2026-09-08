import { afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

export function sessionFixture(): string {
	mkdirSync(join(process.cwd(), "tmp"), { recursive: true });
	const root = mkdtempSync(join(process.cwd(), "tmp", "session-manager-"));
	afterEach(() => rmSync(root, { recursive: true, force: true }));
	return root;
}
