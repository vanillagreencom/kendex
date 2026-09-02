import { expect, test } from "bun:test";
import { extractRetryAfterMs } from "../extensions/subagent/rate-limit-reset.js";

// The predicate this change swapped in: a numeric string goes through Number()
// and has to be finite and positive, where the replaced one matched a digits
// regex and let "0" through as a zero-length wait.
test("extractRetryAfterMs reads a numeric string and rejects a non-positive one", () => {
	expect(extractRetryAfterMs({ retry_after: " 5 " })).toBe(5_000);
	expect(extractRetryAfterMs({ retry_after: "0" })).toBeNull();
});
