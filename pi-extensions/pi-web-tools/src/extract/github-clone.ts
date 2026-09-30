import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import nativePath, { join, relative, type PlatformPath } from "node:path";
import { promisify } from "node:util";
import { TEXT_READ_BYTE_LIMIT, type BoundedRead, type UrlReads } from "./byte-budget.js";

import { piUserDir } from "../package-config.js";

const execFileAsync = promisify(execFile);

export interface CloneOptions {
	cacheDir?: string;
	timeoutSeconds?: number;
	maxAgeHours?: number;
}

export interface CloneResult {
	cachePath: string;
	headRef: string;
	cloned: boolean;
	updated: boolean;
}

export function defaultCacheDir(): string {
	return join(piUserDir(), "cache", "github");
}

function repoCachePath(cacheDir: string, owner: string, repo: string): string {
	return join(cacheDir, `${owner}__${repo}`);
}

/** Whether `child` lies strictly under `parent` by the rules of `paths`. On Windows `relative` returns the target itself
 * for another drive or a UNC share, an absolute path that no `..` prefix marks. */
export function isInside(paths: PlatformPath, parent: string, child: string): boolean {
	const rel = paths.relative(paths.resolve(parent), paths.resolve(child));
	return Boolean(rel) && !rel.startsWith("..") && !paths.isAbsolute(rel);
}

async function runGit(args: string[], cwd: string | undefined, timeoutMs: number): Promise<string> {
	const result = await execFileAsync("git", args, { cwd, timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 });
	return result.stdout.toString().trim();
}

export async function cloneOrUpdateRepo(owner: string, repo: string, ref: string | undefined, options: CloneOptions = {}): Promise<CloneResult> {
	const cacheDir = options.cacheDir ?? defaultCacheDir();
	const targetPath = repoCachePath(cacheDir, owner, repo);
	const timeoutMs = (options.timeoutSeconds ?? 60) * 1000;
	mkdirSync(cacheDir, { recursive: true });
	const cloneUrl = `https://github.com/${owner}/${repo}.git`;
	if (!existsSync(join(targetPath, ".git"))) {
		await runGit(["clone", "--depth", "1", "--filter=blob:none", cloneUrl, targetPath], undefined, timeoutMs);
		if (ref && ref !== "HEAD") {
			try { await runGit(["fetch", "--depth", "1", "origin", ref], targetPath, timeoutMs); } catch { /* ref may already be HEAD */ }
			try { await runGit(["checkout", ref], targetPath, timeoutMs); } catch { /* ignore — keep default */ }
		}
		const headRef = await runGit(["rev-parse", "HEAD"], targetPath, timeoutMs);
		return { cachePath: targetPath, headRef, cloned: true, updated: false };
	}
	const ageMs = Date.now() - statSync(targetPath).mtimeMs;
	const maxAgeMs = (options.maxAgeHours ?? 24) * 3600 * 1000;
	let updated = false;
	if (ageMs > maxAgeMs) {
		try {
			await runGit(["fetch", "--depth", "1", "origin", ref ?? "HEAD"], targetPath, timeoutMs);
			await runGit(["reset", "--hard", `FETCH_HEAD`], targetPath, timeoutMs);
			updated = true;
		} catch { /* offline or network error — keep stale cache */ }
	}
	if (ref && ref !== "HEAD") {
		try { await runGit(["fetch", "--depth", "1", "origin", ref], targetPath, timeoutMs); } catch { /* ignore */ }
		try { await runGit(["checkout", ref], targetPath, timeoutMs); } catch { /* ignore */ }
	}
	const headRef = await runGit(["rev-parse", "HEAD"], targetPath, timeoutMs);
	return { cachePath: targetPath, headRef, cloned: false, updated };
}

export interface CachedBlob {
	content: string;
	/** The file's size on disk. */
	bytes: number;
	/** Where the read was cut and by which ceiling; absent when the file was read whole. */
	cut?: BoundedRead["cut"];
}

function isMissing(error: unknown): boolean {
	const code = (error as NodeJS.ErrnoException | undefined)?.code;
	return code === "ENOENT" || code === "ENOTDIR";
}

/** The canonical path of `path` under the clone cache with every symlink resolved, or null when it is missing or resolves
 * outside the cache, so a committed symlink cannot reach a file or directory beyond it. */
async function resolveInCache(cachePath: string, path: string): Promise<{ root: string; target: string } | null> {
	const resolved = await Promise.all([realpath(cachePath), realpath(join(cachePath, path))]).catch((error: unknown) => { if (isMissing(error)) return null; throw error; });
	if (!resolved) return null;
	const [root, target] = resolved;
	return target === root || isInside(nativePath, root, target) ? { root, target } : null;
}

/** Reads a file from the clone cache through `reads`, which sizes it before the read and reads at most its ceiling. */
export async function readBlobFromCache(cachePath: string, path: string, reads: UrlReads): Promise<CachedBlob | null> {
	const resolved = await resolveInCache(cachePath, path);
	if (!resolved || !(await stat(resolved.target)).isFile()) return null;
	const read = await reads.readFile(resolved.target, TEXT_READ_BYTE_LIMIT);
	return { content: read.bytes.toString("utf8"), bytes: read.size, ...(read.cut ? { cut: read.cut } : {}) };
}

export interface CacheTreeEntry { name: string; path: string; type: "dir" | "file"; size?: number }

export async function readTreeFromCache(cachePath: string, path = "", limit = 200): Promise<{ entries: CacheTreeEntry[]; truncated: boolean } | null> {
	const resolved = await resolveInCache(cachePath, path);
	if (!resolved || !(await stat(resolved.target)).isDirectory()) return null;
	const { root, target } = resolved;
	const dirEntries = (await readdir(target, { withFileTypes: true }))
		.filter((entry) => entry.name !== ".git")
		.sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
	const entries = await Promise.all(dirEntries.slice(0, limit).map(async (entry) => {
		const full = join(target, entry.name);
		const size = entry.isFile() ? await stat(full).then((stats) => stats.size, () => undefined) : undefined;
		return { name: entry.name, path: relative(root, full), type: entry.isDirectory() ? "dir" : "file", size } as CacheTreeEntry;
	}));
	return { entries, truncated: dirEntries.length > limit };
}

export async function readReadmeFromCache(cachePath: string, reads: UrlReads): Promise<CachedBlob | null> {
	const candidates = ["README.md", "README.MD", "Readme.md", "readme.md", "README.markdown", "README.rst", "README.txt", "README"];
	for (const name of candidates) {
		const readme = await readBlobFromCache(cachePath, name, reads);
		if (readme) return readme;
	}
	return null;
}

export function summarizeTreeEntries(entries: CacheTreeEntry[], truncated: boolean): string {
	const lines = entries.map((entry) => entry.type === "dir" ? `- ${entry.path}/` : `- ${entry.path}${typeof entry.size === "number" ? ` (${entry.size} bytes)` : ""}`);
	if (truncated) lines.push("- … (truncated)");
	return lines.join("\n");
}

export function clearGithubCache(): void {
	const dir = defaultCacheDir();
	if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
}

export function isGitInstalled(): boolean {
	try {
		execFileSync("git", ["--version"], { stdio: ["ignore", "pipe", "ignore"] });
		return true;
	} catch {
		return false;
	}
}

export function repoSizeFromMetadata(meta: { size?: unknown } | undefined): number {
	const raw = (meta && typeof meta.size === "number") ? meta.size : 0;
	return Math.max(0, Math.floor(raw));
}
