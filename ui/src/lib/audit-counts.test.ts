import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, HarnessId, RowExits } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  blockedCount,
  blockedIn,
  blockedPlaces,
  unmanagedCount,
  unmanagedIn,
} from "./audit-counts";

function drift(
  name: string,
  harness: HarnessId,
  state: DriftRow["state"],
  root?: string,
): DriftRow {
  return {
    kind: "skill",
    name,
    harness,
    scope: root ? { scope: "project", root } : { scope: "global" },
    state,
    detail: "",
  };
}

function view(rows: DriftRow[], root?: string): AuditView {
  return {
    scope: root ? { scope: "project", root } : { scope: "global" },
    drift: rows,
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  };
}

describe("unmanagedCount", () => {
  it("counts each package once within its own place", () => {
    const tools: HarnessId[] = ["claude", "codex", "opencode", "cursor", "pi"];
    const rows = [
      {
        name: "one package across harnesses",
        reading: view(tools.map((h) => drift("agent-browser", h, "unmanaged"))),
        expected: 1,
      },
      {
        name: "personal package",
        reading: view([drift("github", "claude", "unmanaged")]),
        expected: 1,
      },
      {
        name: "same package in a project",
        reading: view([drift("github", "claude", "unmanaged", "/p")], "/p"),
        expected: 1,
      },
      {
        name: "pending writes do not count",
        reading: view([
          drift("a", "claude", "stale"),
          drift("b", "claude", "missing"),
          drift("c", "claude", "unmanaged"),
        ]),
        expected: 1,
      },
    ];
    expect(
      rows.length,
      "unmanaged package count table is empty",
    ).toBeGreaterThan(0);
    for (const row of rows)
      expect(unmanagedCount(row.reading, null), row.name).toBe(row.expected);
  });

  it("distinguishes an unread count from a confirmed empty count", () => {
    const readable = view([drift("gh", "claude", "unmanaged")]);
    const unreadable: AuditView = {
      ...readable,
      error: { kind: "lock-corrupt", message: "lock is not JSON" },
    };
    const rows: {
      name: string;
      reading: AuditView | undefined;
      failure: string | null;
      expected: number | null;
    }[] = [
      {
        name: "place failed",
        reading: unreadable,
        failure: null,
        expected: null,
      },
      {
        name: "place recovered",
        reading: readable,
        failure: null,
        expected: 1,
      },
      {
        name: "whole audit failed",
        reading: readable,
        failure: "audit refused",
        expected: null,
      },
      {
        name: "whole audit recovered",
        reading: readable,
        failure: null,
        expected: 1,
      },
      { name: "no view yet", reading: undefined, failure: null, expected: 0 },
      {
        name: "no view after whole failure",
        reading: undefined,
        failure: "audit refused",
        expected: null,
      },
    ];
    expect(rows.length, "unmanaged read count table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(unmanagedCount(row.reading, row.failure), row.name).toBe(
        row.expected,
      );
  });
});

describe("unmanagedIn", () => {
  it("does not hand unconfirmed rows to an adopt action", () => {
    const readable = view([drift("gh", "claude", "unmanaged")]);
    const rows = [
      {
        name: "place failed",
        reading: {
          ...readable,
          error: { kind: "lock-corrupt" as const, message: "lock is not JSON" },
        },
        failure: null,
        expected: null,
      },
      {
        name: "whole audit failed",
        reading: readable,
        failure: "audit refused",
        expected: null,
      },
      { name: "no view yet", reading: undefined, failure: null, expected: [] },
    ];
    expect(rows.length, "unmanaged read list table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(unmanagedIn(row.reading, row.failure), row.name).toEqual(
        row.expected,
      );
  });
});

const inTheWay = (
  name: string,
  harness: HarnessId,
  over: Partial<DriftRow> = {},
): DriftRow => ({
  ...drift(name, harness, "conflict"),
  cause: "unmanaged-content",
  detail: `/work/acme/.${harness}/skills/${name}`,
  ...over,
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

const blocked = (rows: DriftRow[], exits: RowExits[]): AuditView => ({
  ...view(rows),
  exits,
});

describe("blockedIn", () => {
  it("folds one item's tools into one row", () => {
    const rows = blockedIn(
      blocked(
        [
          inTheWay("release-notes", "claude"),
          inTheWay("release-notes", "codex"),
        ],
        [
          exit("skill:release-notes:claude"),
          exit("skill:release-notes:codex", { tools: ["codex"] }),
        ],
      ),
      null,
    );

    expect(rows).toHaveLength(1);
    expect(rows?.[0].installations).toHaveLength(2);
  });

  // A conflict of another kind beside files in the way takes the exits off
  // the row it sits with; alone it is a change, not a decision about files.
  it("keeps a blocking row with no files of its own beside the item's", () => {
    const rows = blockedIn(
      blocked(
        [
          inTheWay("release-notes", "claude"),
          inTheWay("release-notes", "codex", {
            cause: undefined,
            detail: "revision clash",
          }),
        ],
        [
          exit("skill:release-notes:claude"),
          exit("skill:release-notes:codex", {
            files: false,
            keep: false,
            enter: false,
            replace: false,
          }),
        ],
      ),
      null,
    );

    expect(rows).toHaveLength(1);
    expect(rows?.[0].installations).toHaveLength(2);
  });

  it("leaves out an item whose only conflict is about no files", () => {
    expect(
      blockedIn(
        blocked(
          [inTheWay("github", "claude", { cause: undefined, detail: "clash" })],
          [exit("skill:github:claude", { files: false })],
        ),
        null,
      ),
    ).toEqual([]);
  });

  // Core reports an exit for the blocked rows only. A drift row it said
  // nothing about is not one this list may draw a button for.
  it("leaves out a row core reported no exit for", () => {
    expect(
      blockedIn(blocked([inTheWay("release-notes", "claude")], []), null),
    ).toEqual([]);
  });
});

// The same two channels `unmanagedIn` takes, for the same reason: both
// exits offered behind these rows move the reader's own files.
describe("blockedPlaces over an unconfirmed reading", () => {
  const one = () =>
    blocked(
      [inTheWay("release-notes", "claude")],
      [exit("skill:release-notes:claude")],
    );

  it("lists nothing for a place whose own view carries an error", () => {
    const unreadable = {
      ...one(),
      error: { kind: "lock-corrupt" as const, message: "bad" },
    };
    expect(blockedPlaces([unreadable], null)).toEqual([]);
  });

  it("answers null when the whole check failed, never an empty list", () => {
    expect(blockedPlaces([one()], "audit refused")).toBeNull();
    expect(blockedCount(blockedPlaces([one()], "audit refused"))).toBe(0);
  });

  // The control: the same views are a real list once the check answers.
  it("lists the place once the check answers", () => {
    const places = blockedPlaces([one()], null);
    expect(places).toHaveLength(1);
    expect(blockedCount(places)).toBe(1);
  });

  it("says whether the same apply carries other work", () => {
    expect(blockedPlaces([one()], null)?.[0].alsoApplies).toBe(false);
    expect(
      blockedPlaces([{ ...one(), plan: ["Install hook guard"] }], null)?.[0]
        .alsoApplies,
    ).toBe(true);
  });
});
