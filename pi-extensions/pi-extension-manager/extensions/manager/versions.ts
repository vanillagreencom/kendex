import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { npmCachePath } from "./paths.js";
import { commandFailure, runCommand } from "./process.js";
import { request } from "node:https";
import { NPM_CACHE_TTL_MS, type NpmCache, type Scope, type SettingsFile, type SourceIndex, type SourceIndexEntry } from "./types.js";

/** `npm root` answers from local configuration; past this it is treated as hung. */
const NPM_ROOT_DEADLINE_MS = 15_000;

type NpmRootLookup = { kind: "found"; root: string } | { kind: "failed"; detail: string };

const npmRootCaches = new WeakMap<AbortSignal, Map<string, Promise<NpmRootLookup>>>();

export function loadSourceIndex(settingsFiles: SettingsFile[]): SourceIndex {
	const merged: SourceIndex = {};
	for (const file of settingsFiles) {
		const path = join(file.baseDir, ".kendex-source.json");
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			if (parsed && typeof parsed === "object") {
				for (const [name, entry] of Object.entries(parsed)) {
					if (entry && typeof entry === "object") merged[name] = entry as SourceIndexEntry;
				}
			}
		} catch {}
	}
	return merged;
}

export function loadNpmCache(): NpmCache {
	const path = npmCachePath();
	if (!existsSync(path)) return {};
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8"));
		return parsed && typeof parsed === "object" ? parsed : {};
	} catch {
		return {};
	}
}

function saveNpmCache(cache: NpmCache): void {
	const path = npmCachePath();
	try {
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, JSON.stringify(cache, null, 2));
	} catch {}
}

export function parseSemver(v: string | undefined): number[] | undefined {
	if (!v) return undefined;
	const clean = v.replace(/^v/, "").split(/[-+]/)[0];
	const parts = clean.split(".").map((p) => Number.parseInt(p, 10));
	if (parts.some((n) => Number.isNaN(n))) return undefined;
	while (parts.length < 3) parts.push(0);
	return parts;
}

export function isNewer(latest: string | undefined, current: string | undefined): boolean {
	const a = parseSemver(latest);
	const b = parseSemver(current);
	if (!a || !b) return false;
	for (let i = 0; i < Math.max(a.length, b.length); i++) {
		const x = a[i] ?? 0;
		const y = b[i] ?? 0;
		if (x > y) return true;
		if (x < y) return false;
	}
	return false;
}

export function localPackageDirName(packageName: string): string {
	return packageName.startsWith("@vanillagreen/") ? packageName.split("/").pop() || packageName : packageName;
}

export function readPackageVersionFromDir(dir: string | undefined): string | undefined {
	if (!dir) return undefined;
	const manifestPath = join(dir, "package.json");
	if (!existsSync(manifestPath)) return undefined;
	try {
		const parsed = JSON.parse(readFileSync(manifestPath, "utf8"));
		return typeof parsed?.version === "string" ? parsed.version : undefined;
	} catch {
		return undefined;
	}
}

export function readSourceRepoVersion(repoRoot: string, packageName: string, sourcePath?: string): string | undefined {
	return readPackageVersionFromDir(sourcePath) ?? readPackageVersionFromDir(join(repoRoot, "pi-extensions", localPackageDirName(packageName)));
}

/** The session signal keys the memo and stops a running lookup. */
function npmRoot(signal: AbortSignal, args: string[], cwd: string): Promise<NpmRootLookup> {
	let memo = npmRootCaches.get(signal);
	if (!memo) {
		memo = new Map();
		npmRootCaches.set(signal, memo);
		const cache = memo;
		signal.addEventListener("abort", () => cache.clear(), { once: true });
	}
	const key = JSON.stringify([args, cwd]);
	const cached = memo.get(key);
	if (cached) return cached;
	const lookup = lookupNpmRoot(signal, args, cwd);
	memo.set(key, lookup);
	return lookup;
}

async function lookupNpmRoot(signal: AbortSignal, args: string[], cwd: string): Promise<NpmRootLookup> {
	const argv = ["root", ...args];
	const label = `npm ${argv.join(" ")}`;
	const result = await runCommand("npm", argv, { cwd, deadlineMs: NPM_ROOT_DEADLINE_MS, signal });
	const failure = commandFailure(result);
	if (failure) return { kind: "failed", detail: `${label}: ${failure.reason}=${failure.termination}` };
	if (result.kind !== "exited") throw new Error(`npm-root: a run with no failure ended as ${result.kind}`);
	const root = result.output.stdout.trim();
	if (result.output.truncated) return { kind: "failed", detail: `${label}: output exceeded the capture bound` };
	if (!root) return { kind: "failed", detail: `${label}: printed no root` };
	return { kind: "found", root };
}

