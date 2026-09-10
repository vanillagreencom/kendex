import { describe, expect, it } from "vitest";
import type { BlockedPlace } from "@/lib/audit-counts";
import type { Problem } from "@/stores/problems";
import { afterReconnect } from "./after-reconnect";

const ROOT = "/work/vsys";
const here = { scope: "project" as const, root: ROOT };
const elsewhere = { scope: "project" as const, root: "/work/other" };

/** One place with `rows` blocked items in it. The count a person reads is
 *  the items, and one place holds every one of them at that folder. */
const blocked = (scope: BlockedPlace["scope"], rows = 1): BlockedPlace =>
  ({
    key: "k",
    scope,
    rows: Array.from({ length: rows }, (_, at) => ({ name: `item${at}` })),
    exits: null,
    alsoApplies: false,
  }) as never;
const problem = (scope: Problem["scope"]): Problem => ({
  key: "k",
  scope,
  kind: "lock-corrupt",
  message: "no",
});

describe("what the read after a reconnect says about the new folder", () => {
  it("counts the items at that folder, not the places holding them", () => {
    expect(
      afterReconnect([], [blocked(here, 3), blocked(elsewhere, 2)], ROOT),
    ).toEqual({ state: "problems", count: 3 });
    expect(afterReconnect([], [blocked(elsewhere)], ROOT)).toEqual({
      state: "clean",
    });
  });

  // The one claim this must never make: a place kendex could not read is
  // not a place kendex found nothing wrong with.
  it("claims nothing where the read could not answer", () => {
    expect(afterReconnect([], null, ROOT)).toEqual({ state: "unchecked" });
    expect(afterReconnect([problem(here)], [], ROOT)).toEqual({
      state: "unchecked",
    });
    expect(afterReconnect([problem(null)], [], ROOT)).toEqual({
      state: "clean",
    });
  });
});
