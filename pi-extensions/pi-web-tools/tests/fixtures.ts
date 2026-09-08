import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";

export function tempDir(t: TestContext): string {
	const root = mkdtempSync(join(tmpdir(), "pi-web-tools-test-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	return root;
}

export function isolateEnvironment(t: TestContext, keys: string[]): void {
	const saved = keys.map((key) => [key, process.env[key]] as const);
	t.after(() => {
		for (const [key, value] of saved) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	});
	for (const key of keys) delete process.env[key];
}

export const settingsEnvironment = [
	"PI_CODING_AGENT_DIR", "PI_WEB_TOOLS_CONFIG_FILE", "PI_WEB_TOOLS_OP_READ_TIMEOUT_MS",
	"EXA_API_KEY", "PERPLEXITY_API_KEY", "GEMINI_API_KEY", "OPENAI_API_KEY", "JINA_API_KEY",
];
