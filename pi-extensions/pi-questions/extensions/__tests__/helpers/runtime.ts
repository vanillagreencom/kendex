import { mock } from "bun:test";

/** The dependency-free test carrier implements only the Pi UI calls a case needs. */
export function mockQuestionRuntime(tui: Record<string, unknown> = {}): void {
	const unexpected = () => { throw new Error("Unexpected UI or output operation"); };
	mock.module("@earendil-works/pi-coding-agent", () => ({
		DEFAULT_MAX_BYTES: 1024,
		DEFAULT_MAX_LINES: 100,
		formatSize: String,
		truncateHead: unexpected,
		withFileMutationQueue: unexpected,
	}));
	mock.module("@earendil-works/pi-tui", () => ({
		Input: class { constructor() { unexpected(); } },
		matchesKey: unexpected,
		truncateToWidth: unexpected,
		visibleWidth: unexpected,
		wrapTextWithAnsi: unexpected,
		...tui,
	}));
}
