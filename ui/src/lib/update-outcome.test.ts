import { describe, expect, it } from "vitest";
import type { DriftRow, PackageUpdate_Serialize } from "@/bindings";
import { outcomeOf } from "./update-outcome";

const row = (
  harness: "claude" | "codex",
  state: DriftRow["state"],
): DriftRow => ({
  kind: "skill",
  name: "gh",
  harness,
  scope: { scope: "global" },
  state,
  detail: "why",
  cause: null,
});

const update = (
  parts: Partial<
    Pick<PackageUpdate_Serialize, "heldBack" | "removed" | "moved">
  >,
): PackageUpdate_Serialize =>
  ({
    view: {
      scope: { scope: "global" },
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      adoptable: [],
      exits: [],
      error: null,
    },
    heldBack: [],
    removed: [],
    moved: [],
    ...parts,
  }) as PackageUpdate_Serialize;

describe("outcomeOf", () => {
  it("reads a clean apply as moved", () => {
    expect(outcomeOf(update({ moved: [row("claude", "stale")] }))).toEqual({
      removed: [],
      held: [],
      moved: true,
    });
  });

  // A plan that refused nothing wrote the package, whether or not the
  // report names a rendering it moved.
  it("reads an apply that refused nothing as moved", () => {
    expect(outcomeOf(update({}))).toEqual({
      removed: [],
      held: [],
      moved: true,
    });
  });

  it("reads a refusal that kept the copy as held, and nothing moved", () => {
    expect(
      outcomeOf(update({ heldBack: [row("claude", "conflict")] })),
    ).toEqual({
      removed: [],
      held: ["Claude Code"],
      moved: false,
    });
  });

  it("reads a refusal that took the copy away as removed", () => {
    expect(outcomeOf(update({ removed: [row("claude", "conflict")] }))).toEqual(
      {
        removed: ["Claude Code"],
        held: [],
        moved: false,
      },
    );
  });

  // A run can do more than one of these at once, and a reading that picks
  // one verdict drops whichever it did not pick.
  it("keeps every answer a run gave at once", () => {
    expect(
      outcomeOf(
        update({
          removed: [row("claude", "conflict")],
          heldBack: [row("codex", "conflict")],
          moved: [row("codex", "stale")],
        }),
      ),
    ).toEqual({
      removed: ["Claude Code"],
      held: ["Codex"],
      moved: true,
    });
  });
});
