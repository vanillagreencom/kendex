import assert from "node:assert/strict";
import test from "node:test";
import { buildHeaders } from "../src/background-image-generation.js";

const token = `header.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-1" } })).toString("base64")}.signature`;
const rows: Array<{ name: string; model: Record<string, string>; overrides: Record<string, string | null>; expected: Record<string, string | null> }> = [
	{ name: "nullable overrides", model: { "x-inherited": "keep", "x-dropped": "stale" }, overrides: { "x-dropped": null, "x-added": "value" }, expected: { "x-dropped": null, "x-inherited": "keep", "x-added": "value" } },
	{ name: "pinned request headers", model: {}, overrides: { Authorization: null, "chatgpt-account-id": null, originator: null, "content-type": null }, expected: { authorization: `Bearer ${token}`, "chatgpt-account-id": "acct-1", originator: "pi", "content-type": "application/json" } },
];
for (const row of rows) {
	test(`image request headers: ${row.name}`, () => {
		const headers = buildHeaders({ headers: row.model } as never, token, row.overrides);
		assert.deepEqual(Object.fromEntries(Object.keys(row.expected).map((key) => [key, headers.get(key)])), row.expected);
	});
}
