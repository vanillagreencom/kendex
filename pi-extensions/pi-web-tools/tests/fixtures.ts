import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";
import type { ExecOptions, ExecResult } from "@earendil-works/pi-coding-agent";
import { ByteBudget, TEXT_READ_BYTE_LIMIT, type UrlReads } from "../src/extract/byte-budget.js";
import type { PiExec } from "../src/utils/deadline.js";
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

/** Reads of other web_fetch calls that have each read TEXT_READ_BYTE_LIMIT bytes and hold them while their URLs are processed.
 * They await no chunk, so no BODY_IDLE_TIMEOUT_MS deadline returns their in-flight room; the test's end releases it. */
export async function heldReads(t: TestContext, count: number): Promise<UrlReads[]> {
	const chunk = new Uint8Array(TEXT_READ_BYTE_LIMIT);
	const held = await Promise.all(Array.from({ length: count }, async () => {
		const reads = new ByteBudget().openUrl();
		await reads.readBody(new Response(new ReadableStream<Uint8Array>({ pull: (controller) => controller.enqueue(chunk) })), TEXT_READ_BYTE_LIMIT, undefined);
		return reads;
	}));
	t.after(() => { for (const reads of held) reads.release(); });
	return held;
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

// Pi builds ExtensionAPI.exec from `execCommand` in its core/exec.js and exports it only through a loaded extension runtime,
// so the fixture loads that module from the installed package.
const { execCommand } = await import(new URL("./core/exec.js", import.meta.resolve("@earendil-works/pi-coding-agent")).href) as {
	execCommand: (command: string, args: string[], cwd: string, options?: ExecOptions) => Promise<ExecResult>;
};

/** Pi's ExtensionAPI.exec, as a loaded extension gets it. */
export const piExec: PiExec = { exec: (command, args, options) => execCommand(command, args, options?.cwd ?? process.cwd(), options) };

/** The URL of a local server standing in for a provider that hangs: `silent` accepts each request and never answers;
 * `stall` sends 200 headers and the first bytes of a JSON body, then nothing more with the connection open. */
export async function stallingServer(t: TestContext, mode: "silent" | "stall"): Promise<string> {
	const server = createServer((_request, response) => {
		if (mode === "stall") {
			response.writeHead(200, { "content-type": "application/json" });
			response.write('{"results":[');
		}
	});
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	t.after(() => {
		server.closeAllConnections();
		server.close();
	});
	return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

/** The URL of a local server that answers each request with 200 and the JSON `body`, `delayMs` after it arrives, as a slow
 * provider that does answer. */
export async function answeringServer(t: TestContext, delayMs: number, body: unknown): Promise<string> {
	const timers = new Set<ReturnType<typeof setTimeout>>();
	const server = createServer((_request, response) => {
		const timer = setTimeout(() => {
			timers.delete(timer);
			response.writeHead(200, { "content-type": "application/json" });
			response.end(JSON.stringify(body));
		}, delayMs);
		timers.add(timer);
	});
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	t.after(() => {
		for (const timer of timers) clearTimeout(timer);
		server.closeAllConnections();
		server.close();
	});
	return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

/** An executable `name` in `dir` that records its pid and its arguments, then sleeps `seconds` as a hung helper does. The
 * sleep replaces the script's process, so the recorded pid is the process the caller must kill. */
export function sleepingHelper(dir: string, name: string, seconds: number): { path: string; pid: () => number; args: () => string[] } {
	const path = join(dir, name);
	const pidFile = join(dir, `${name}.pid`);
	const argsFile = join(dir, `${name}.args`);
	writeFileSync(path, `#!/bin/sh\necho $$ > '${pidFile}'\nprintf '%s\\n' "$@" > '${argsFile}'\nexec sleep ${seconds}\n`);
	chmodSync(path, 0o755);
	return {
		path,
		pid: () => Number(readFileSync(pidFile, "utf8").trim()),
		args: () => readFileSync(argsFile, "utf8").trim().split("\n"),
	};
}

/** Whether a process with `pid` still runs. */
export function processAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
		throw error;
	}
}
