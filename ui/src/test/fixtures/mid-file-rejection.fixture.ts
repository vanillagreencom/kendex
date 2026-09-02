// The other half of the shape: the case returns, the rejection settles
// while the file is still running, and the case that leaked it — not the
// last case to have run — is the one that goes red.
import { expect, test } from "vitest";

test("leaks a rejection its own case outlives", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("mid-file rejection fixture")), 0);
  });
  expect(1).toBe(1);
});

test("runs after the leak", () => {
  expect(1).toBe(1);
});
