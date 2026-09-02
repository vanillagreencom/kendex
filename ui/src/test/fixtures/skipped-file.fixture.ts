// A leak with no case to hang it on: the rejection is started at module
// scope and the file's only case is skipped, so nothing this repo registers
// — no hook, no drain — ever runs for it. Vitest catches this one itself,
// and the control asserts it is red under both configs: the closing window
// must not cost the report vitest already makes.
import { expect, test } from "vitest";

Promise.reject(new Error("skipped file fixture"));

test.skip("never runs", () => {
  expect(1).toBe(1);
});
