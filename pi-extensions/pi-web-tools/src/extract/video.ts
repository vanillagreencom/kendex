import { readFile, stat } from "node:fs/promises";
import { basename, extname } from "node:path";
import { requestWithin } from "../utils/deadline.js";

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

async function uploadVideoToGemini(filePath: string, apiKey: string, options: LocalVideoExtractOptions): Promise<{ uri: string; mimeType: string }> {
	const data = await readFile(filePath);
	const mimeType = videoMimeForPath(filePath);
	const initUrl = `https://generativelanguage.googleapis.com/upload/v1beta/files?key=${encodeURIComponent(apiKey)}`;
	const uploadUrl = await requestWithin("Gemini Files API upload start", initUrl, {
		method: "POST",
		headers: {
			"x-goog-upload-protocol": "resumable",
			"x-goog-upload-command": "start",
			"x-goog-upload-header-content-length": String(data.byteLength),
			"x-goog-upload-header-content-type": mimeType,
			"content-type": "application/json",
		},
		body: JSON.stringify({ file: { display_name: basename(filePath) } }),
	}, options, async (response) => {
		const uploadUrl = response.headers.get("x-goog-upload-url");
		if (!uploadUrl) throw new Error("Gemini Files API did not return upload URL.");
		return uploadUrl;
	});
	// fetch sets content-length from the body. Node 22's fetch appends its value to one given here ("5, 5"), which the npm
	// undici 8 dispatcher Pi loads rejects as an invalid content-length header.
	const payload = await requestWithin<any>("Gemini Files API upload", uploadUrl, {
		method: "POST",
		headers: {
			"x-goog-upload-offset": "0",
			"x-goog-upload-command": "upload, finalize",
		},
		body: data as unknown as BodyInit,
	}, options);
	const uri = payload?.file?.uri;
	if (!uri) throw new Error("Gemini Files API did not return a file URI.");
	return { uri, mimeType };
}

export async function extractLocalVideo(filePath: string, options: LocalVideoExtractOptions = {}): Promise<LocalVideoExtractResult> {
	if (!options.geminiApiKey) throw new Error("Local video extraction requires GEMINI_API_KEY for Gemini Files API upload.");
	const info = await stat(filePath);
	const limit = (options.maxSizeMB ?? 50) * 1024 * 1024;
	if (info.size > limit) throw new Error(`Video too large (${Math.round(info.size / (1024 * 1024))}MB > ${options.maxSizeMB ?? 50}MB).`);
	const { uri, mimeType } = await uploadVideoToGemini(filePath, options.geminiApiKey, options);
	const model = options.geminiModel ?? "gemini-2.5-flash";
	const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(options.geminiApiKey)}`;
	const body = { contents: [{ role: "user", parts: [{ fileData: { fileUri: uri, mimeType } }, { text: enhancePrompt(options.prompt) }] }] };
	const raw = await requestWithin<any>(`Gemini API ${model} local video analysis`, url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }, options);
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
