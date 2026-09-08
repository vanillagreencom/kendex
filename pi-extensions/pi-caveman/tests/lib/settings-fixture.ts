import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";

export function settingsFixture(t: TestContext) {
	const root = mkdtempSync(join(tmpdir(), "pi-caveman-test-"));
	const previous = process.env.PI_CODING_AGENT_DIR;
	t.after(() => {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		rmSync(root, { recursive: true, force: true });
	});
	const userDir = join(root, "agent");
	const projectDir = join(root, "project");
	mkdirSync(userDir, { recursive: true });
	mkdirSync(join(projectDir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = userDir;
	const userPath = join(userDir, "settings.json");
	const projectPath = join(projectDir, ".pi", "settings.json");
	function writeConfig(path: string, packages: Record<string, unknown>): void {
		writeFileSync(path, JSON.stringify({ kendex: { extensionManager: { config: packages } } }));
	}
	return { userPath, projectPath, projectDir, writeConfig };
}
