// A case that installs fake timers and never restores them. The closing
// window has to outlive that: it waits on the `setTimeout` captured at setup
// load, so a run reaches its verdict instead of hanging on a clock nobody
// advances. Green under the guarded config, and it hangs to the case timeout
// the moment the wait is late-bound to `globalThis.setTimeout`.
import { expect, test, vi } from "vitest";

test("leaves fake timers installed", () => {
  vi.useFakeTimers();
  expect(vi.isFakeTimers()).toBe(true);
});
