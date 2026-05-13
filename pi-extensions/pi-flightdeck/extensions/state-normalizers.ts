// Defensive shape normalizers for `readMasterState`.
//
// A corrupt or partially-written archive (crash mid-archive, hand-edit
// gone wrong, manual JSON tweak) should render as empty-but-stable, not
// as a render-time exception that crashes the popup. These helpers
// filter the two nested fields the renderers iterate without guarding:
// `conflict_graph.edges` and per-issue `decisions_log`.

import type { IssueRecord } from "./state.js";

export function normalizeConflictGraph(raw: unknown): { edges: Array<[string, string]>; computed_at: string | null } {
	const empty = { computed_at: null, edges: [] as Array<[string, string]> };
	if (!raw || typeof raw !== "object" || Array.isArray(raw)) return empty;
	const obj = raw as { edges?: unknown; computed_at?: unknown };
	const edges: Array<[string, string]> = [];
	if (Array.isArray(obj.edges)) {
		for (const edge of obj.edges) {
			if (Array.isArray(edge) && edge.length >= 2 && typeof edge[0] === "string" && typeof edge[1] === "string") {
				edges.push([edge[0], edge[1]]);
			}
		}
	}
	const computed_at = typeof obj.computed_at === "string" ? obj.computed_at : null;
	return { computed_at, edges };
}

export function normalizeDecisionsLog(raw: unknown): IssueRecord["decisions_log"] {
	if (!Array.isArray(raw)) return [];
	const out: NonNullable<IssueRecord["decisions_log"]> = [];
	for (const entry of raw) {
		if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
		const e = entry as { ts?: unknown; prompt_tag?: unknown; answer?: unknown };
		if (typeof e.ts !== "string" || typeof e.prompt_tag !== "string" || typeof e.answer !== "string") continue;
		out.push({ answer: e.answer, prompt_tag: e.prompt_tag, ts: e.ts });
	}
	return out;
}
