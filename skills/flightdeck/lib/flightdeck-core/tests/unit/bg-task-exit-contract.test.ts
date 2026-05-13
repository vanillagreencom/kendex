// Parity test for the pi-bg-task-exit canonical contract (vstack#15
// optional reviewer-structure suggestion).
//
// Asserts the TS constants in src/events/bg-task-exit.ts match the bash
// constants in scripts/lib/daemon-bg-task-events.sh and the tag is
// registered in the daemon's CANONICAL_TAGS allowlist. A drift between
// the two (or between either and the canonical-tag allowlist) is the
// kind of bug that silently breaks the wake routing and only surfaces
// in production.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	BG_TASK_EVENT_CUSTOM_TYPE,
	BG_TASK_EXIT_CLASSIFIER_TAG,
	BG_TASK_EXIT_EVENT_TYPE,
} from "../../src/events/bg-task-exit.ts";
import { isCanonicalTag } from "../../src/daemon/events.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const BG_TASK_EVENTS_SH = resolve(HERE, "../../../../scripts/lib/daemon-bg-task-events.sh");
const DAEMON_BASH = resolve(HERE, "../../../../scripts/flightdeck-daemon.bash");

function extractExportValue(source: string, name: string): string | null {
	const match = source.match(new RegExp(`(?:^|\\n)\\s*export\\s+${name}=\"([^\"]+)\"`));
	return match ? match[1]! : null;
}

describe("pi-bg-task-exit canonical contract parity", () => {
	const bgTaskBash = readFileSync(BG_TASK_EVENTS_SH, "utf8");

	test("BG_TASK_EVENT_CUSTOM_TYPE matches bash export", () => {
		const bashValue = extractExportValue(bgTaskBash, "BG_TASK_EVENT_CUSTOM_TYPE");
		expect(bashValue).toBe(BG_TASK_EVENT_CUSTOM_TYPE);
	});

	test("BG_TASK_EXIT_EVENT_TYPE matches bash export", () => {
		const bashValue = extractExportValue(bgTaskBash, "BG_TASK_EXIT_EVENT_TYPE");
		expect(bashValue).toBe(BG_TASK_EXIT_EVENT_TYPE);
	});

	test("BG_TASK_EXIT_CLASSIFIER_TAG matches bash export", () => {
		const bashValue = extractExportValue(bgTaskBash, "BG_TASK_EXIT_CLASSIFIER_TAG");
		expect(bashValue).toBe(BG_TASK_EXIT_CLASSIFIER_TAG);
	});

	test("classifier tag is canonical in the TS daemon allowlist", () => {
		expect(isCanonicalTag(BG_TASK_EXIT_CLASSIFIER_TAG)).toBe(true);
	});

	test("classifier tag is canonical in the bash daemon allowlist", () => {
		const daemonBash = readFileSync(DAEMON_BASH, "utf8");
		// CANONICAL_TAGS=(\n   tag1\n   tag2\n   ...\n) — match a line
		// containing only the tag (whitespace + optional comment OK).
		const tagLine = new RegExp(`^\\s*${BG_TASK_EXIT_CLASSIFIER_TAG}\\s*(#.*)?$`, "m");
		expect(daemonBash).toMatch(tagLine);
	});
});
