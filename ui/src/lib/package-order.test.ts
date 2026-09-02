import { describe, expect, it } from "vitest";
import type { AvailablePackage, ItemKind } from "@/bindings";
import type { PackageEntry } from "@/components/marketplaces/package-row";
import { subscription } from "@/stores/marketplaces-shared";
import { BY_NAME, orderPackages, type SortKey } from "./package-order";

const catalog = subscription({ scope: "global" }, "kendex");

const entry = (
  name: string,
  updatedAt: string | null = null,
  kind: ItemKind = "skill",
): PackageEntry => ({
  catalog,
  recordsUnreadable: false,
  row: {
    kind,
    name,
    description: null,
    summary: null,
    tags: [],
    bundles: [],
    state: "available",
    collision: null,
    dependencies: { required: [], optional: [] },
    updatedAt,
  } satisfies AvailablePackage,
});

const names = (entries: PackageEntry[], key: SortKey, ascending: boolean) =>
  orderPackages(entries, { key, ascending }).map((e) => e.row.name);

describe("the order a marketplace's packages are drawn in", () => {
  const rows = [entry("review"), entry("apply"), entry("gh")];

  it("opens on name, A to Z", () => {
    expect(orderPackages(rows, BY_NAME).map((e) => e.row.name)).toEqual([
      "apply",
      "gh",
      "review",
    ]);
  });

  it("turns around when the same column is asked for again", () => {
    expect(names(rows, "name", false)).toEqual(["review", "gh", "apply"]);
  });

  it("leaves the caller's list alone", () => {
    orderPackages(rows, { key: "name", ascending: false });
    expect(rows.map((e) => e.row.name)).toEqual(["review", "apply", "gh"]);
  });
});

describe("ordering by when a package last changed", () => {
  const rows = [
    entry("old", "2024-01-01T00:00:00+00:00"),
    entry("new", "2026-05-05T00:00:00+00:00"),
    entry("undated"),
  ];

  it("puts the oldest first ascending", () => {
    expect(names(rows, "updated", true)).toEqual(["old", "new", "undated"]);
  });

  // Both directions are one click apart on the header, so both are asserted
  // in full: the undated row lands last either way and proves nothing about
  // the direction on its own.
  it("puts the newest first descending", () => {
    expect(names(rows, "updated", false)).toEqual(["new", "old", "undated"]);
  });

  // Unknown is not "older than everything": a catalog with no history to
  // read would otherwise lead the list every time it is sorted oldest-first.
  it("keeps an undated package last whichever way the column points", () => {
    expect(names(rows, "updated", true).at(-1)).toBe("undated");
    expect(names(rows, "updated", false).at(-1)).toBe("undated");
  });

  it("compares instants, not the strings they were written as", () => {
    const zones = [
      entry("later", "2026-05-05T01:00:00+00:00"),
      entry("earlier", "2026-05-05T09:00:00+09:00"),
    ];
    expect(names(zones, "updated", true)).toEqual(["earlier", "later"]);
  });
});

describe("ordering by kind", () => {
  const rows = [
    entry("zeta", null, "skill"),
    entry("alpha", null, "skill"),
    entry("beta", null, "agent"),
  ];

  it("groups the kinds and breaks every tie by name", () => {
    expect(names(rows, "kind", true)).toEqual(["beta", "alpha", "zeta"]);
  });

  // Turning the column around turns the kinds around; names inside a kind
  // stay A-to-Z, because the tie-break is not what was reversed.
  it("turns the kinds around and leaves the tie-break alone", () => {
    expect(names(rows, "kind", false)).toEqual(["alpha", "zeta", "beta"]);
  });
});

// A commit date is a catalog's bytes. git prints a timezone `Date.parse`
// rejects without complaint, and a NaN comparator does not merely misplace
// the row that carries it — it makes the whole table's order
// implementation-defined.
describe("ordering when a catalog wrote a date nothing can read", () => {
  const unreadable = entry("broken", "2009-02-18T02:31:30+99:00");
  const rows = [
    entry("old", "2024-01-01T00:00:00+00:00"),
    unreadable,
    entry("new", "2026-05-05T00:00:00+00:00"),
  ];

  it("is a date nothing can read, so the premise holds", () => {
    expect(Number.isNaN(Date.parse("2009-02-18T02:31:30+99:00"))).toBe(true);
  });

  it("buries it with the undated rows instead of scrambling the table", () => {
    expect(names(rows, "updated", true)).toEqual(["old", "new", "broken"]);
    expect(names(rows, "updated", false)).toEqual(["new", "old", "broken"]);
  });
});
