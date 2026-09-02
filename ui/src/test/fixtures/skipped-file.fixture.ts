// A leak with no case to hang it on: started at module scope, with the
// file's only case skipped, so no hook runs for it at all. Vitest catches
// this one itself, and the control asserts it is red under both configs —
// the closing window must not cost the report vitest already makes.
import { expect, test } from "vitest";

Promise.reject(new Error("skipped file fixture"));

test.skip("never runs", () => {
  expect(1).toBe(1);
});
