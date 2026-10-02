import { DEFAULT_DEADLINE_MS, withDeadline } from "../utils/deadline.js";
import { ByteBudgetExhausted, readTextWithin, truncationMetadata, type UrlReads } from "./byte-budget.js";
import { cloneOrUpdateRepo, defaultCacheDir, isGitInstalled, readBlobFromCache, readReadmeFromCache, readTreeFromCache, summarizeTreeEntries } from "./github-clone.js";

export type GitHubUrlKind = "repo" | "blob" | "tree" | "commit";

export interface ParsedGitHubUrl {
	kind: GitHubUrlKind;
	owner: string;
	repo: string;
	ref?: string;
	path?: string;
	apiUrl: string;
	rawUrl?: string;
}

export interface GitHubExtractOptions {
	fetchImpl?: typeof fetch;
	signal?: AbortSignal;
	maxTreeEntries?: number;
	cloneEnabled?: boolean;
	maxRepoSizeMB?: number;
	cloneTimeoutSeconds?: number;
	cacheDir?: string;
	maxAgeHours?: number;
	/** Deadline of each GitHub API, raw-file or README request, through its body; DEFAULT_DEADLINE_MS when absent. */
	timeoutMs?: number;
	/** This URL's reads under the calling web_fetch call's budget; the caller releases them when the URL's processing ends. */
	reads: UrlReads;
}

function splitRefAndPath(parts: string[]): { ref?: string; path?: string } {
	if (parts.length === 0) return {};
	return { ref: parts[0], path: parts.slice(1).join("/") || undefined };
}

export function parseGitHubUrl(input: string): ParsedGitHubUrl | undefined {
	const url = new URL(input);
	if (url.hostname !== "github.com" && url.hostname !== "www.github.com") return undefined;
	const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
	if (parts.length < 2) return undefined;
	const [owner, repo, marker, ...rest] = parts;
	const base = `https://api.github.com/repos/${owner}/${repo}`;
	if (!marker) return { kind: "repo", owner, repo, apiUrl: base };
	if (marker === "blob") {
		const { ref, path } = splitRefAndPath(rest);
		return { kind: "blob", owner, repo, ref, path, apiUrl: `${base}/contents/${path ?? ""}?ref=${encodeURIComponent(ref ?? "HEAD")}`, rawUrl: `https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${path}` };
	}
	if (marker === "tree") {
		const { ref, path } = splitRefAndPath(rest);
		return { kind: "tree", owner, repo, ref, path, apiUrl: `${base}/contents/${path ?? ""}?ref=${encodeURIComponent(ref ?? "HEAD")}` };
	}
	if (marker === "commit") return { kind: "commit", owner, repo, ref: rest[0], apiUrl: `${base}/commits/${rest[0] ?? ""}` };
	return { kind: "repo", owner, repo, apiUrl: base };
}

/** Every GitHub request: `read` takes the response under the request's deadline signal, which also ends its body read. */
async function githubRequest<T>(fetchImpl: typeof fetch, url: string, options: GitHubExtractOptions, init: RequestInit, read: (response: Response, signal: AbortSignal) => Promise<T>): Promise<T> {
	return await withDeadline(options.signal, options.timeoutMs ?? DEFAULT_DEADLINE_MS, `GitHub fetch of ${url}`, async (signal) => await read(await fetchImpl(url, { ...init, signal }), signal));
}

async function jsonFetch(fetchImpl: typeof fetch, url: string, options: GitHubExtractOptions): Promise<any> {
	return await githubRequest(fetchImpl, url, options, { headers: { accept: "application/vnd.github+json" } }, async (response) => {
		if (!response.ok) throw new Error(`GitHub fetch failed (${response.status}) for ${url}`);
		return await response.json();
	});
}

async function shouldUseClone(parsed: ParsedGitHubUrl, options: GitHubExtractOptions, fetchImpl: typeof fetch): Promise<{ useClone: boolean; sizeKB?: number; defaultBranch?: string }> {
	if (options.cloneEnabled === false) return { useClone: false };
	if (parsed.kind === "commit") return { useClone: false };
	if (!isGitInstalled()) return { useClone: false };
	try {
		const meta = await jsonFetch(fetchImpl, `https://api.github.com/repos/${parsed.owner}/${parsed.repo}`, options);
		const maxKB = (options.maxRepoSizeMB ?? 350) * 1024;
		const size = typeof meta?.size === "number" ? meta.size : 0;
		if (size > maxKB) return { useClone: false, sizeKB: size, defaultBranch: meta?.default_branch };
		return { useClone: true, sizeKB: size, defaultBranch: meta?.default_branch };
	} catch {
		return { useClone: false };
	}
}

