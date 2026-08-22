import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, HarnessId, RowExits } from "@/bindings";
import { auditCounts } from "./audit-counts";
import { driftZones, Exits } from "./drift-zones";

function row(harness: HarnessId): DriftRow {
  return {
    kind: "skill",
    name: "browser",
    harness,
    scope: { scope: "project", root: "/w/app" },
    state: "conflict",
    detail: "/w/app/shared/browser",
  };
}

const exit = (
  harness: HarnessId,
  keep: boolean,
  replace: boolean,
): RowExits => ({
  key: `skill:browser:${harness}`,
  blocking: true,
  keep,
  replace,
});

const view = (
  root: string,
  rows: DriftRow[],
  exits: RowExits[],
): AuditView => ({
  scope: { scope: "project", root },
  drift: rows,
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: [],
  exits,
  heldBack: [],
  queued: [],
});

describe("a place nothing can settle, beside one with a way out", () => {
  // Both exits act on the whole item and the engine refuses one it could
  // only half settle, so the place with no exit belongs on the same row —
  // drawn without it, the row offers a button that fails on the click.
  it("sits on the same row", () => {
    const zones = driftZones(
      [row("claude"), row("codex")],
      new Exits([exit("claude", true, true), exit("codex", false, false)]),
    );

    expect(zones.inTheWay).toHaveLength(1);
    expect(zones.inTheWay[0]?.installations).toHaveLength(2);
    expect(zones.changes).toHaveLength(0);
  });

  // An edit is settled by keeping it as a fork or discarding it. Core says
  // so by leaving it out of the exits, and the row it is on stays under
  // the Apply button where it belongs.
  it("leaves a row core did not call blocking where it was", () => {
    const edited: DriftRow = { ...row("codex"), state: "stale" };
    const zones = driftZones(
      [row("claude"), edited],
      new Exits([exit("claude", true, true)]),
    );

    expect(zones.inTheWay[0]?.installations).toHaveLength(1);
    expect(zones.changes).toHaveLength(1);
  });
});

describe("a place with files and no way out at all", () => {
  // Apply cannot move it, so listing it as a change ready to apply
  // promises a button that will not touch it. It is a decision like the
  // rest, and the row says to move the files by hand.
  it("is a decision, not a change ready to apply", () => {
    const only = view("/w/a", [row("claude")], [exit("claude", false, false)]);
    const zones = driftZones(only.drift, new Exits(only.exits));
    const counts = auditCounts([only]);

    expect(zones.inTheWay).toHaveLength(1);
    expect(zones.changes).toHaveLength(0);
    expect(counts.inTheWay).toBe(1);
    expect(counts.changes).toBe(0);
  });
});
