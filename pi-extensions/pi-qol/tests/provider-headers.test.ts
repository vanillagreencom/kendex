import { expect, test } from "bun:test";
import { headerRecord } from "../extensions/qol/session-rename.ts";

// Pi resolves provider headers as `ProviderHeaders` (`Record<string, string | null>`).
// `null` is a header-deletion marker pi-ai acts on, so forwarding must not drop it.
const headerRows = [
	{ name: "null deletion marker", input: { "x-keep": "value", "x-delete": null }, expected: { "x-keep": "value", "x-delete": null } },
	{ name: "empty header value", input: { "x-empty": "", "x-keep": "value" }, expected: { "x-keep": "value" } },
	{ name: "numeric header value", input: { "x-number": 7, "x-keep": "value" }, expected: { "x-keep": "value" } },
	{ name: "absent headers", input: undefined, expected: undefined },
	{ name: "array headers", input: ["x-keep", "value"], expected: undefined },
	{ name: "empty header record", input: {}, expected: undefined },
];

if (headerRows.length === 0) throw new Error("Provider header table is empty");

for (const row of headerRows) {
	test(row.name, () => {
		expect.hasAssertions();
		expect(headerRecord(row.input)).toEqual(row.expected);
	});
}
