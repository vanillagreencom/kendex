import { readFile, stat } from "node:fs/promises";
import { basename, extname } from "node:path";
import { DEFAULT_DEADLINE_MS, withDeadline } from "../utils/deadline.js";

const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v", ".mpg", ".mpeg", ".wmv", ".flv"]);
const VIDEO_MIME: Record<string, string> = {
	".mp4": "video/mp4",
	".mov": "video/quicktime",
	".webm": "video/webm",
	".mkv": "video/x-matroska",
	".avi": "video/x-msvideo",
	".m4v": "video/x-m4v",
	".mpg": "video/mpeg",
	".mpeg": "video/mpeg",
	".wmv": "video/x-ms-wmv",
	".flv": "video/x-flv",
};

export function isLocalVideoPath(path: string): boolean {
	return VIDEO_EXTENSIONS.has(extname(path).toLowerCase());
}

export function videoMimeForPath(path: string): string {
	return VIDEO_MIME[extname(path).toLowerCase()] ?? "application/octet-stream";
}

export interface LocalVideoExtractOptions {
	prompt?: string;
	geminiApiKey?: string;
	geminiModel?: string;
	signal?: AbortSignal;
	maxSizeMB?: number;
	fetchImpl?: typeof fetch;
	/** Deadline of each Gemini request, the upload start, the upload and the analysis, through its body; DEFAULT_DEADLINE_MS
	 * when absent. */
	timeoutMs?: number;
}

export interface LocalVideoExtractResult {
	path: string;
	title: string;
	content: string;
	source: "gemini-api";
	metadata: Record<string, unknown>;
}

const DEFAULT_PROMPT = "Describe the contents of this video. Include important visual details, text on screen, and approximate timestamps for major sections.";

const TRANSCRIPT_KEYWORDS = /\b(transcri[bp]|transcription|verbatim|subtitle|caption|lyrics?\b)/i;
const TIMESTAMP_DIRECTIVE = "\n\nFormat the output as a transcript with [HH:MM:SS] timestamps at every line break (every 10-15 seconds). Include spoken dialogue, lyrics, and notable visual cues. Do not omit timestamps.";

function enhancePrompt(input: string | undefined): string {
	const base = input ?? DEFAULT_PROMPT;
	if (input && TRANSCRIPT_KEYWORDS.test(input) && !/\[hh:mm/i.test(input)) return base + TIMESTAMP_DIRECTIVE;
	return base;
}

async function uploadVideoToGemini(filePath: string, apiKey: string, fetchImpl: typeof fetch, options: LocalVideoExtractOptions): Promise<{ uri: string; mimeType: string }> {
	const data = await readFile(filePath);
	const mimeType = videoMimeForPath(filePath);
	const timeoutMs = options.timeoutMs ?? DEFAULT_DEADLINE_MS;
	const initUrl = `https://generativelanguage.googleapis.com/upload/v1beta/files?key=${encodeURIComponent(apiKey)}`;
	const uploadUrl = await withDeadline(options.signal, timeoutMs, "Gemini Files API upload start", async (signal) => {
		const startResponse = await fetchImpl(initUrl, {
			method: "POST",
			headers: {
				"x-goog-upload-protocol": "resumable",
				"x-goog-upload-command": "start",
				"x-goog-upload-header-content-length": String(data.byteLength),
				"x-goog-upload-header-content-type": mimeType,
				"content-type": "application/json",
			},
			body: JSON.stringify({ file: { display_name: basename(filePath) } }),
			signal,
		});
		if (!startResponse.ok) {
			const text = await startResponse.text().catch(() => "");
			throw new Error(`Gemini Files API start failed (${startResponse.status}): ${text || startResponse.statusText}`);
		}
		const uploadUrl = startResponse.headers.get("x-goog-upload-url");
		if (!uploadUrl) throw new Error("Gemini Files API did not return upload URL.");
		return uploadUrl;
	});
	const payload = await withDeadline(options.signal, timeoutMs, "Gemini Files API upload", async (signal) => {
		const finishResponse = await fetchImpl(uploadUrl, {
			method: "POST",
			headers: {
				"content-length": String(data.byteLength),
				"x-goog-upload-offset": "0",
				"x-goog-upload-command": "upload, finalize",
			},
			body: data as unknown as BodyInit,
			signal,
		});
		if (!finishResponse.ok) {
			const text = await finishResponse.text().catch(() => "");
			throw new Error(`Gemini Files API finalize failed (${finishResponse.status}): ${text || finishResponse.statusText}`);
		}
		return await finishResponse.json() as any;
	});
	const uri = payload?.file?.uri;
	if (!uri) throw new Error("Gemini Files API did not return a file URI.");
	return { uri, mimeType };
}

export async function extractLocalVideo(filePath: string, options: LocalVideoExtractOptions = {}): Promise<LocalVideoExtractResult> {
	if (!options.geminiApiKey) throw new Error("Local video extraction requires GEMINI_API_KEY for Gemini Files API upload.");
	const info = await stat(filePath);
	const limit = (options.maxSizeMB ?? 50) * 1024 * 1024;
	if (info.size > limit) throw new Error(`Video too large (${Math.round(info.size / (1024 * 1024))}MB > ${options.maxSizeMB ?? 50}MB).`);
	const fetchImpl = options.fetchImpl ?? fetch;
	const { uri, mimeType } = await uploadVideoToGemini(filePath, options.geminiApiKey, fetchImpl, options);
	const model = options.geminiModel ?? "gemini-2.5-flash";
	const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(options.geminiApiKey)}`;
	const body = { contents: [{ role: "user", parts: [{ fileData: { fileUri: uri, mimeType } }, { text: enhancePrompt(options.prompt) }] }] };
	const raw = await withDeadline(options.signal, options.timeoutMs ?? DEFAULT_DEADLINE_MS, `Gemini API ${model} local video analysis`, async (signal) => {
		const response = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal });
		if (!response.ok) {
			const text = await response.text().catch(() => "");
			throw new Error(`Gemini API video analysis failed (${response.status}): ${text || response.statusText}`);
		}
		return await response.json() as any;
	});
	const content = raw?.candidates?.[0]?.content?.parts?.map((p: any) => p?.text).filter(Boolean).join("\n").trim();
	if (!content) throw new Error("Gemini API returned empty response for local video.");
	return {
		path: filePath,
		title: basename(filePath),
		content,
		source: "gemini-api",
		metadata: { provider: "gemini-api", model, fileUri: uri, mimeType, sizeBytes: info.size },
	};
}
