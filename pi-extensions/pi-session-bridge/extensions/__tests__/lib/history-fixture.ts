import { afterEach, beforeEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { HistoryEnvelope, HistoryLimits } from "../../event-history.js";

export const defaultLimits: HistoryLimits = {
	historyLimit: 500,
	maxHistoryBytes: 4 * 1024 * 1024,
	maxRawSpillBytes: 16 * 1024 * 1024,
	spillEnabled: true,
};

let monotonicCounter = 0;

export function makeEnvelope(event: string, dataBytes = 32): HistoryEnvelope {
	const filler = "x".repeat(dataBytes);
	const idx = monotonicCounter++;
	const ms = String(idx % 1000).padStart(3, "0");
	const seconds = String(Math.floor(idx / 1000) % 60).padStart(2, "0");
	return {
		type: "event",
		event,
		timestamp: `2026-05-21T00:00:${seconds}.${ms}Z`,
		data: { filler, idx },
	};
}

export let dir = "";
export let spillPath = "";
export let warnings: Array<{ where: string; error: unknown }> = [];

export function useHistoryFixture(): void {
beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "bridge-history-"));
	spillPath = join(dir, "raw", `${process.pid}.jsonl`);
	warnings = [];
	monotonicCounter = 0;
});

afterEach(() => {
	rmSync(dir, { recursive: true, force: true });
});

}