function npmPrefixRoot(): string | undefined {
	const prefix = process.env.NPM_CONFIG_PREFIX || process.env.npm_config_prefix;
	return prefix ? join(prefix, "lib", "node_modules") : undefined;
}

export function npmPackageDir(root: string, npmName: string): string {
	return join(root, ...npmName.split("/"));
}

// Two-tier lookup: cheap candidates first (filesystem + env), expensive `npm root`
// spawns only as fallback. Returns ordered roots; the caller short-circuits on first
// existing dir (see `resolveNpmPackageDir`).
function cheapNpmRoots(scope: Scope, baseDir: string): string[] {
	const roots: string[] = [];
	if (scope === "project") {
		roots.push(join(baseDir, "npm", "node_modules"));
	} else if (scope === "user") {
		roots.push(join(baseDir, "npm", "node_modules"));
		const prefixRoot = npmPrefixRoot();
		if (prefixRoot) roots.push(prefixRoot);
	}
	return roots;
}

function expensiveNpmRootArgs(scope: Scope, baseDir: string): string[][] {
	if (scope === "project") return [["--prefix", join(baseDir, "npm")], []];
	if (scope === "user") return [["-g"]];
	return [[], ["-g"]];
}

/** A missed package reports each `npm root` lookup that failed rather than reading it as not installed. */
export type NpmPackageDirLookup = { kind: "found"; dir: string } | { kind: "missing"; lookupFailures: string[] };

export async function resolveNpmPackageDir(signal: AbortSignal, npmName: string, scope: Scope, baseDir: string, cwd: string): Promise<NpmPackageDirLookup> {
	const seen = new Set<string>();
	const tryRoot = (root: string): string | undefined => {
		const dir = npmPackageDir(root, npmName);
		if (seen.has(dir)) return undefined;
		seen.add(dir);
		return existsSync(join(dir, "package.json")) ? dir : undefined;
	};
	for (const root of cheapNpmRoots(scope, baseDir)) {
		const hit = tryRoot(root);
		if (hit) return { kind: "found", dir: hit };
	}
	const lookupFailures: string[] = [];
	for (const args of expensiveNpmRootArgs(scope, baseDir)) {
		const lookup = await npmRoot(signal, args, cwd);
		switch (lookup.kind) {
			case "found": {
				const hit = tryRoot(lookup.root);
				if (hit) return { kind: "found", dir: hit };
				break;
			}
			case "failed":
				lookupFailures.push(lookup.detail);
				break;
			default: {
				const unreachable: never = lookup;
				throw new Error(`npm-root: unknown lookup ${JSON.stringify(unreachable)}`);
			}
		}
	}
	return { kind: "missing", lookupFailures };
}

const UNSAFE_GIT_COMPONENT_RE = /[\\/]|[\0-\x1f\x7f]/;

function isSafeGitComponent(value: string): boolean {
	return value.length > 0 && value !== "." && value !== ".." && !UNSAFE_GIT_COMPONENT_RE.test(value);
}

function isInsidePath(root: string, candidate: string): boolean {
	const rel = relative(root, candidate);
	return rel === "" || (rel.length > 0 && !rel.startsWith("..") && !isAbsolute(rel));
}

function safeGitPackageDir(baseDir: string, host: string, repoPath: string): string | undefined {
	if (!isSafeGitComponent(host)) return undefined;
	const parts = repoPath.replace(/\.git$/, "").split("/");
	if (parts.length === 0 || parts.some((part) => !isSafeGitComponent(part))) return undefined;
	const root = resolve(baseDir, "git");
	const candidate = resolve(root, host, ...parts);
	return isInsidePath(root, candidate) ? candidate : undefined;
}

