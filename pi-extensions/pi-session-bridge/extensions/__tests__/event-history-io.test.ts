/**
 * Sidecar I/O failure paths.
 *
 * Every root-proof way to make a real file refuse a write also makes the next
 * append refuse it, which reports the same code without ever entering the
 * rewrite. These cases stub the three `node:fs` calls the rewrite uses instead,
 * so each failure is reached on its own. Module stubbing is process-wide in
 * Bun, so it lives in this file alone; the stubs delegate to the real calls
 * unless a case arms them.
 */
import { beforeEach, describe, expect, mock, test } from "bun:test";
import * as realFs from "node:fs";

import { defaultLimits, makeEnvelope, spillPath, warnings, useHistoryFixture } from "./lib/history-fixture.ts";

interface FailingCall {
	code: string;
	calls: number;
	armed: boolean;
}

const failing: Record<"writeFileSync" | "openSync" | "unlinkSync", FailingCall> = {
	writeFileSync: { code: "EROFS", calls: 0, armed: false },
	openSync: { code: "EIO", calls: 0, armed: false },
	unlinkSync: { code: "EPERM", calls: 0, armed: false },
};

function wrap<K extends keyof typeof failing>(name: K) {
	const real = realFs[name] as (...args: unknown[]) => unknown;
	return (...args: unknown[]): unknown => {
		const state = failing[name];
		state.calls++;
		if (state.armed) throw Object.assign(new Error(`stubbed ${name}`), { code: state.code, path: String(args[0]) });
		return real(...args);
	};
}

mock.module("node:fs", () => ({
	...realFs,
	default: realFs,
	writeFileSync: wrap("writeFileSync"),
	openSync: wrap("openSync"),
	unlinkSync: wrap("unlinkSync"),
}));

const { BridgeHistory } = await import("../event-history.js");

useHistoryFixture();

beforeEach(() => {
	for (const state of Object.values(failing)) {
		state.calls = 0;
		state.armed = false;
	}
});

describe("sidecar I/O failures", () => {
	const spillPayload = { delta: "z".repeat(150) };
	const spillEnvelope = () => ({ ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 });

	// The rewrite is the only caller of writeFileSync and unlinkSync during a
	// push, and the only caller of openSync, so a call count of one proves the
	// failure was reached inside it and not by a later append.
	for (const row of [
		{ name: "the rewrite cannot write", call: "writeFileSync" as const },
		{ name: "the rewrite cannot read", call: "openSync" as const },
	]) {
		test(`${row.name}, the spill reports that call's error`, () => {
			const limits = { ...defaultLimits, historyLimit: 2, maxRawSpillBytes: 4 * 1024 };
			const history = new BridgeHistory(spillPath, () => limits, (where: string, error: unknown) => warnings.push({ where, error }));
			const push = () => history.push(spillEnvelope(), spillPayload);

			push();
			push();
			// The third evicts the first, leaving its bytes orphaned in the file.
			push();
			const lineBytes = realFs.statSync(spillPath).size / 3;

			// Room for the two live slots plus the incoming line, but not for
			// the orphan as well, so the next spill must rewrite first.
			limits.maxRawSpillBytes = Math.ceil(lineBytes * 3);
			failing[row.call].armed = true;
			const refused = push();

			expect(failing[row.call].calls).toBe(1);
			expect(refused.rawEventRef).toBeUndefined();
			expect(refused.rawError?.split("\n")[0]).toBe(`error_code=${failing[row.call].code} path=${spillPath}`);
			// A swallowed rewrite reports here and hands the caller a budget
			// refusal instead; the propagated one reports under the spill.
			expect(warnings.some((entry) => entry.where === "compactSidecar")).toBe(false);
			expect(warnings.some((entry) => entry.where === "spill")).toBe(true);
		});
	}

	test("a reclaim that cannot remove the emptied sidecar reports the unlink error", () => {
		const limits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 4 * 1024 };
		const history = new BridgeHistory(spillPath, () => limits, (where: string, error: unknown) => warnings.push({ where, error }));
		const push = () => history.push(spillEnvelope(), spillPayload);

		const first = push();
		expect(first.rawEventRef).toBe("1");
		const lineBytes = realFs.statSync(spillPath).size;

		// The next push evicts the only live envelope, so the reclaim keeps no
		// slot and removes the file outright.
		limits.maxRawSpillBytes = Math.ceil(lineBytes * 1.5);
		failing.unlinkSync.armed = true;
		const refused = push();

		expect(failing.unlinkSync.calls).toBe(1);
		expect(refused.rawEventRef).toBeUndefined();
		expect(refused.rawError?.split("\n")[0]).toBe(`error_code=EPERM path=${spillPath}`);
		expect(warnings.some((entry) => entry.where === "compactSidecar")).toBe(false);
	});
});
