import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, RowExits, Scope } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { blockedCount, blockedIn, blockedPlaces } from "@/lib/blocked";

const ACME: Scope = { scope: "project", root: "/work/acme" };

const inTheWay = (name: string, harness: DriftRow["harness"]): DriftRow => ({
  kind: "skill",
  name,
  harness,
  scope: ACME,
  state: "conflict",
  cause: "unmanaged-content",
  detail: `/work/acme/.${harness}/skills/${name}`,
});

const exit = (key: string, over: Partial<RowExits> = {}): RowExits => ({
  key,
  blocking: true,
  files: true,
  keep: true,
  enter: true,
  replace: true,
  tools: ["claude"],
  ...over,
});

const view = (over: Partial<AuditView>): AuditView => ({
  scope: ACME,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
  ...over,
});

describe("blockedIn", () => {
  it("folds one item's tools into one row", () => {
    const rows = blockedIn(
      view({
        drift: [
          inTheWay("release-notes", "claude"),
          inTheWay("release-notes", "codex"),
        ],
        exits: [
          exit("skill:release-notes:claude"),
          exit("skill:release-notes:codex", { tools: ["codex"] }),
        ],
      }),
    );

    expect(rows).toHaveLength(1);
    expect(rows[0].installations.map((row) => row.harness)).toEqual([
      "claude",
      "codex",
    ]);
  });

  // A revision clash beside files in the way takes the exits off the row it
  // sits with; alone it is a change, not a decision about files.
  it("keeps a blocking row with no files of its own beside the item's", () => {
    const clash: DriftRow = {
      ...inTheWay("release-notes", "codex"),
      cause: undefined,
      detail: "revision clash",
    };

    const rows = blockedIn(
      view({
        drift: [inTheWay("release-notes", "claude"), clash],
        exits: [
          exit("skill:release-notes:claude"),
          exit("skill:release-notes:codex", {
            files: false,
            keep: false,
            enter: false,
            replace: false,
          }),
        ],
      }),
    );

    expect(rows).toHaveLength(1);
    expect(rows[0].installations).toHaveLength(2);
  });

  it("leaves out an item whose only conflict is about no files", () => {
    const clash: DriftRow = {
      ...inTheWay("github", "claude"),
      cause: undefined,
      detail: "revision clash",
    };

    expect(
      blockedIn(
        view({
          drift: [clash],
          exits: [
            exit("skill:github:claude", {
              files: false,
              keep: false,
              enter: false,
              replace: false,
            }),
          ],
        }),
      ),
    ).toEqual([]);
  });

  // Core reports an exit for the blocked rows only. A drift row it said
  // nothing about is not one this list may draw a button for.
  it("leaves out a row core reported no exit for", () => {
    expect(
      blockedIn(view({ drift: [inTheWay("release-notes", "claude")] })),
    ).toEqual([]);
  });
});

describe("blockedPlaces", () => {
  it("skips a place the audit could not read", () => {
    const unreadable = view({
      drift: [inTheWay("release-notes", "claude")],
      exits: [exit("skill:release-notes:claude")],
      error: { kind: "lock-corrupt", message: "not valid JSON" },
    });

    expect(blockedPlaces([unreadable])).toEqual([]);
  });

  it("says whether the same apply carries other work", () => {
    const drift = [inTheWay("release-notes", "claude")];
    const exits = [exit("skill:release-notes:claude")];

    expect(blockedPlaces([view({ drift, exits })])[0].alsoApplies).toBe(false);
    expect(
      blockedPlaces([view({ drift, exits, plan: ["Install hook guard"] })])[0]
        .alsoApplies,
    ).toBe(true);
  });

  it("counts blocked items across every place", () => {
    const places = blockedPlaces([
      view({
        drift: [
          inTheWay("release-notes", "claude"),
          inTheWay("deploy", "claude"),
        ],
        exits: [
          exit("skill:release-notes:claude"),
          exit("skill:deploy:claude"),
        ],
      }),
      view({
        scope: { scope: "global" },
        drift: [inTheWay("browser", "claude")],
        exits: [exit("skill:browser:claude")],
      }),
    ]);

    expect(places.map((place) => place.key)).toEqual(["/work/acme", "global"]);
    expect(blockedCount(places)).toBe(3);
  });
});