async function extractFromClone(parsed: ParsedGitHubUrl, options: GitHubExtractOptions, defaultBranch: string | undefined) {
	const clone = await cloneOrUpdateRepo(parsed.owner, parsed.repo, parsed.ref ?? defaultBranch, {
		cacheDir: options.cacheDir ?? defaultCacheDir(),
		timeoutSeconds: options.cloneTimeoutSeconds,
		maxAgeHours: options.maxAgeHours,
	});
	const meta = { provider: "github", ...parsed, extraction: "clone", cachePath: clone.cachePath, headRef: clone.headRef, cloned: clone.cloned, updated: clone.updated, defaultBranch };
	if (parsed.kind === "blob" && parsed.path) {
		const blob = await readBlobFromCache(clone.cachePath, parsed.path, options.reads);
		if (!blob) throw new Error(`File not found in cloned repo: ${parsed.path}`);
		return { title: `${parsed.owner}/${parsed.repo}/${parsed.path}`, content: blob.content, metadata: { ...meta, bytes: blob.bytes, ...truncationMetadata(blob.cut) } };
	}
	if (parsed.kind === "tree") {
		const tree = await readTreeFromCache(clone.cachePath, parsed.path ?? "", options.maxTreeEntries ?? 200);
		if (!tree) throw new Error(`Directory not found in cloned repo: ${parsed.path ?? "/"}`);
		return { title: `${parsed.owner}/${parsed.repo}/${parsed.path ?? ""}`, content: summarizeTreeEntries(tree.entries, tree.truncated), metadata: { ...meta, entries: tree.entries.length, truncated: tree.truncated } };
	}
	const readmeBlob = await readReadmeFromCache(clone.cachePath, options.reads);
	const readme = readmeBlob?.content ?? "";
	const tree = await readTreeFromCache(clone.cachePath, "", options.maxTreeEntries ?? 80);
	const treeText = tree ? summarizeTreeEntries(tree.entries, tree.truncated) : "";
	const body = [`# ${parsed.owner}/${parsed.repo}`, `Cached at: ${clone.cachePath}`, treeText ? `\n## Tree (top entries)\n${treeText}` : undefined, readme ? `\n## README\n\n${readme}` : undefined].filter(Boolean).join("\n");
	return { title: `${parsed.owner}/${parsed.repo}`, content: body, metadata: { ...meta, hasReadme: Boolean(readme), entries: tree?.entries.length ?? 0, ...truncationMetadata(readmeBlob?.cut) } };
}

export async function extractGitHubUrl(input: string, options: GitHubExtractOptions) {
	const parsed = parseGitHubUrl(input);
	if (!parsed) return undefined;
	const fetchImpl = options.fetchImpl ?? fetch;
	const decision = await shouldUseClone(parsed, options, fetchImpl);
	if (decision.useClone) {
		try {
			return await extractFromClone(parsed, options, decision.defaultBranch);
		} catch (error) {
			// A clone failure falls through to the API path; a byte-budget refusal or an abort ends the URL instead.
			if (error instanceof ByteBudgetExhausted || options.signal?.aborted) throw error;
		}
	}
	if (parsed.kind === "blob" && parsed.rawUrl) {
		const rawUrl = parsed.rawUrl;
		const body = await githubRequest(fetchImpl, rawUrl, options, {}, async (response, signal) => {
			if (!response.ok) throw new Error(`GitHub raw fetch failed (${response.status}) for ${rawUrl}`);
			return await readTextWithin(response, options.reads, signal);
		});
		return { title: `${parsed.owner}/${parsed.repo}/${parsed.path ?? ""}`, content: body.text, metadata: { provider: "github", ...parsed, extraction: "raw", ...truncationMetadata(body.cut) } };
	}
	const data = await jsonFetch(fetchImpl, parsed.apiUrl, options);
	if (parsed.kind === "repo") {
		const readmeUrl = `https://raw.githubusercontent.com/${parsed.owner}/${parsed.repo}/HEAD/README.md`;
		const readme = await githubRequest(fetchImpl, readmeUrl, options, {}, async (response, signal) => response.ok ? await readTextWithin(response, options.reads, signal) : undefined).catch((error: unknown) => {
			// A repo without a readable README, its deadline passed included, still returns its description; a byte-budget refusal
			// or an abort ends the URL instead.
			if (error instanceof ByteBudgetExhausted || options.signal?.aborted) throw error;
			return undefined;
		});
		const content = `# ${data.full_name ?? `${parsed.owner}/${parsed.repo}`}\n\n${data.description ?? ""}\n\n${readme?.text ?? ""}`.trim();
		return { title: data.full_name ?? `${parsed.owner}/${parsed.repo}`, content, metadata: { provider: "github", ...parsed, extraction: "repo", stars: data.stargazers_count, defaultBranch: data.default_branch, ...truncationMetadata(readme?.cut) } };
	}
	if (Array.isArray(data)) {
		const entries = data.slice(0, options.maxTreeEntries ?? 200).map((entry: any) => `- ${entry.type === "dir" ? "dir" : "file"}: ${entry.path ?? entry.name}`).join("\n");
		return { title: `${parsed.owner}/${parsed.repo}/${parsed.path ?? ""}`, content: entries, metadata: { provider: "github", ...parsed, extraction: "tree", entries: data.length } };
	}
	const content = JSON.stringify(data, null, 2);
	return { title: `${parsed.owner}/${parsed.repo}`, content, metadata: { provider: "github", ...parsed, extraction: parsed.kind } };
}
