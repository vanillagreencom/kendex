import { describe, expect, it } from "vitest";
import type { BlockedPlace } from "@/lib/audit-counts";
import type { Problem } from "@/stores/problems";
import { afterReconnect } from "./after-reconnect";

const ROOT = "/work/vsys";
const here = { scope: "project" as const, root: ROOT };
const elsewhere = { scope: "project" as const, root: "/work/other" };

const blocked = (scope: BlockedPlace["scope"]): BlockedPlace =>
  ({ key: "k", scope, rows: [], exits: null, alsoApplies: false }) as never;
const problem = (scope: Problem["scope"]): Problem => ({
  key: "k",
  scope,
  kind: "lock-corrupt",
  message: "no",
});

describe("what the read after a reconnect says about the new folder", () => {
  it("counts only what is at that folder", () => {
    expect(
      afterReconnect([], [blocked(here), blocked(elsewhere)], ROOT),
    ).toEqual({ state: "problems", count: 1 });
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
