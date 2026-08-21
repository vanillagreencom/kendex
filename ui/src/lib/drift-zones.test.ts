import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { canKeep, canReplace, driftZones } from "@/lib/drift-zones";

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

describe("which ways out a row has", () => {
  it("puts every state where files are already there with the decisions", () => {
    const zones = driftZones([
      row({ name: "deploy", cause: "unmanaged-content" }),
      row({ name: "scout", cause: "unmanaged-wrong-shape" }),
      row({ name: "browser", cause: "shared-link" }),
    ]);
    expect(zones.inTheWay).toHaveLength(3);
    expect(zones.changes).toHaveLength(0);
  });

  it("offers keeping only where kendex can take what is there", () => {
    expect(canKeep("unmanaged-content")).toBe(true);
    expect(canKeep("shared-link")).toBe(true);
    // A folder where one file goes: kendex has nowhere to put it as it
    // stands, so a Keep button here would fail on the click.
    expect(canKeep("unmanaged-wrong-shape")).toBe(false);
    expect(canKeep("local-edit")).toBe(false);
  });

  it("offers replacing except where the files are not at that position", () => {
    expect(canReplace("unmanaged-content")).toBe(true);
    expect(canReplace("unmanaged-wrong-shape")).toBe(true);
    // A link somebody else made: writing over it breaks their sharing.
    expect(canReplace("shared-link")).toBe(false);
  });
});
