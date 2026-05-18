// Pi bridge-state classifier for tracked-entry lifecycle.
//
// The buffer-text classifier in classify.ts works on tmux capture output
// (a string). Pi panes expose a richer signal through pi-bridge: the
// session's `isIdle` flag and `hasPendingMessages` indicator. For generic
// Pi entries (adhoc/workflow) — where master has no issue-mode prompt tags
// to read — reaching `isIdle: true && hasPendingMessages: false` is the
// canonical terminal signal, and session-watch advances waiting → complete
// on it.
//
// Issue-mode and other-harness entries keep their existing classifier
// path (buffer text + post-footer rules), so the gating below MUST
// require a generic kind (adhoc/workflow) AND harness == "pi".

export interface PiBridgeStateLike {
	isIdle?: unknown;
	hasPendingMessages?: unknown;
	[key: string]: unknown;
}

export type PiBridgeStateTag = "terminal-state-reached" | "idle" | "rendering";

export interface PiBridgeStateClassification {
	tag: PiBridgeStateTag;
	matched: string;
}

export interface PiBridgeStateOptions {
	entryKind: string;
	entryHarness: string;
}

function normalizeKind(value: string | undefined): string {
	return (value ?? "").trim().toLowerCase();
}

function isGenericTerminalKind(kind: string): boolean {
	return kind === "adhoc" || kind === "workflow";
}

function isStateRecord(value: unknown): value is PiBridgeStateLike {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function normalizeBridgeState(state: PiBridgeStateLike): PiBridgeStateLike {
	return isStateRecord(state.data) ? state.data : state;
}

export function classifyPiBridgeState(
	state: PiBridgeStateLike | null | undefined,
	options: PiBridgeStateOptions,
): PiBridgeStateClassification {
	const kind = normalizeKind(options.entryKind);
	const harness = normalizeKind(options.entryHarness);
	if (!isStateRecord(state)) {
		return { tag: "rendering", matched: "no-bridge-state" };
	}
	const normalized = normalizeBridgeState(state);
	const isIdle = normalized.isIdle === true;
	const hasPendingMessages = normalized.hasPendingMessages === true;
	if (!isIdle) return { tag: "rendering", matched: "bridge-state busy" };
	if (hasPendingMessages) return { tag: "idle", matched: "bridge-state idle with pending messages" };
	if (isGenericTerminalKind(kind) && harness === "pi") {
		return { tag: "terminal-state-reached", matched: `${kind} pi idle, no pending messages` };
	}
	return { tag: "idle", matched: `bridge-state idle (kind=${kind || "unknown"} harness=${harness || "unknown"})` };
}
