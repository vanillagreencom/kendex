import { PRE_FOOTER_RULES, POST_FOOTER_RULES, FOOTER_GATE, IDLE_CURSOR, ISSUE_ONLY_TAGS } from "./rules.ts";

export interface ClassifyResult {
	tag: string;
	matched: string;
}

export interface ClassifyOptions {
	noFooterGate?: boolean;
	entryKind?: string;
	entryKindUnknown?: boolean;
	allowMissingKind?: boolean;
}

// Mirrors scripts/prompt-classify control flow exactly:
//   1. pre-footer sentinels (awaiting-direction)
//   2. footer gate (unless disabled) — returns rendering or idle on miss
//   3. post-footer specific sentinels (priority order, first match wins)
//   4. fallback: idle
export function classifyBuffer(buf: string, options: ClassifyOptions = {}): ClassifyResult {
	for (const rule of PRE_FOOTER_RULES) {
		if (rule.pattern.test(buf)) return applyDomainGuard({ matched: rule.matched, tag: rule.tag }, options.entryKind, options.entryKindUnknown, options.allowMissingKind);
	}

	if (!options.noFooterGate) {
		if (!FOOTER_GATE.test(buf)) {
			if (IDLE_CURSOR.test(buf)) return { matched: "", tag: "idle" };
			return { matched: "", tag: "rendering" };
		}
	}

	for (const rule of POST_FOOTER_RULES) {
		if (rule.pattern.test(buf)) return applyDomainGuard({ matched: rule.matched, tag: rule.tag }, options.entryKind, options.entryKindUnknown, options.allowMissingKind);
	}

	return { matched: "", tag: "idle" };
}

export function applyDomainGuard(result: ClassifyResult, entryKind?: string, entryKindUnknown = false, allowMissingKind = false): ClassifyResult {
	const kind = entryKindUnknown ? "unknown" : entryKind?.trim().toLowerCase();
	if (!ISSUE_ONLY_TAGS.has(result.tag)) return result;
	if (kind === "issue" || (!kind && allowMissingKind)) return result;
	if (!kind) {
		return {
			matched: `issue-only ${result.tag} without entry kind`,
			tag: "domain-mismatch",
		};
	}
	return {
		matched: `issue-only ${result.tag} on ${kind} entry`,
		tag: "domain-mismatch",
	};
}
