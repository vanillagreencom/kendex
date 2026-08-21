import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { driftZones } from "@/lib/drift-zones";

const row = (over: Partial<DriftRow>): DriftRow =>
  ({
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    state: "conflict",
    detail: "/home/me/.claude/skills/deploy",
    ...over,
  }) as DriftRow;

describe("driftZones", () => {
  it("keeps an item whose files were already there out of the apply list", () => {
    const zones = driftZones([row({ cause: "unmanaged-content" })]);
    expect(zones.inTheWay).toHaveLength(1);
    expect(zones.changes).toHaveLength(0);
    expect(zones.inTheWay[0]?.name).toBe("deploy");
  });

  it("leaves every other conflict where the reader expects it", () => {
    const zones = driftZones([
      row({ name: "gh", cause: "local-edit" }),
      row({ name: "lint", state: "stale", cause: "upstream-changed" }),
      row({ name: "old", state: "orphaned" }),
      row({ name: "mine", state: "unmanaged" }),
    ]);
    expect(zones.changes.map((group) => group.name)).toEqual([
      "gh",
      "lint",
      "old",
    ]);
    expect(zones.orphans.map((group) => group.name)).toEqual(["old"]);
    expect(zones.unmanaged.map((group) => group.name)).toEqual(["mine"]);
    expect(zones.inTheWay).toHaveLength(0);
  });

  it("folds one item's tools into one row to decide once", () => {
    const zones = driftZones([
      row({ harness: "claude", cause: "unmanaged-content" }),
      row({ harness: "codex", cause: "unmanaged-content" }),
    ]);
    expect(zones.inTheWay).toHaveLength(1);
    expect(zones.inTheWay[0].installations).toHaveLength(2);
  });
});
