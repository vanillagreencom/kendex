import { expect, test } from "bun:test";
import { headerRecord } from "../extensions/qol/session-rename.ts";

// Pi resolves provider headers as `ProviderHeaders` (`Record<string, string | null>`).
// `null` is a header-deletion marker pi-ai acts on, so forwarding must not drop it.
test("headerRecord preserves null header-deletion markers", () => {
	expect(headerRecord({ "x-keep": "value", "x-delete": null })).toEqual({ "x-keep": "value", "x-delete": null });
});

test("headerRecord still drops empty and non-string header values", () => {
	expect(headerRecord({ "x-empty": "", "x-number": 7, "x-keep": "value" })).toEqual({ "x-keep": "value" });
});

test("headerRecord returns undefined for absent or non-object headers", () => {
	expect(headerRecord(undefined)).toBeUndefined();
	expect(headerRecord(["x-keep", "value"])).toBeUndefined();
	expect(headerRecord({})).toBeUndefined();
});
