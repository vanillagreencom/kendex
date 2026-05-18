// Regression coverage for vstack#61/#117: the Pi subscriber must emit a
// wake-event row with classifier_tag=terminal-state-reached when a generic
// Pi pane (adhoc/workflow) transitions to isIdle=true with no pending messages.
// Issue-mode panes keep their existing classifier path.
//
// The bash mirror lives in scripts/lib/subscribers.bash::pi_subscriber_loop.
// The TS function below is the canonical source of truth; the bash check
// must stay in lock step per the CLAUDE.md parity rule.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	ADHOC_PI_IDLE_HASH_TAG,
	decidePiAdhocWake,
	piAdhocWakeHash,
} from "../../src/daemon/pi-adhoc-wake.ts";
import { createHash } from "node:crypto";

const HERE = dirname(fileURLToPath(import.meta.url));
const BASH_SUBSCRIBERS = resolve(HERE, "../../../../scripts/lib/subscribers.bash");

const FIXED_NOW = () => new Date("2026-05-15T12:00:00.000Z");

const TEXT_HASH = "abcd1234ef56";

describe("decidePiAdhocWake (vstack#61)", () => {
	test("adhoc pi idle transition with no pending messages -> wake row terminal-state-reached", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%10",
			entryKind: "adhoc",
			entryHarness: "pi",
			bridgeState: { data: { isIdle: true, hasPendingMessages: false } },
			assistantTextHash: TEXT_HASH,
			now: FIXED_NOW,
		});
		expect(outcome.emit).toBe(true);
		if (!outcome.emit) throw new Error("expected emit=true");
		expect(outcome.row.classifier_tag).toBe("terminal-state-reached");
		expect(outcome.row.harness).toBe("pi");
		expect(outcome.row.pane_id).toBe("%10");
		expect(outcome.row.ts).toBe("2026-05-15T12:00:00.000Z");
		expect(outcome.row.hash).toMatch(/^[0-9a-f]{12}$/);
		expect(outcome.row.last_assistant_text).toBe("");
	});

	test("workflow pi idle transition with no pending messages -> wake row terminal-state-reached", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%11",
			entryKind: "workflow",
			entryHarness: "pi",
			bridgeState: { isIdle: true, hasPendingMessages: false },
			assistantTextHash: TEXT_HASH,
			now: FIXED_NOW,
		});
		expect(outcome.emit).toBe(true);
		if (!outcome.emit) throw new Error("expected emit=true");
		expect(outcome.row.classifier_tag).toBe("terminal-state-reached");
		expect(outcome.row.pane_id).toBe("%11");
	});

	test("issue-kind pi idle transition -> no wake (existing classifier path handles it)", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%10",
			entryKind: "issue",
			entryHarness: "pi",
			bridgeState: { isIdle: true, hasPendingMessages: false },
			assistantTextHash: TEXT_HASH,
		});
		expect(outcome.emit).toBe(false);
	});

	test("adhoc claude idle transition -> no wake (Pi-only)", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%10",
			entryKind: "adhoc",
			entryHarness: "claude",
			bridgeState: { isIdle: true, hasPendingMessages: false },
			assistantTextHash: TEXT_HASH,
		});
		expect(outcome.emit).toBe(false);
	});

	test("adhoc pi with isIdle=true but hasPendingMessages=true -> no wake (still has work)", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%10",
			entryKind: "adhoc",
			entryHarness: "pi",
			bridgeState: { isIdle: true, hasPendingMessages: true },
			assistantTextHash: TEXT_HASH,
		});
		expect(outcome.emit).toBe(false);
	});

	test("adhoc pi but pane busy (isIdle=false) -> no wake (rendering)", () => {
		const outcome = decidePiAdhocWake({
			paneId: "%10",
			entryKind: "adhoc",
			entryHarness: "pi",
			bridgeState: { isIdle: false, hasPendingMessages: false },
			assistantTextHash: TEXT_HASH,
		});
		expect(outcome.emit).toBe(false);
	});

	test("missing pane id -> no wake", () => {
		const outcome = decidePiAdhocWake({
			paneId: "",
			entryKind: "adhoc",
			entryHarness: "pi",
			bridgeState: { isIdle: true, hasPendingMessages: false },
			assistantTextHash: TEXT_HASH,
		});
		expect(outcome.emit).toBe(false);
		if (outcome.emit) throw new Error("expected emit=false");
		expect(outcome.reason).toBe("missing-pane-id");
	});

	test("missing/empty bridge state -> no wake", () => {
		expect(decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: null, assistantTextHash: TEXT_HASH }).emit).toBe(false);
		expect(decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: {}, assistantTextHash: TEXT_HASH }).emit).toBe(false);
	});

	test("wake row hash differs between two distinct pane ids (same assistant text)", () => {
		const a = decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: TEXT_HASH, now: FIXED_NOW });
		const b = decidePiAdhocWake({ paneId: "%20", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: TEXT_HASH, now: FIXED_NOW });
		expect(a.emit && b.emit).toBe(true);
		if (a.emit && b.emit) expect(a.row.hash).not.toBe(b.row.hash);
	});

	test("wake row hash differs between two distinct assistant text hashes (same pane)", () => {
		const a = decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: "hash-A", now: FIXED_NOW });
		const b = decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: "hash-B", now: FIXED_NOW });
		expect(a.emit && b.emit).toBe(true);
		if (a.emit && b.emit) expect(a.row.hash).not.toBe(b.row.hash);
	});

	test("wake row hash is stable across now() variations (parity with bash: ts not in hash)", () => {
		const a = decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: TEXT_HASH, now: () => new Date("2026-05-15T12:00:00.000Z") });
		const b = decidePiAdhocWake({ paneId: "%10", entryKind: "adhoc", entryHarness: "pi", bridgeState: { isIdle: true, hasPendingMessages: false }, assistantTextHash: TEXT_HASH, now: () => new Date("2027-01-01T00:00:00.000Z") });
		expect(a.emit && b.emit).toBe(true);
		if (a.emit && b.emit) expect(a.row.hash).toBe(b.row.hash);
	});
});

