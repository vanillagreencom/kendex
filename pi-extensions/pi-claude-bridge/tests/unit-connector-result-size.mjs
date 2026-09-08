import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { connectorResultByteSize } from "../src/connector-audit.ts";

describe("connector result byte size", () => {
	it("measures serializable payloads and omits unmeasurable values", () => {
		const circular = {};
		circular.self = circular;
		const rows = [["ASCII", "abc", 3], ["UTF-8", "é☃", 5], ["missing", undefined, undefined], ["null", null, undefined], ["circular", circular, undefined]];
		for (const [name, payload, expected] of rows) {
			assert.equal(connectorResultByteSize(payload), expected, name);
		}
	});

	it("measures a block array as its payload, not as a block count", () => {
		const payload = "x".repeat(300);
		const size = connectorResultByteSize([{ type: "text", text: payload }]);
		assert.ok(size > 300, `expected the payload to be measured, got ${size}`);
	});
});
