import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { ByteBudget, type UrlReads } from "../src/extract/byte-budget.js";
import { getWebContent, type WebContentLookup } from "../src/storage.js";
import type { ResultRef } from "../src/utils/format.js";

import { clearPackageConfigCache } from "../src/package-config.js";

export function tempDir(t: TestContext): string {
	const root = mkdtempSync(join(tmpdir(), "pi-web-tools-test-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	return root;
}

/** One URL's reads under a fresh web_fetch call budget of `total` bytes, released when the test ends. */
export function urlReads(t: TestContext, total?: number): UrlReads {
	const reads = new ByteBudget(total).openUrl();
	t.after(() => reads.release());
	return reads;
}

/** A body of `chunks` chunks of `chunkBytes` bytes, pulled one at a time, that counts the chunks pulled and records a cancel.
 * After its chunks it closes, or with `end: "stall"` sends nothing more and never closes, as a server holding the connection open. */
export function streamedBody(chunks: number, chunkBytes: number, end: "close" | "stall" = "close") {
	const probe = { pulled: 0, cancelled: false };
	const chunk = new Uint8Array(chunkBytes).fill(0x61);
	const body = new ReadableStream<Uint8Array>({
		pull(controller) {
			if (probe.pulled === chunks) return end === "close" ? controller.close() : new Promise<void>(() => undefined);
			probe.pulled++;
			controller.enqueue(chunk);
		},
		cancel() { probe.cancelled = true; },
	}, { highWaterMark: 0 });
	return { body, probe };
}

export function isolateEnvironment(t: TestContext, keys: string[]): void {
	const saved = keys.map((key) => [key, process.env[key]] as const);
	t.after(() => {
		for (const [key, value] of saved) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		clearPackageConfigCache();
	});
	for (const key of keys) delete process.env[key];
	clearPackageConfigCache();
}

export const settingsEnvironment = [
	"PI_CODING_AGENT_DIR", "PI_WEB_TOOLS_CONFIG_FILE", "PI_WEB_TOOLS_OP_READ_TIMEOUT_MS",
	"EXA_API_KEY", "PERPLEXITY_API_KEY", "GEMINI_API_KEY", "OPENAI_API_KEY", "JINA_API_KEY",
];

/** A local repository with `files` committed, which git clones in place of https://github.com/fixture/repo.git
 * while the test runs; `cache` is an empty clone-cache directory beside it. */
export function githubFixtureRepo(t: TestContext, files: Record<string, string>): { cache: string; head: string } {
	isolateEnvironment(t, [...Object.keys(process.env).filter((key) => key.startsWith("GIT_")), "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"]);
	const root = tempDir(t);
	const source = join(root, "source");
	const config = join(root, "gitconfig");
	process.env.GIT_CONFIG_GLOBAL = config;
	process.env.GIT_CONFIG_NOSYSTEM = "1";
	process.env.GIT_CONFIG_COUNT = "1";
	process.env.GIT_CONFIG_KEY_0 = "core.hooksPath";
	process.env.GIT_CONFIG_VALUE_0 = join(root, "no-hooks");
	const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	git("init", "-q", "--initial-branch=main", source);
	for (const [name, content] of Object.entries(files)) writeFileSync(join(source, name), content);
	git("-C", source, "add", ...Object.keys(files));
	git("-C", source, "-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgSign=false", "commit", "-q", "-m", "init");
	git("config", "--file", config, `url.${source}.insteadOf`, "https://github.com/fixture/repo.git");
	return { cache: join(root, "cache"), head: git("-C", source, "rev-parse", "HEAD") };
}

/** Whether `text` appears in a tool result's details as Pi writes them to the
 *  session record. */
export function detailsHold(details: unknown, text: string): boolean {
	return JSON.stringify(details).includes(text);
}

/** The stored text a lookup found, or undefined when it found none. */
export function textOf(lookup: WebContentLookup): string | undefined {
	return lookup.status === "found" ? lookup.item.content : undefined;
}

/** Each result ref with its content id replaced by the text stored under it. */
export function withStoredText(results: ResultRef[]): Array<Omit<ResultRef, "contentId"> & { stored?: string }> {
	return results.map(({ contentId, ...ref }) => ({ ...ref, stored: contentId === undefined ? undefined : textOf(getWebContent(contentId)) }));
}