describe("piAdhocWakeHash bash parity (vstack#61 B5)", () => {
	test("TS computes the same hash bash would produce: sha256(<pane>|adhoc-pi-idle|<text-hash>) prefix 12", () => {
		const paneId = "%42";
		const textHash = "deadbeefcafe";
		const manual = createHash("sha256").update(`${paneId}|${ADHOC_PI_IDLE_HASH_TAG}|${textHash}`).digest("hex").slice(0, 12);
		expect(piAdhocWakeHash(paneId, textHash)).toBe(manual);
	});

	test("ADHOC_PI_IDLE_HASH_TAG matches the literal in subscribers.bash", () => {
		expect(ADHOC_PI_IDLE_HASH_TAG).toBe("adhoc-pi-idle");
	});
});

describe("bash subscribers.bash adhoc-pi mirror (vstack#61)", () => {
	const body = readFileSync(BASH_SUBSCRIBERS, "utf8");

	test("pi_subscriber_loop has the FD_ENTRY_KIND generic adhoc/workflow gate", () => {
		expect(body).toContain("FD_ENTRY_KIND");
		expect(body).toContain("== \"adhoc\"");
		expect(body).toContain("== \"workflow\"");
	});

	test("pi_subscriber_loop checks isIdle and hasPendingMessages from pi-bridge state", () => {
		expect(body).toMatch(/\.isIdle == true.*hasPendingMessages/);
	});

	test("pi_subscriber_loop emits classifier_tag=terminal-state-reached for the adhoc case", () => {
		expect(body).toMatch(/--arg tag "terminal-state-reached"/);
	});

	test("bash mirror references the canonical TS source", () => {
		expect(body).toContain("pi-adhoc-wake.ts");
		expect(body).toContain("pi-bridge-state.ts");
	});

	test("bash mirror has a last_terminal_hash dedup variable", () => {
		expect(body).toContain("last_terminal_hash");
	});

	test("bash mirror logs terminal-state errors instead of dropping silently", () => {
		expect(body).toContain("[pi-sub-terminal-state-error]");
		expect(body).toContain("reason=state_rc");
		expect(body).toContain("reason=state_json");
		expect(body).toContain("reason=append_failed");
	});

	test("bash mirror accepts pi-bridge state wrappers", () => {
		expect(body).toContain(".data // .");
	});
});
