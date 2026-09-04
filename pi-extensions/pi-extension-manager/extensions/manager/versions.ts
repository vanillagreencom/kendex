import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { npmCachePath } from "./paths.js";
import { runCommand } from "./process.js";
import { NPM_CACHE_TTL_MS, type NpmCache, type Scope, type SettingsFile, type SourceIndex, type SourceIndexEntry } from "./types.js";

let npmCheckInFlight = false;

// `npm root [args]` is slow (Node + npm config bootstrap, typically 40-500ms each). The
// answer is invariant for the process lifetime, so memoize. Without this, opening the
// extension manager popup spawned 2-5 `npm root` invocations per npm-sourced package
const npmRootMemo = new Map<string, string | undefined>();

function npmRootCacheKey(args: string[], cwd?: string): string {
	return `${args.join("\x00")}\x01${cwd ?? ""}`;
}

export function __resetNpmRootCacheForTests(): void {
	npmRootMemo.clear();
}

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

function npmRoot(args: string[], cwd?: string): string | undefined {
	const key = npmRootCacheKey(args, cwd);
	if (npmRootMemo.has(key)) return npmRootMemo.get(key);
	const result = runCommand("npm", ["root", ...args], { cwd });
	const value = result.error || (result.status ?? 1) !== 0 ? undefined : ((result.stdout ?? "").trim() || undefined);
	npmRootMemo.set(key, value);
	return value;
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

function expensiveNpmRoots(scope: Scope, baseDir: string, cwd: string): string[] {
	const roots: string[] = [];
	if (scope === "project") {
		const projectRoot = npmRoot(["--prefix", join(baseDir, "npm")], cwd);
		if (projectRoot) roots.push(projectRoot);
		const cwdRoot = npmRoot([], cwd);
		if (cwdRoot) roots.push(cwdRoot);
	} else if (scope === "user") {
		const globalRoot = npmRoot(["-g"], cwd);
		if (globalRoot) roots.push(globalRoot);
	} else {
		const localRoot = npmRoot([], cwd);
		if (localRoot) roots.push(localRoot);
		const globalRoot = npmRoot(["-g"], cwd);
		if (globalRoot) roots.push(globalRoot);
	}
	return roots;
}

export function resolveNpmPackageDir(npmName: string, scope: Scope, baseDir: string, cwd: string): string | undefined {
	const seen = new Set<string>();
	const tryRoot = (root: string): string | undefined => {
		const dir = npmPackageDir(root, npmName);
		if (seen.has(dir)) return undefined;
		seen.add(dir);
		return existsSync(join(dir, "package.json")) ? dir : undefined;
	};
	for (const root of cheapNpmRoots(scope, baseDir)) {
		const hit = tryRoot(root);
		if (hit) return hit;
	}
	for (const root of expensiveNpmRoots(scope, baseDir, cwd)) {
		const hit = tryRoot(root);
		if (hit) return hit;
	}
	return undefined;
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

export function npmInstalledVersion(npmName: string, cwd: string): string | undefined {
	const roots = [npmRoot(["-g"]), npmRoot([], cwd)].filter((root): root is string => Boolean(root));
	for (const root of roots) {
		const version = readPackageVersionFromDir(npmPackageDir(root, npmName));
		if (version) return version;
	}
	return undefined;
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

function fetchNpmLatest(name: string): Promise<string | undefined> {
	return new Promise((resolve) => {
		try {
			const https = require("node:https") as typeof import("node:https");
			const encoded = encodeURIComponent(name).replace(/%40/g, "@").replace(/%2F/g, "/");
			const req = https.request(
				{
					host: "registry.npmjs.org",
					path: `/${encoded}/latest`,
					headers: { accept: "application/json", "user-agent": "kendex-extension-manager" },
					timeout: 4000,
				},
				(res) => {
					if ((res.statusCode ?? 0) >= 400) {
						res.resume();
						resolve(undefined);
						return;
					}
					let body = "";
					res.setEncoding("utf8");
					res.on("data", (chunk) => { body += chunk; });
					res.on("end", () => {
						try {
							const parsed = JSON.parse(body);
							resolve(typeof parsed?.version === "string" ? parsed.version : undefined);
						} catch {
							resolve(undefined);
						}
					});
				},
			);
			req.on("error", () => resolve(undefined));
			req.on("timeout", () => { req.destroy(); resolve(undefined); });
			req.end();
		} catch {
			resolve(undefined);
		}
	});
}

export function kickNpmUpdateCheck(packages: { name: string; npmName: string }[], onUpdate: () => void): void {
	if (npmCheckInFlight || packages.length === 0) return;
	const cache = loadNpmCache();
	const now = Date.now();
	const stale = packages.filter((p) => {
		const entry = cache[p.npmName];
		return !entry || now - entry.checkedAt > NPM_CACHE_TTL_MS;
	});
	if (stale.length === 0) return;
	npmCheckInFlight = true;
	void (async () => {
		let changed = false;
		for (const p of stale) {
			const latest = await fetchNpmLatest(p.npmName);
			if (latest) {
				cache[p.npmName] = { version: latest, checkedAt: Date.now() };
				changed = true;
			}
		}
		if (changed) saveNpmCache(cache);
		npmCheckInFlight = false;
		try { onUpdate(); } catch {}
	})();
}
