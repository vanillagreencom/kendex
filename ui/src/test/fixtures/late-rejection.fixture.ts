// The shape the closing window exists for: a case starts a promise, the file
// ends, and the promise rejects after the worker that held its timer is
// gone. Not named `*.test.*`, so only the two configs beside it pick these
// up — never the suite.
import { expect, test } from "vitest";

test("returns before the promise it started rejects", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("late rejection fixture")), 20);
  });
  expect(1).toBe(1);
});
