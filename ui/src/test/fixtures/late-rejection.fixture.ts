// The shape the closing window exists for: a promise rejecting after the
// file's last case returned. Not named `*.test.*`, so only the two configs
// beside it pick these up — never the suite.
//
// The delay has to clear worker teardown, measured under 5ms, and stay well
// under the window the guarded control sets. Move it and check both.
import { expect, test } from "vitest";

test("returns before the promise it started rejects", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("late rejection fixture")), 250);
  });
  expect(1).toBe(1);
});
