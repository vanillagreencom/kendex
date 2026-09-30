import { describe, expect, spyOn, test } from "bun:test";
import * as fs from "node:fs";
import { BridgeHistory } from "../event-history.js";
import { defaultLimits, makeEnvelope, spillPath, warnings, useHistoryFixture, pushRaw, settle } from "./lib/history-fixture.ts";

useHistoryFixture();

const payload = { delta: "z".repeat(150) };
const envelope = () => ({ ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 });

describe("sidecar I/O failures", () => {
	for (const row of [
		{ name: "read", mode: "r", code: "EIO", suffix: "" },
		{ name: "write", mode: "w", code: "EROFS", suffix: ".compact" },
	]) {
		test(`compaction ${row.name} failure reports its own cause and preserves live data`, async () => {
			const limits = { ...defaultLimits, historyLimit: 2, maxRawSpillBytes: 4096 };
			const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
			for (let i = 0; i < 3; i++) { pushRaw(history, envelope(), payload); await settle(history); }
			limits.maxRawSpillBytes = fs.statSync(spillPath).size;
			const open = fs.promises.open.bind(fs.promises);
			let calls = 0;
			const spy = spyOn(fs.promises, "open").mockImplementation(async (...args) => {
				if (args[1] === row.mode) {
					calls++;
					throw Object.assign(new Error(`refused ${row.name}`), { code: row.code, path: String(args[0]) });
				}
				return open(...args);
			});
			const refused = pushRaw(history, envelope(), payload);
			try { await settle(history); } finally { spy.mockRestore(); }
			expect(calls).toBe(1);
			expect(refused.rawEventRef).toBeUndefined();
			expect(refused.rawError?.split("\n")[0]).toBe(`error_code=${row.code} path=${spillPath}${row.suffix}`);
			expect(warnings.map((entry) => entry.where)).toEqual(["spill"]);
			const response = await history.buildResponse({ limit: 2, maxBytes: 4096, raw: true });
			expect(response.events[0]?.rawRestored).toBe(true);
			expect(response.events[0]?.data).toEqual(payload);
		});
	}

	test("compaction unlink failure reports the file that survived", async () => {
		const limits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 4096 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		pushRaw(history, envelope(), payload);
		await settle(history);
		limits.maxRawSpillBytes = Math.ceil(fs.statSync(spillPath).size * 1.5);
		const unlink = fs.promises.unlink.bind(fs.promises);
		const spy = spyOn(fs.promises, "unlink").mockImplementation(async (...args) => {
			if (args[0] === spillPath) throw Object.assign(new Error("refused unlink"), { code: "EPERM", path: spillPath });
			return unlink(...args);
		});
		const refused = pushRaw(history, envelope(), payload);
		try { await settle(history); } finally { spy.mockRestore(); }
		expect(refused.rawEventRef).toBeUndefined();
		expect(refused.rawError?.split("\n")[0]).toBe(`error_code=EPERM path=${spillPath}`);
		expect(warnings.map((entry) => entry.where)).toEqual(["spill"]);
	});

	test("append failure releases its reservation so a later event can spill", async () => {
		const limits = { ...defaultLimits, maxRawSpillBytes: 400 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const spy = spyOn(fs.promises, "appendFile").mockRejectedValueOnce(Object.assign(new Error("append refused"), { code: "EIO", path: spillPath }));
		const refused = pushRaw(history, envelope(), payload);
		try { await settle(history); } finally { spy.mockRestore(); }
		expect(refused.rawError?.split("\n")[0]).toBe(`error_code=EIO path=${spillPath}`);
		const next = pushRaw(history, envelope(), payload);
		await settle(history);
		expect(next.rawError).toBeUndefined();
		expect(next.rawEventRef).toBe("2");
		expect(history.rawSpillBytes).toBe(fs.statSync(spillPath).size);
	});
});
