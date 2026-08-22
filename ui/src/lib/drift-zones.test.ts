import { describe, expect, it } from "vitest";
import type { DriftRow, HarnessId } from "@/bindings";
import { auditCounts } from "./audit-counts";
import { driftZones } from "./drift-zones";

function row(
  harness: HarnessId,
  cause: DriftRow["cause"],
  state: DriftRow["state"] = "conflict",
): DriftRow {
  return {
    kind: "skill",
    name: "browser",
    harness,
    scope: { scope: "project", root: "/w/app" },
    state,
    detail: "/w/app/shared/browser",
    cause,
  };
}

describe("a hard conflict beside files in the way", () => {
  // Both exits act on the whole item and the engine refuses one it could
  // only half settle, so the row a person reads has to carry the link
  // kendex will not touch — drawn without it, it offers a button that
  // fails on the click.
  it("sits on the same row, where it takes the offers with it", () => {
    const zones = driftZones([
      row("claude", "unmanaged-content"),
      row("codex", "foreign-link"),
    ]);

    expect(zones.inTheWay).toHaveLength(1);
    expect(zones.inTheWay[0]?.installations).toHaveLength(2);
    expect(zones.changes).toHaveLength(0);
  });

  it("leaves an ordinary conflict where it was", () => {
    const zones = driftZones([
      row("claude", "unmanaged-content"),
      // An installation the person edited: settled by a decision of its
      // own, and never a reason to take this item's exits away.
      row("codex", null, "stale"),
    ]);

    expect(zones.inTheWay[0]?.installations).toHaveLength(1);
    expect(zones.changes).toHaveLength(1);
  });
});

describe("an edit beside files in the way", () => {
  // An edit is settled by keeping it as a fork or discarding it, so it
  // never takes the item's other exits away — unlike a place nothing can
  // settle, which does.
  it("is left where it was, and the exits stand", () => {
    const zones = driftZones([
      row("claude", "unmanaged-content"),
      row("codex", "local-edit"),
    ]);

    expect(zones.inTheWay[0]?.installations).toHaveLength(1);
    expect(zones.changes).toHaveLength(1);
  });

  it("counts the same way Review draws it", () => {
    const view = {
      scope: { scope: "project" as const, root: "/w/app" },
      drift: [row("claude", "unmanaged-content"), row("codex", "foreign-link")],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      adoptable: [],
      keepable: [],
      heldBack: [],
      queued: [],
    };
    const counts = auditCounts([view]);

    expect(counts.inTheWay).toBe(1);
    expect(counts.changes).toBe(0);
  });
});
