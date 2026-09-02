// A leak timed to land while a LATER case is running. Vitest attributes it
// to the file rather than to the case that started the promise, which is the
// sentence the control pins. Leak and sleep are timers in one process, so the
// leak fires first, with 190ms before the file ends for the report to land.
import { expect, test } from "vitest";

test("starts a rejection timed to land during the next case", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("mid-file rejection fixture")), 10);
  });
  expect(1).toBe(1);
});

test("innocent: slow, but leaks nothing", async () => {
  await new Promise((resolve) => setTimeout(resolve, 200));
  expect(1).toBe(1);
});
