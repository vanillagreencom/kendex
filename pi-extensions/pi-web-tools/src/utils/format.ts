export function truncateText(value: string, maxChars = 12000): { text: string; truncated: boolean } {
	if (value.length <= maxChars) return { text: value, truncated: false };
	return { text: `${value.slice(0, maxChars)}\n\n[truncated ${value.length - maxChars} characters]`, truncated: true };
}

export function jsonText(value: unknown): string {
	return JSON.stringify(value, null, 2);
}

export function sourceList(results: Array<{ title?: string; url?: string; contentId?: string }>): string {
	return results.map((result, index) => {
		const bits = [result.url, result.contentId ? `content id ${result.contentId}` : undefined].filter(Boolean).join(" — ");
		return `${index + 1}. ${result.title || result.url || "Untitled"}${bits ? ` — ${bits}` : ""}`;
	}).join("\n");
}

/** A provider result as a tool's details carry it: what `sourceList` and the
 *  result renderers draw, and no page text. Pi keeps details in the session
 *  record, so text there is a second copy beside the content store; a tool
 *  that keeps the text names it by `contentId`. */
export interface ResultRef {
	title?: string;
	url?: string;
	publishedDate?: string;
	contentId?: string;
}

export function toResultRef(result: { title?: string; url?: string; publishedDate?: string }, contentId?: string): ResultRef {
	const ref: ResultRef = {};
	if (result.title !== undefined) ref.title = result.title;
	if (result.url !== undefined) ref.url = result.url;
	if (result.publishedDate !== undefined) ref.publishedDate = result.publishedDate;
	if (contentId !== undefined) ref.contentId = contentId;
	return ref;
}
