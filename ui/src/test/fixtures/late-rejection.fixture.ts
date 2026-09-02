// The shape the closing window exists for: a promise rejecting after the
// file's last case returned. Not named `*.test.*`, so only the two configs
// beside it pick these up — never the suite.
//
// The delay races worker teardown, which is work rather than a clock: under
// 5ms on an idle box, but it stretches with load while this timer does not,
// so the two do not scale together and the gap has to be absolute. The
// window the guarded control sets is a timer like this one, so that side
// only needs to outlast this delay. Move this and check both directions.
import { expect, test } from "vitest";

test("returns before the promise it started rejects", () => {
  new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("late rejection fixture")), 750);
  });
  expect(1).toBe(1);
});
