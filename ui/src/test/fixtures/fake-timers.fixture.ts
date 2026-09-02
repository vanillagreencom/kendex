// A case that installs fake timers and never restores them. The window waits
// on the `setTimeout` captured at setup load, so the run reaches a verdict.
// Bind that wait late instead and the child dies on vitest's hook timeout —
// "Hook timed out in 10000ms", exit 1.
import { expect, test, vi } from "vitest";

test("leaves fake timers installed", () => {
  vi.useFakeTimers();
  expect(vi.isFakeTimers()).toBe(true);
});
