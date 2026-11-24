import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { clearPackageConfigCache, recordProjectTrust } from "../src/package-config.js";
import { loadSettings } from "../src/settings.js";
import { createWebResearchToolDefinition } from "../src/tools/web-research.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

const keyFileCases: Array<{ name: string; contents: string; key: string | null }> =
	JSON.parse(readFileSync(new URL("key-file-cases.json", import.meta.url), "utf8"));

// The key file sits outside the project, as a computer's private key file
// does. The fetch stub records the key each Exa request sends and whether
// process.env, which every process Pi starts inherits, holds it then.
test("KENDEX_KEY_FILE supplies EXA_API_KEY to the Exa request alone, after every other source", async (t) => {
	isolateEnvironment(t, settingsEnvironment);
	const root = tempDir(t);
	const user = join(root, "agent");
	const project = join(root, "project");
	mkdirSync(user);
	mkdirSync(join(project, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = user;
	recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
	const keyFile = join(root, "keys.env");
	const sent: Array<{ key: string | null; env: string | null }> = [];
	t.mock.method(globalThis, "fetch", async (_url: unknown, init: RequestInit) => {
		sent.push({ key: new Headers(init.headers).get("x-api-key"), env: process.env.EXA_API_KEY ?? null });
		return new Response(JSON.stringify({ output: { content: "Answer." }, results: [] }));
	});
	const tool = createWebResearchToolDefinition({ appendEntry() {} } as any, loadSettings);
	const research = async () => {
		clearPackageConfigCache();
		await tool.execute("call", { query: "q", researchMode: "lite" }, undefined, undefined, { cwd: project } as any);
		return sent.pop();
	};

	process.env.KENDEX_KEY_FILE = keyFile;
	for (const row of keyFileCases) {
		await t.test(row.name, async () => {
			writeFileSync(keyFile, `PERPLEXITY_API_KEY=other\n${row.contents}`);
			clearPackageConfigCache();
			assert.equal(loadSettings(project).apiKeys.exa, row.key ?? undefined);
			assert.equal(loadSettings(project).apiKeys.perplexity, undefined, "only the EXA_API_KEY line is read");
			if (row.key !== null) assert.deepEqual(await research(), { key: row.key, env: null });
		});
	}

	// A key the project holds wins over the key file, and a key file with no
	// key line costs such a project nothing.
	writeFileSync(join(project, ".env.local"), "EXA_API_KEY=from-project\n");
	for (const [name, contents] of [["file holds the line", "EXA_API_KEY=from-key-file\n"], ["file lacks the line", "OTHER_KEY=other\n"]]) {
		writeFileSync(keyFile, contents);
		assert.deepEqual(await research(), { key: "from-project", env: null }, name);
		assert.deepEqual(loadSettings(project).warnings.filter((warning) => warning.startsWith("key-file-")), [], name);
	}
});

// A key file that cannot supply the key leaves it unset, so the Exa tools are
// withheld, and the settings name the file and why.
test("a key file without a usable EXA_API_KEY leaves the key unset and names the file", (t) => {
	isolateEnvironment(t, settingsEnvironment);
	const root = tempDir(t);
	const user = join(root, "agent");
	const project = join(root, "project");
	mkdirSync(user);
	mkdirSync(project);
	process.env.PI_CODING_AGENT_DIR = user;
	const keyFile = join(root, "keys.env");
	for (const row of [
		{ name: "empty file", contents: "", path: keyFile, key: "key-file-key-missing" },
		{ name: "empty value", contents: "EXA_API_KEY=\n", path: keyFile, key: "key-file-key-missing" },
		{ name: "missing file", contents: undefined, path: join(root, "absent.env"), key: "key-file-unreadable" },
		{ name: "relative path", contents: undefined, path: "keys.env", key: "key-file-not-absolute" },
	]) {
		if (row.contents !== undefined) writeFileSync(keyFile, row.contents);
		process.env.KENDEX_KEY_FILE = row.path;
		clearPackageConfigCache();
		const settings = loadSettings(project);
		const refusals = settings.warnings.filter((warning) => warning.startsWith("key-file-"));
		assert.deepEqual({
			exa: settings.apiKeys.exa,
			keys: refusals.map((warning) => warning.slice(0, warning.indexOf(":"))),
			namesFile: refusals.every((warning) => warning.includes(row.path)),
		}, { exa: undefined, keys: [row.key], namesFile: true }, row.name);
	}
});
