// The shape the unhandled-rejection guard exists for: a case starts a
// promise, returns, and the promise rejects afterwards with nothing
// awaiting it. Not named `*.test.*`, so only the two configs beside it
// pick it up — never the suite.
import { expect, test } from "vitest";

test("returns before the promise it started rejects", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("late rejection fixture")), 20);
  });
  expect(1).toBe(1);
});
