import { describe, expect, test } from "bun:test";
import { extractRetryAfterMs } from "../extensions/subagent/rate-limit-reset.js";

// The whole contract in one table. Seconds keys scale by 1000, `_ms` keys do
// not, strings go through Number() so exponent and hex forms are accepted, and
// anything that is not finite and positive is no answer rather than zero.
describe("extractRetryAfterMs", () => {
	const cases: Array<[string, unknown, number | null]> = [
		["seconds key scales to ms", { retry_after: 5 }, 5_000],
		["camel seconds key scales to ms", { retryAfter: 5 }, 5_000],
		["ms key passes through", { retry_after_ms: 250 }, 250],
		["camel ms key passes through", { retryAfterMs: 1_500 }, 1_500],
		["ms key wins over the seconds key", { retry_after: 5, retry_after_ms: 250 }, 250],
		["fractional seconds floor to whole ms", { retry_after: 1.5 }, 1_500],
		["exponent string", { retry_after: "1e3" }, 1_000_000],
		["hex string", { retry_after: "0x10" }, 16_000],
		["padded string", { retry_after: " 5 " }, 5_000],
		["zero is no answer", { retry_after: 0 }, null],
		["zero string is no answer", { retry_after: "0" }, null],
		["negative is no answer", { retry_after: -5 }, null],
		["non-numeric string is no answer", { retry_after: "soon" }, null],
		["empty string is no answer", { retry_after: "" }, null],
		["absent is no answer", { message: {} }, null],
		["found at any depth", { message: { error: { retry_after_ms: 42 } } }, 42],
	];
	for (const [label, event, expected] of cases) {
		test(label, () => {
			expect(extractRetryAfterMs(event)).toBe(expected);
		});
	}
});
