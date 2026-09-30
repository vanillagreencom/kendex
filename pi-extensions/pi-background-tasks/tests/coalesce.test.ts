import { expect, test } from "bun:test";
import { createCoalescedCall } from "../extensions/coalesce.js";

type Step = "request" | "cancel" | "fire";

test("coalesced call runs once per window", () => {
	const rows: { name: string; steps: Step[]; expected: { runs: number; armed: number; cleared: number; pending: boolean } }[] = [
		{ name: "requests inside one window share one run", steps: ["request", "request", "request", "fire"], expected: { runs: 1, armed: 1, cleared: 0, pending: false } },
		{ name: "a request after the run arms a new window", steps: ["request", "fire", "request", "fire"], expected: { runs: 2, armed: 2, cleared: 0, pending: false } },
		{ name: "cancel drops the pending run", steps: ["request", "cancel"], expected: { runs: 0, armed: 1, cleared: 1, pending: false } },
		{ name: "cancel with nothing pending clears nothing", steps: ["cancel"], expected: { runs: 0, armed: 0, cleared: 0, pending: false } },
		{ name: "a request without its window elapsing stays pending", steps: ["request"], expected: { runs: 0, armed: 1, cleared: 0, pending: true } },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "coalesced call table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		let runs = 0;
		let armed = 0;
		let cleared = 0;
		let pending: (() => void) | null = null;
		const call = createCoalescedCall(() => { runs++; }, 100, {
			setTimer(cb, ms) {
				if (ms !== 100) throw new Error(`coalesce_test.delay=${ms}`);
				armed++;
				pending = cb;
				return { unref() {} } as unknown as NodeJS.Timeout;
			},
			clearTimer() { cleared++; pending = null; },
		});
		for (const step of row.steps) {
			if (step === "request") call.request();
			else if (step === "cancel") call.cancel();
			else {
				const fire = pending;
				if (!fire) throw new Error("coalesce_test.fire=no-pending-timer");
				pending = null;
				fire();
			}
		}
		expect({ runs, armed, cleared, pending: pending !== null }, row.name).toStrictEqual(row.expected);
	}
});
