import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path";
import { StringEnum } from "@earendil-works/pi-ai";
import { withFileMutationQueue, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { ExaClient, type ExaDeepType, type NormalizedExaResponse } from "../providers/exa.js";
import type { WebToolsSettings } from "../settings.js";
import { accent, emptyComponent, errorSummary, firstText, muted, providerLabel, successSummary, textComponent, tree, webCallText } from "../utils/render.js";
import { toResultRef } from "../utils/format.js";
import { withDeadline } from "../utils/deadline.js";

const deepTypes = ["deep-reasoning", "deep-lite", "deep"] as const;
const researchModes = ["lite", "standard", "full"] as const;
const reportFormats = ["findings", "markdown", "json"] as const;
const EXPANDED_SOURCE_LIMIT = 20;

export type ResearchMode = (typeof researchModes)[number];

interface ResearchModeDefaults {
	type: ExaDeepType;
	numResults: number;
	textMaxCharacters: number;
	timeoutSeconds: number;
	highlightsMaxCharacters: number;
	highlightNumSentences: number;
	highlightsPerUrl: number;
	summaryQuery?: string;
	maxAgeHours?: number;
	category?: string;
	outputSchema?: Record<string, unknown>;
}

type ResearchModeProfile = Partial<ResearchModeDefaults>;

export const defaultResearchOutputSchema = {
	type: "object",
	required: ["executiveSummary", "keyFindings", "recommendation", "risks", "revisitConditions"],
	properties: {
		executiveSummary: { type: "string", description: "Concise source-grounded summary of the answer." },
		keyFindings: { type: "array", items: { type: "string" }, description: "Important findings with source-grounded specifics." },
		tradeoffs: { type: "array", items: { type: "string" }, description: "Tradeoffs and alternatives surfaced by the evidence." },
		recommendation: { type: "string", description: "Recommended decision or decision criteria." },
		risks: { type: "array", items: { type: "string" }, description: "Known risks, gaps, or uncertainties." },
		revisitConditions: { type: "array", items: { type: "string" }, description: "Concrete conditions that should trigger re-running the research." },
	},
};

const researchModeDefaults: Record<ResearchMode, ResearchModeDefaults> = {
	lite: { type: "deep-lite", numResults: 15, textMaxCharacters: 10000, timeoutSeconds: 300, highlightsMaxCharacters: 600, highlightNumSentences: 3, highlightsPerUrl: 1 },
	standard: { type: "deep-reasoning", numResults: 50, textMaxCharacters: 16000, timeoutSeconds: 600, highlightsMaxCharacters: 900, highlightNumSentences: 4, highlightsPerUrl: 2, summaryQuery: "Summarize the source evidence relevant to the research question, preserving concrete facts and tradeoffs.", outputSchema: defaultResearchOutputSchema },
	full: { type: "deep-reasoning", numResults: 150, textMaxCharacters: 24000, timeoutSeconds: 1800, highlightsMaxCharacters: 1200, highlightNumSentences: 5, highlightsPerUrl: 3, summaryQuery: "Summarize the source evidence relevant to the research question, emphasizing decision criteria, tradeoffs, risks, and revisit triggers.", outputSchema: defaultResearchOutputSchema },
};

export const webResearchSchema = Type.Object({
	query: Type.Optional(Type.String({ description: "Research question to investigate with Exa Deep Search." })),
	queryFile: Type.Optional(Type.String({ description: "Path to a file containing the research question. Relative paths resolve against ctx.cwd; leading @ is stripped." })),
	contextFiles: Type.Optional(Type.Array(Type.String({ description: "Context files to append to the system prompt. Relative paths resolve against ctx.cwd; leading @ is stripped." }))),
	contextGlob: Type.Optional(Type.String({ description: "Simple bounded glob for context files, e.g. tmp/plans/research/ISSUE/context-*.md." })),
	researchMode: Type.Optional(StringEnum(researchModes)),
	type: Type.Optional(StringEnum(deepTypes)),
	systemPrompt: Type.Optional(Type.String()),
	additionalQueries: Type.Optional(Type.Array(Type.String())),
	numResults: Type.Optional(Type.Number()),
	textMaxCharacters: Type.Optional(Type.Number()),
	highlightsMaxCharacters: Type.Optional(Type.Number()),
	highlightNumSentences: Type.Optional(Type.Number()),
	highlightsPerUrl: Type.Optional(Type.Number()),
	summaryQuery: Type.Optional(Type.String()),
	maxAgeHours: Type.Optional(Type.Number()),
	category: Type.Optional(Type.String()),
	includeDomains: Type.Optional(Type.Array(Type.String())),
	excludeDomains: Type.Optional(Type.Array(Type.String())),
	startPublishedDate: Type.Optional(Type.String()),
	endPublishedDate: Type.Optional(Type.String()),
	outputSchema: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
	outputPath: Type.Optional(Type.String({ description: "Optional path for the findings report. Relative paths resolve against ctx.cwd; leading @ is stripped." })),
	reportTitle: Type.Optional(Type.String()),
	reportFormat: Type.Optional(StringEnum(reportFormats)),
	rawOutputPath: Type.Optional(Type.String({ description: "Optional explicit path for raw Exa JSON metadata. Defaults to findings.raw.json next to outputPath for findings and markdown reports; json reports write none." })),
});

export type WebResearchInput = Static<typeof webResearchSchema>;

function cleanPath(path: string): string {
	return path.startsWith("@") ? path.slice(1) : path;
}

export function resolveOutputPath(cwd: string, rawPath: string): string {
	const cleaned = cleanPath(rawPath.trim());
	return isAbsolute(cleaned) ? cleaned : resolve(cwd, cleaned);
}

export const MAX_CONTEXT_FILES = 25;

export async function expandSimpleGlob(cwd: string, rawGlob: string, limit = MAX_CONTEXT_FILES): Promise<string[]> {
	const cleaned = cleanPath(rawGlob.trim());
	if (!cleaned.includes("*")) return [resolveOutputPath(cwd, cleaned)];
	const normalized = cleaned.replace(/\\/g, "/");
	const slash = normalized.lastIndexOf("/");
	const dirPart = slash >= 0 ? normalized.slice(0, slash) : ".";
	const basePattern = slash >= 0 ? normalized.slice(slash + 1) : normalized;
	if (basePattern.split("*").length > 2) throw new Error(`contextGlob supports one '*' wildcard in the file name: ${rawGlob}`);
	const [prefix, suffix] = basePattern.split("*") as [string, string];
	const dir = resolveOutputPath(cwd, dirPart);
	const entries = await readdir(dir, { withFileTypes: true });
	const matches = entries
		.filter((entry) => entry.isFile() && entry.name.startsWith(prefix) && entry.name.endsWith(suffix))
		.map((entry) => join(dir, entry.name))
		.sort();
	if (matches.length > limit) throw new Error(`contextGlob matched ${matches.length} files; limit is ${limit}: ${rawGlob}`);
	return matches;
}

async function resolveContextPaths(cwd: string, params: WebResearchInput): Promise<string[]> {
	const explicit = (params.contextFiles ?? []).map((path) => resolveOutputPath(cwd, path));
	const globbed = params.contextGlob ? await expandSimpleGlob(cwd, params.contextGlob) : [];
	return Array.from(new Set([...explicit, ...globbed])).sort();
}

export async function prepareResearchInput(cwd: string, params: WebResearchInput): Promise<WebResearchInput & { query: string }> {
	let query = params.query?.trim() ?? "";
	if (params.queryFile) query = (await readFile(resolveOutputPath(cwd, params.queryFile), "utf8")).trim();
	if (!query) throw new Error("web_research requires query or queryFile.");
	const contextPaths = await resolveContextPaths(cwd, params);
	const contextParts = [];
	for (const path of contextPaths) {
		contextParts.push(`Context from ${path}:\n${await readFile(path, "utf8")}`);
	}
	const basePrompt = params.systemPrompt?.trim() || "You are producing an evidence-backed research findings report. Prioritize primary sources, current documentation, tradeoffs, risks, and concrete revisit conditions. Include source URLs for material claims when Exa returns citations.";
	return { ...params, query, systemPrompt: contextParts.length ? [basePrompt, ...contextParts].join("\n\n---\n\n") : basePrompt };
}

export function defaultRawOutputPath(outputPath: string): string {
	const ext = extname(outputPath);
	return ext ? `${outputPath.slice(0, -ext.length)}.raw.json` : `${outputPath}.raw.json`;
}

function modeProfile(settings: WebToolsSettings | undefined, researchMode: ResearchMode): ResearchModeProfile {
	const raw = settings?.exaResearchModes?.[researchMode];
	if (!raw) return {};
	const profile: ResearchModeProfile = {};
	if (deepTypes.includes(raw.type as ExaDeepType)) profile.type = raw.type as ExaDeepType;
	for (const key of ["numResults", "textMaxCharacters", "timeoutSeconds", "highlightsMaxCharacters", "highlightNumSentences", "highlightsPerUrl", "maxAgeHours"] as const) {
		if (typeof raw[key] === "number" && Number.isFinite(raw[key])) (profile as any)[key] = raw[key];
	}
	for (const key of ["summaryQuery", "category"] as const) {
		if (typeof raw[key] === "string" && raw[key].trim()) (profile as any)[key] = raw[key].trim();
	}
	if (raw.outputSchema && typeof raw.outputSchema === "object" && !Array.isArray(raw.outputSchema)) profile.outputSchema = raw.outputSchema as Record<string, unknown>;
	return profile;
}

export function applyResearchMode(input: Pick<WebResearchInput, "researchMode" | "type" | "numResults" | "textMaxCharacters" | "highlightsMaxCharacters" | "highlightNumSentences" | "highlightsPerUrl" | "summaryQuery" | "maxAgeHours" | "category" | "outputSchema">, settings?: WebToolsSettings) {
	const researchMode = input.researchMode ?? "standard";
	const defaults = researchModeDefaults[researchMode];
	if (!defaults) throw new Error(`Invalid researchMode '${researchMode}'. Expected one of: ${researchModes.join(", ")}.`);
	const profile = modeProfile(settings, researchMode);
	return {
		researchMode,
		type: input.type ?? profile.type ?? defaults.type,
		numResults: input.numResults ?? profile.numResults ?? defaults.numResults,
		textMaxCharacters: input.textMaxCharacters ?? profile.textMaxCharacters ?? defaults.textMaxCharacters,
		timeoutSeconds: profile.timeoutSeconds ?? defaults.timeoutSeconds,
		highlightsMaxCharacters: input.highlightsMaxCharacters ?? profile.highlightsMaxCharacters ?? defaults.highlightsMaxCharacters,
		highlightNumSentences: input.highlightNumSentences ?? profile.highlightNumSentences ?? defaults.highlightNumSentences,
		highlightsPerUrl: input.highlightsPerUrl ?? profile.highlightsPerUrl ?? defaults.highlightsPerUrl,
		summaryQuery: input.summaryQuery ?? profile.summaryQuery ?? defaults.summaryQuery,
		maxAgeHours: input.maxAgeHours ?? profile.maxAgeHours ?? defaults.maxAgeHours,
		category: input.category ?? profile.category ?? defaults.category,
		outputSchema: input.outputSchema ?? profile.outputSchema ?? defaults.outputSchema,
	};
}

function dedupeResults(responses: NormalizedExaResponse[]) {
	const seen = new Set<string>();
	const unique = [];
	let sourceCount = 0;
	for (const response of responses) {
		sourceCount += response.results.length;
		for (const result of response.results) {
			const key = (result.url || result.title || JSON.stringify(result)).trim().toLowerCase();
			if (seen.has(key)) continue;
			seen.add(key);
			unique.push(result);
		}
	}
	return { unique, sourceCount };
}

function compactAnswer(responses: NormalizedExaResponse[]): string | undefined {
	const answers = responses.map((response, index) => response.answer?.trim() ? `Query ${index + 1}: ${response.answer.trim()}` : undefined).filter(Boolean);
	if (answers.length === 0) return undefined;
	if (answers.length === 1) return answers[0]?.replace(/^Query 1: /, "");
	return answers.join("\n\n");
}

export async function runExaResearch(client: Pick<ExaClient, "deepResearch">, params: WebResearchInput & { query: string }, signal?: AbortSignal, settings?: WebToolsSettings): Promise<NormalizedExaResponse> {
	const startedAt = Date.now();
	const mode = applyResearchMode(params, settings);
	const queryList = mode.researchMode === "full"
		? [params.query, ...(params.additionalQueries ?? [])].map((query) => query.trim()).filter(Boolean)
		: [params.query];
	const uniqueQueries = Array.from(new Set(queryList));
	// The mode's timeoutSeconds bounds the whole run, every query of a full run together, and each request inside it.
	const timeoutMs = mode.timeoutSeconds * 1000;
	const responses = await withDeadline(signal, timeoutMs, `web_research ${mode.researchMode} mode`, async (deadline) => {
		const responses: NormalizedExaResponse[] = [];
		for (const query of uniqueQueries) {
			responses.push(await client.deepResearch({
				query,
				type: mode.type,
				category: mode.category,
				systemPrompt: params.systemPrompt,
				additionalQueries: mode.researchMode === "full" ? undefined : params.additionalQueries,
				numResults: mode.numResults,
				textMaxCharacters: mode.textMaxCharacters,
				highlightsMaxCharacters: mode.highlightsMaxCharacters,
				highlightNumSentences: mode.highlightNumSentences,
				highlightsPerUrl: mode.highlightsPerUrl,
				summaryQuery: mode.summaryQuery,
				maxAgeHours: mode.maxAgeHours,
				includeDomains: params.includeDomains,
				excludeDomains: params.excludeDomains,
				startPublishedDate: params.startPublishedDate,
				endPublishedDate: params.endPublishedDate,
				outputSchema: mode.outputSchema,
			}, deadline, timeoutMs));
		}
		return responses;
	});
	const { unique, sourceCount } = dedupeResults(responses);
	const raw = responses.length === 1 ? responses[0].raw : { responses: responses.map((response) => response.raw), results: unique, answer: compactAnswer(responses) };
	return {
		answer: compactAnswer(responses),
		results: unique,
		raw,
		metadata: {
			researchMode: mode.researchMode,
			type: mode.type,
			numResults: mode.numResults,
			textMaxCharacters: mode.textMaxCharacters,
			timeoutSeconds: mode.timeoutSeconds,
			highlightsMaxCharacters: mode.highlightsMaxCharacters,
			highlightNumSentences: mode.highlightNumSentences,
			highlightsPerUrl: mode.highlightsPerUrl,
			summaryQuery: mode.summaryQuery,
			maxAgeHours: mode.maxAgeHours,
			category: mode.category,
			outputSchema: mode.outputSchema,
			queryCount: uniqueQueries.length,
			sourceCount,
			uniqueSourceCount: unique.length,
			elapsedMs: Date.now() - startedAt,
			requests: responses.map((response) => response.metadata?.request).filter(Boolean),
		},
	};
}

function bulletSources(response: NormalizedExaResponse): string {
	if (response.results.length === 0) return "- No source URLs returned by Exa.";
	return response.results.map((result, index) => `- [${index + 1}] ${result.title ?? result.url ?? "Untitled"}${result.url ? ` — ${result.url}` : ""}${result.publishedDate ? ` (${result.publishedDate})` : ""}`).join("\n");
}

function oneLine(value: string, max = 260): string {
	const cleaned = sanitizeEvidenceText(value).replace(/\s+/g, " ").trim();
	return cleaned.length > max ? `${cleaned.slice(0, max - 1)}…` : cleaned;
}

function resultSnippet(result: NormalizedExaResponse["results"][number], max = 900): string {
	return oneLine([result.summary, ...(result.highlights ?? []), result.text].filter(Boolean).join(" "), max);
}

function sanitizeEvidenceText(value: string): string {
	return String(value ?? "")
		.split(/\r?\n/)
		.map((line) => line
			.replace(/^\s{0,3}#{1,6}\s+/g, "")
			.replace(/^\s{0,3}>\s*/g, "")
			.replace(/^\s*```.*$/g, "")
			.trim())
		.filter(Boolean)
		.join(" ")
		.replace(/\s+/g, " ")
		.trim();
}

function listMarkdown(value: unknown, fallback: string): string {
	if (Array.isArray(value) && value.length) return value.map((item) => `- ${sanitizeEvidenceText(typeof item === "string" ? item : JSON.stringify(item))}`).join("\n");
	if (typeof value === "string" && value.trim()) return value.trim();
	return fallback;
}

function structuredOutputContent(response: NormalizedExaResponse): Record<string, unknown> | undefined {
	const raw: any = response.raw;
	if (raw?.output?.content && typeof raw.output.content === "object" && !Array.isArray(raw.output.content)) return raw.output.content;
	return undefined;
}

function isGenericNoAnswer(value: string | undefined): boolean {
	return !value?.trim() || /Exa returned (sources|\d+ sources) but no synthesized answer field/i.test(value);
}

function fallbackSummary(response: NormalizedExaResponse): string {
	if (!isGenericNoAnswer(response.answer)) return response.answer!.trim();
	if (response.results.length === 0) return "No sources were returned. Re-run with broader terms or fewer filters before making a decision.";
	const themes = response.results.slice(0, 5).map((result, index) => `(${index + 1}) ${result.title ?? result.url ?? "Untitled"}`).join("; ");
	return `Exa returned ${response.results.length} sources but no synthesized answer field. The strongest source clusters are: ${themes}. Treat the findings below as an evidence brief and validate recommendations against primary sources before committing.`;
}

function keyFindings(response: NormalizedExaResponse): string {
	if (!isGenericNoAnswer(response.answer)) return response.answer!.trim();
	if (response.results.length === 0) return "- No source-backed findings were returned.";
	return response.results.slice(0, 8).map((result, index) => `- [${index + 1}] ${result.title ?? result.url ?? "Untitled"}: ${resultSnippet(result, 260) || "Review source directly."}`).join("\n");
}

export function renderFindingsReport(input: WebResearchInput & { query: string }, response: NormalizedExaResponse, options: { rawOutputPath?: string } = {}): string {
	const title = input.reportTitle || input.query;
	const structured = structuredOutputContent(response);
	const answer = typeof structured?.executiveSummary === "string" ? structured.executiveSummary.trim() : fallbackSummary(response);
	const findings = structured ? listMarkdown(structured.keyFindings ?? structured.findings, keyFindings(response)) : keyFindings(response);
	const tradeoffs = structured ? listMarkdown(structured.tradeoffs, "- Compare benefits against implementation cost, operational risk, and project-specific constraints before committing.\n- Prefer primary-source documentation and current release notes when evidence conflicts.") : "- Compare benefits against implementation cost, operational risk, and project-specific constraints before committing.\n- Prefer primary-source documentation and current release notes when evidence conflicts.";
	const recommendation = typeof structured?.recommendation === "string" && structured.recommendation.trim() ? structured.recommendation.trim() : answer;
	const risks = structured ? listMarkdown(structured.risks, "- Verify source freshness and applicability to this project.\n- Re-run research if provider APIs, pricing, or release notes change.\n- Treat uncited or snippet-only claims as hypotheses until confirmed by primary sources.") : "- Verify source freshness and applicability to this project.\n- Re-run research if provider APIs, pricing, or release notes change.\n- Treat uncited or snippet-only claims as hypotheses until confirmed by primary sources.";
	const revisit = structured ? listMarkdown(structured.revisitConditions, "- New primary-source documentation contradicts these findings.\n- Implementation constraints differ from the context supplied to research.\n- Exa Deep Search returns materially different source coverage in a later run.") : "- New primary-source documentation contradicts these findings.\n- Implementation constraints differ from the context supplied to research.\n- Exa Deep Search returns materially different source coverage in a later run.";
	const evidence = response.results.map((result, index) => {
		const snippet = sanitizeEvidenceText(resultSnippet(result, 1200)).split("\n").map((line) => `> ${line}`).join("\n");
		return `### [${index + 1}] ${result.title ?? result.url ?? "Untitled"}\n\n${result.url ?? ""}\n\n${snippet || "> No snippet returned."}`;
	}).join("\n\n");
	const metadata = [
		`- Mode: ${response.metadata.researchMode ?? input.researchMode ?? "standard"}`,
		`- Exa type: ${response.metadata.type ?? input.type ?? "deep-reasoning"}`,
		`- Queries: ${response.metadata.queryCount ?? 1}`,
		`- Sources: ${response.metadata.uniqueSourceCount ?? response.results.length} unique${response.metadata.sourceCount && response.metadata.sourceCount !== response.results.length ? ` (${response.metadata.sourceCount} returned before dedupe)` : ""}`,
		options.rawOutputPath ? `- Raw metadata sidecar: ${options.rawOutputPath}` : undefined,
	].filter(Boolean).join("\n");
	return `# Findings: ${title}\n\n## Research Question\n\n${input.query}\n\n## Executive Summary\n\n${answer}\n\n## Key Findings\n\n${findings}\n\n## Evidence and Sources\n\n${bulletSources(response)}\n\n${evidence}\n\n## Tradeoffs / Alternatives\n\n${tradeoffs}\n\n## Recommendation / Decision Criteria\n\n${recommendation}\n\nUse the source evidence above as decision criteria; validate any project-specific assumptions before irreversible work.\n\n## Risks / Unknowns\n\n${risks}\n\n## Revisit Conditions\n\n${revisit}\n\n## Research Metadata\n\n${metadata}\n`;
}

export interface RawResearchSidecar {
	metadata: Record<string, unknown> & { rawOutputPath?: string };
	raw: unknown;
}

export function buildRawSidecar(response: NormalizedExaResponse, rawOutputPath?: string): RawResearchSidecar {
	return {
		metadata: { ...response.metadata, rawOutputPath },
		raw: response.raw,
	};
}

/** The research metadata a tool result's details and the session entry carry:
 *  the mode, type and counts the renderer draws. Pi keeps both in the session
 *  record, and the request bodies in the full metadata hold the text of every
 *  context file, so only the raw sidecar keeps them, and only when `execute`
 *  writes one. */
function researchDetailsMetadata(metadata: NormalizedExaResponse["metadata"]): Record<string, unknown> {
	const { researchMode, type, queryCount, sourceCount, uniqueSourceCount } = metadata;
	return { researchMode, type, queryCount, sourceCount, uniqueSourceCount };
}

export function renderWebResearchSourceTree(sources: any[], theme: any, expanded = false, limit = EXPANDED_SOURCE_LIMIT): string[] {
	if (!expanded || sources.length === 0) return [];
	const shown = sources.slice(0, Math.max(1, limit));
	const hidden = Math.max(0, sources.length - shown.length);
	const lines: string[] = [];
	for (let index = 0; index < shown.length; index++) {
		const source = shown[index] ?? {};
		const isLastVisible = index === shown.length - 1 && hidden === 0;
		const title = source.title || source.url || "Untitled";
		const date = source.publishedDate ? muted(theme, ` · ${source.publishedDate}`) : "";
		lines.push(`${tree(theme, isLastVisible ? "└" : "├")}${accent(theme, `[${index + 1}] ${oneLine(title, 120)}`)}${date}`);
		if (source.url) {
			const stem = isLastVisible ? muted(theme, "     ") : tree(theme, "│");
			lines.push(`${stem}${muted(theme, oneLine(source.url, 140))}`);
		}
	}
	if (hidden > 0) lines.push(`${tree(theme, "└")}${muted(theme, `… ${hidden} more sources · UI cap ${shown.length}/${sources.length}`)}`);
	return lines;
}

export function displayWebResearchPath(cwd: string | undefined, filePath: string): string {
	if (!cwd) return filePath;
	const rel = relative(cwd, filePath);
	return rel && !rel.startsWith("..") && !isAbsolute(rel) ? rel : filePath;
}

function researchProviderMode(input?: Pick<WebResearchInput, "researchMode" | "type"> | Record<string, unknown>): string {
	const explicitType = typeof input?.type === "string" ? input.type : undefined;
	if (explicitType) return explicitType;
	return input?.researchMode === "lite" ? "deep-lite" : "deep-reasoning";
}

async function writeQueued(path: string, content: string): Promise<void> {
	await withFileMutationQueue(path, async () => {
		await mkdir(dirname(path), { recursive: true });
		await writeFile(path, content, "utf8");
	});
}

export function createWebResearchToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings, name = "web_research") {
	return {
		renderShell: "self" as const,
		name,
		label: "Web Research",
		description: "Run Exa Deep Search research and optionally write a findings report. Requires EXA_API_KEY; does not fall back to general web search.",
		promptSnippet: "Run Exa deep research and write evidence-backed findings reports.",
		promptGuidelines: ["Use web_research for evidence-backed research reports; pass outputPath when the user asks for findings.md or a saved report."],
		parameters: webResearchSchema,
		renderCall(args: WebResearchInput, theme: any, context: any) {
			if (context?.executionStarted && !context?.isPartial) return emptyComponent();
			const meta = [args?.researchMode ?? "standard", args?.type, args?.outputPath ? `→ ${args.outputPath}` : undefined].filter(Boolean).join(" · ");
			return textComponent(webCallText(theme, providerLabel("Web Research", "exa", researchProviderMode(args)), args?.query ?? args?.queryFile ?? "research", meta));
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			if (options?.isPartial) return emptyComponent();
			if (context?.isError) return textComponent(errorSummary(theme, providerLabel("Web Research", "exa", researchProviderMode(context?.args)), firstText(result) || "failed"));
			const details = result?.details ?? {};
			const metadata = details.metadata ?? {};
			const outputPath = details.outputPath as string | undefined;
			const rawOutputPath = details.rawOutputPath as string | undefined;
			const sources = Array.isArray(details.sources) ? details.sources : [];
			const sourceCount = sources.length || undefined;
			const target = context?.args?.query ?? context?.args?.queryFile ?? (outputPath ? displayWebResearchPath(context?.cwd, outputPath) : undefined) ?? "complete";
			const hasSourceTree = Boolean(options?.expanded && sources.length > 0);
			const modeMeta = [metadata.researchMode ?? context?.args?.researchMode ?? "standard", metadata.type ?? context?.args?.type].filter(Boolean).join("/");
			const meta = [modeMeta, sourceCount != null ? `${sourceCount} sources` : undefined, sourceCount && !options?.expanded ? "ctrl+o to expand" : undefined].filter(Boolean).join(" · ");
			const lines = [successSummary(theme, providerLabel("Web Research", "exa", metadata.type ?? researchProviderMode(context?.args)), target, meta)];
			if (outputPath) lines.push(`${tree(theme, rawOutputPath || hasSourceTree ? "├" : "└")}${theme.fg("muted", "report ")}${theme.fg("accent", displayWebResearchPath(context?.cwd, outputPath))}`);
			if (rawOutputPath) lines.push(`${tree(theme, hasSourceTree ? "├" : "└")}${theme.fg("muted", "raw metadata ")}${theme.fg("accent", displayWebResearchPath(context?.cwd, rawOutputPath))}`);
			lines.push(...renderWebResearchSourceTree(sources, theme, Boolean(options?.expanded)));
			return textComponent(lines.join("\n"));
		},
		async execute(_toolCallId: string, params: WebResearchInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const settings = getSettings(ctx.cwd);
			if (!settings.exaDeepResearchEnabled) throw new Error("web_research is disabled by pi-web-tools.exaDeepResearchEnabled.");
			const client = new ExaClient({ apiKey: settings.apiKeys.exa });
			const prepared = await prepareResearchInput(ctx.cwd, params);
			const response = await runExaResearch(client, prepared, signal, settings);
			const format = params.reportFormat ?? "findings";
			let outputPath: string | undefined;
			let rawOutputPath: string | undefined;
			if (params.outputPath) {
				outputPath = resolveOutputPath(ctx.cwd, params.outputPath);
				if (format !== "json") rawOutputPath = params.rawOutputPath ? resolveOutputPath(ctx.cwd, params.rawOutputPath) : defaultRawOutputPath(outputPath);
			} else if (params.rawOutputPath) {
				rawOutputPath = resolveOutputPath(ctx.cwd, params.rawOutputPath);
			}
			const report = format === "json" ? JSON.stringify(response.raw, null, 2) : renderFindingsReport(prepared, response, { rawOutputPath });
			if (outputPath) {
				await writeQueued(outputPath, report);
			}
			if (rawOutputPath) {
				await writeQueued(rawOutputPath, JSON.stringify(buildRawSidecar(response, rawOutputPath), null, 2));
			}
			const metadata = researchDetailsMetadata(response.metadata);
			pi.appendEntry?.("pi-web-tools.web_research", { query: prepared.query, outputPath, rawOutputPath, metadata, sources: response.results.length });
			return {
				content: [{ type: "text", text: outputPath ? `Exa deep research complete. Report: ${outputPath}\nSources: ${response.results.length}${rawOutputPath ? `\nRaw metadata: ${rawOutputPath}` : ""}` : report }],
				details: { outputPath, rawOutputPath, sources: response.results.map((result) => toResultRef(result)), metadata },
			};
		},
	};
}
