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
  it("counts one item installed for five tools once", () => {
    const tools: HarnessId[] = ["claude", "codex", "opencode", "cursor", "pi"];
    const rows = tools.map((h) => drift("agent-browser", h, "unmanaged"));

    expect(unmanagedCount(view(rows), null)).toBe(1);
  });

  it("counts each place on its own, never folding two projects together", () => {
    const personal = view([drift("github", "claude", "unmanaged")]);
    const project = view([drift("github", "claude", "unmanaged", "/p")], "/p");

    expect(unmanagedCount(personal, null)).toBe(1);
    expect(unmanagedCount(project, null)).toBe(1);
  });

  it("counts only what was never adopted, not pending writes", () => {
    const rows = [
      drift("a", "claude", "stale"),
      drift("b", "claude", "missing"),
      drift("c", "claude", "unmanaged"),
    ];

    expect(unmanagedCount(view(rows), null)).toBe(1);
  });
});

// A place the audit could not read holds an unknown number of unmanaged
// items, not zero. Zero is a claim, and every row this list feeds carries a
// button that adopts — a write to the filesystem from rows nothing has
// confirmed still exist.
describe("a place the audit could not read", () => {
  const unreadable = (): AuditView => ({
    ...view([drift("gh", "claude", "unmanaged")]),
    error: { kind: "lock-corrupt", message: "lock is not JSON" },
  });

  it("counts nothing rather than counting zero", () => {
    expect(unmanagedCount(unreadable(), null)).toBeNull();
  });

  it("lists nothing rather than listing an empty list", () => {
    expect(unmanagedIn(unreadable(), null)).toBeNull();
  });

  // The control: the same rows without the error are a real, countable list.
  it("counts them once the place reads", () => {
    expect(
      unmanagedCount(view([drift("gh", "claude", "unmanaged")]), null),
    ).toBe(1);
  });
});

// The other way a reading fails. When `auditAll` itself refuses, the store
// records the failure and keeps every view it already had, so each one still
// reads clean while standing for a place nothing has confirmed since.
describe("a whole audit that failed", () => {
  const readable = () => view([drift("gh", "claude", "unmanaged")]);

  it("counts nothing, whatever the kept view still says", () => {
    expect(unmanagedCount(readable(), "audit refused")).toBeNull();
  });

  it("lists nothing, so no row can be handed an adopt button", () => {
    expect(unmanagedIn(readable(), "audit refused")).toBeNull();
  });

  // The control: the same view is a real list once the check succeeds.
  it("counts them again once a check answers", () => {
    expect(unmanagedCount(readable(), null)).toBe(1);
  });
});

// A place the audit has not reached yet is not a place it failed at: no
// view means no answer, which is an empty list rather than an unknown one.
describe("a place with no view yet", () => {
  it("is empty rather than unknown", () => {
    expect(unmanagedIn(undefined, null)).toEqual([]);
    expect(unmanagedCount(undefined, null)).toBe(0);
  });

  it("is unknown once the whole check has failed", () => {
    expect(unmanagedCount(undefined, "audit refused")).toBeNull();
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