export function gitPackageDirCandidates(source: string, scope: Scope, baseDir: string): string[] {
	if (!(source.startsWith("git:") || source.startsWith("http://") || source.startsWith("https://") || source.startsWith("ssh://") || source.startsWith("git://"))) return [];
	let spec = source.startsWith("git:") ? source.slice("git:".length) : source;
	const lastRef = spec.lastIndexOf("@");
	const lastPathSeparator = Math.max(spec.lastIndexOf("/"), spec.lastIndexOf(":"));
	if (lastRef > lastPathSeparator) spec = spec.slice(0, lastRef);

	let host = "";
	let repoPath = "";
	try {
		if (/^[a-z][a-z0-9+.-]*:\/\//i.test(spec)) {
			const parsed = new URL(spec);
			host = parsed.hostname;
			repoPath = parsed.pathname.replace(/^\/+/, "");
		} else {
			const ssh = spec.match(/^[^@]+@([^:]+):(.+)$/);
			if (ssh) {
				host = ssh[1] ?? "";
				repoPath = ssh[2] ?? "";
			} else {
				const parts = spec.split("/").filter(Boolean);
				host = parts.shift() ?? "";
				repoPath = parts.join("/");
			}
		}
	} catch {
		return [];
	}
	if (!host || !repoPath) return [];
	const dir = safeGitPackageDir(baseDir, host, repoPath);
	return dir ? [dir] : [];
}

export function npmPackageNameFromSource(source: string): string | undefined {
	if (!source.startsWith("npm:")) return undefined;
	const rest = source.slice("npm:".length);
	if (!rest) return undefined;
	const withoutTag = rest.startsWith("@")
		? rest.split("@").slice(0, 2).join("@")
		: rest.split("@")[0];
	return withoutTag || undefined;
}

export const NPM_CHECK_TIMEOUT_MS = 4_000;
export const NPM_RESPONSE_MAX_BYTES = 256 * 1024;

/** Bound the whole response, including a peer that keeps its socket active. */
export function fetchNpmLatest(name: string, signal: AbortSignal): Promise<string> {
	return new Promise((resolve, reject) => {
		const encoded = encodeURIComponent(name).replace(/%40/g, "@").replace(/%2F/g, "/");
		let response: import("node:http").IncomingMessage | undefined;
		let settled = false;
		const finish = (error?: Error, version?: string) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			signal.removeEventListener("abort", abort);
			if (error) {
				response?.destroy();
				req.destroy();
				reject(error);
			} else resolve(version!);
		};
		const abort = () => finish(new Error("npm check cancelled"));
		const req = request({ host: "registry.npmjs.org", path: `/${encoded}/latest`, headers: { accept: "application/json", "user-agent": "kendex-extension-manager" } }, (res) => {
			response = res;
			res.on("error", (error) => finish(error));
			res.on("aborted", () => finish(new Error("npm response interrupted")));
			if (res.statusCode !== 200) return finish(new Error(`npm registry status ${res.statusCode}`));
			let bytes = 0;
			const chunks: Buffer[] = [];
			res.on("data", (chunk: Buffer) => {
				bytes += chunk.length;
				if (bytes > NPM_RESPONSE_MAX_BYTES) return finish(new Error("npm response byte limit exceeded"));
				chunks.push(chunk);
			});
			res.on("end", () => {
				if (settled) return;
				try {
					const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
					if (typeof parsed?.version !== "string") throw new Error("npm response has no version");
					finish(undefined, parsed.version);
				} catch (error) { finish(error instanceof Error ? error : new Error(String(error))); }
			});
		});
		const timer = setTimeout(() => finish(new Error("npm check deadline exceeded")), NPM_CHECK_TIMEOUT_MS);
		req.on("error", (error) => finish(error));
		signal.addEventListener("abort", abort, { once: true });
		if (signal.aborted) abort();
		else req.end();
	});
}

/** Refresh stale versions for this interaction. Its owner cancels the signal on teardown. */
export async function kickNpmUpdateCheck(packages: { name: string; npmName: string }[], signal: AbortSignal, onUpdate: () => void): Promise<void> {
	const cache = loadNpmCache();
	const now = Date.now();
	const stale = [...new Set(packages.map((p) => p.npmName))].filter((name) => !cache[name] || now - cache[name].checkedAt > NPM_CACHE_TTL_MS);
	let changed = false;
	for (const name of stale) {
		if (signal.aborted) return;
		try {
			const version = await fetchNpmLatest(name, signal);
			if (signal.aborted) return;
			cache[name] = { version, checkedAt: Date.now() };
			changed = true;
		} catch (error) {
			if (signal.aborted) return;
			console.warn(`npm check ${name}: ${String(error)}`);
		}
	}
	if (changed && !signal.aborted) {
		saveNpmCache(cache);
		onUpdate();
	}
}
