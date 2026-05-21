export interface NormalizedTranscriptEvent {
	event: any;
	name?: string;
	payload: any;
}

export function normalizePiStreamEvent(event: any): NormalizedTranscriptEvent {
	if (!event || typeof event !== "object") return { event, payload: event };
	if (typeof event.event === "string") {
		const data = event.data && typeof event.data === "object" && !Array.isArray(event.data) ? event.data : {};
		const canonical = { ...data, type: event.event };
		return { event: canonical, name: event.event, payload: canonical };
	}
	if (event.event && typeof event.event === "object" && !Array.isArray(event.event)) {
		const canonical = event.event;
		const name = typeof canonical.type === "string" ? canonical.type : undefined;
		return { event: canonical, name, payload: canonical };
	}
	const name = typeof event.type === "string" ? event.type : undefined;
	return { event, name, payload: event };
}

export function normalizeTranscriptRecordEvent(record: any): NormalizedTranscriptEvent {
	if (!record || typeof record !== "object") return { event: record, payload: record };
	if (record.event && typeof record.event === "object") return normalizePiStreamEvent(record.event);
	return normalizePiStreamEvent(record);
}
