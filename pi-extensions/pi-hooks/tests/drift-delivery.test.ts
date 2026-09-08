import { expect, test } from "bun:test";
import { deliverDrift, type DriftCheckResult } from "../extensions/drift-check.ts";

for (const row of [
	{ name: "error throw", error: new Error("spawn-failed"), first: 'drift-error="spawn-failed"' },
	{ name: "non-Error throw", error: "failed", first: 'drift-error="failed"' },
	{ name: "clean", result: { kind: "clean" }, first: undefined },
	{ name: "drift", result: { kind: "drift", report: "outdated=orch" }, first: "outdated=orch" },
	{ name: "stale channel", error: new Error("failed"), first: 'drift-error="failed"', throws: true },
] as const) {
	test(`drift delivery: ${row.name}`, async () => {
		const sent: string[] = [];
		const check = "error" in row ? Promise.reject(row.error) : Promise.resolve(row.result as DriftCheckResult);
		await expect(deliverDrift(check, (message) => {
			sent.push(message);
			if ("throws" in row) throw new Error("channel-gone");
		})).resolves.toBeUndefined();
		expect(sent.map((message) => message.split("\n")[0])).toEqual(row.first === undefined ? [] : [row.first]);
		if ("result" in row && row.result.kind === "drift") expect(sent[0]?.endsWith(row.result.report)).toBe(true);
	});
}
