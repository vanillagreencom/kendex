import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, normalize, relative, resolve } from "node:path";
import { promisify } from "node:util";

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

/** Root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`
 * means it, which `isAbsolute` is not: it calls a driveless `\root` absolute
 * where the renderer does not, putting the two on different roots. Hoisted, so
 * a circular import cannot reach it inside a temporal dead zone. */
function rootAnchored(path: string, windows: boolean): boolean { return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/"); }

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function defaultCacheDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	const piHome = rootAnchored(override, process.platform === "win32") ? override : join(homedir(), ".pi", "agent");
	return join(piHome, "cache", "github");
}

function repoCachePath(cacheDir: string, owner: string, repo: string): string {
	return join(cacheDir, `${owner}__${repo}`);
}

function isInside(parent: string, child: string): boolean {
	const rel = relative(resolve(parent), resolve(child));
	return Boolean(rel) && !rel.startsWith("..") && !rel.startsWith("/");
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

export function readBlobFromCache(cachePath: string, path: string): { content: string; bytes: number } | null {
	const target = normalize(join(cachePath, path));
	if (!isInside(cachePath, target)) return null;
	if (!existsSync(target)) return null;
	const info = statSync(target);
	if (!info.isFile()) return null;
	const content = readFileSync(target, "utf8");
	return { content, bytes: info.size };
}

export interface CacheTreeEntry { name: string; path: string; type: "dir" | "file"; size?: number }

export function readTreeFromCache(cachePath: string, path = "", limit = 200): { entries: CacheTreeEntry[]; truncated: boolean } | null {
	const target = normalize(join(cachePath, path));
	if (!isInside(cachePath, target) && resolve(target) !== resolve(cachePath)) return null;
	if (!existsSync(target) || !statSync(target).isDirectory()) return null;
	const dirEntries = readdirSync(target, { withFileTypes: true })
		.filter((entry) => entry.name !== ".git")
		.sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
	const total = dirEntries.length;
	const entries = dirEntries.slice(0, limit).map((entry) => {
		const full = join(target, entry.name);
		let size: number | undefined;
		if (entry.isFile()) try { size = statSync(full).size; } catch { /* ignore */ }
		const rel = relative(cachePath, full);
		return { name: entry.name, path: rel, type: entry.isDirectory() ? "dir" : "file", size } as CacheTreeEntry;
	});
	return { entries, truncated: total > limit };
}

export function readReadmeFromCache(cachePath: string): string | null {
	const candidates = ["README.md", "README.MD", "Readme.md", "readme.md", "README.markdown", "README.rst", "README.txt", "README"];
	for (const name of candidates) {
		const path = join(cachePath, name);
		if (existsSync(path)) {
			try { return readFileSync(path, "utf8"); } catch { /* ignore */ }
		}
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
