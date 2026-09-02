// A leak timed to land while a LATER case is running. Vitest attributes it
// to the file and hedges about the case ("the latest test that might've
// caused the error"), which is the honest reading: nothing here knows which
// case started the promise. The control asserts that hedge survives under
// both configs — a guard that replaced it with a confident name would be
// stating something it cannot know.
import { expect, test } from "vitest";

test("starts a rejection timed to land during the next case", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("mid-file rejection fixture")), 25);
  });
  expect(1).toBe(1);
});

test("innocent: slow, but leaks nothing", async () => {
  await new Promise((resolve) => setTimeout(resolve, 60));
  expect(1).toBe(1);
});
