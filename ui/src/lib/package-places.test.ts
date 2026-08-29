import { describe, expect, it } from "vitest";
import type {
  ItemKind,
  PackageMeta_Serialize,
  Scope,
  UpdateRow,
} from "@/bindings";
import { packagePlaces, updatableRows } from "@/lib/package-places";
import { scopeKey } from "@/lib/scope";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
const MINE: Scope = { scope: "global" };

const row = (scope: Scope, over: Partial<UpdateRow> = {}): UpdateRow => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: null,
  latest: null,
  updateAvailable: true,
  pinned: false,
  holdOwner: null,
  ignored: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: false,
  canTakeLatest: false,
  derived: false,
  forked: false,
  mixed: false,
  removedUpstream: false,
  ...over,
});

const meta = (installedAt: string | null): PackageMeta_Serialize => ({
  source: "cat",
  repo: "o/r",
  repoUrl: null,
  rev: null,
  current: null,
  installedAt,
  harnesses: ["claude"],
  enabled: true,
  fork: null,
  catalog: null,
});

const places = (
  scopes: Scope[],
  rows: UpdateRow[],
  metas: Record<string, PackageMeta_Serialize | null> = {},
  kind: ItemKind = "skill",
) => packagePlaces(scopes, kind, "gh", rows, metas);

describe("the places one package sits in", () => {
  it("names each place among the others and carries its install date", () => {
    const built = places([VG, HYPR], [], {
      [scopeKey(VG)]: meta("2026-08-01T10:00:00Z"),
      [scopeKey(HYPR)]: meta(null),
    });

    expect(built.map((place) => place.name)).toEqual(["vg", "hyprtrade"]);
    expect(built[0].installedAt).toBe("2026-08-01T10:00:00Z");
    expect(built[1].installedAt).toBeNull();
  });

  // The scan says where a package is installed. A place the update read
  // never spoke about, or whose record could not be read, is still a place
  // holding a copy — dropping its card would hide an installation.
  it("keeps a place no other read could speak for", () => {
    const built = places([VG, MINE], [row(VG)]);

    expect(built.map((place) => place.name)).toEqual(["vg", "User level"]);
    expect(built[1].row).toBeNull();
    expect(built[1].installedAt).toBeNull();
  });

  it("matches a row by place, not by package name alone", () => {
    const elsewhere = { ...row(HYPR), name: "other" };
    const built = places([VG, HYPR], [row(VG), elsewhere]);

    expect(built[0].row?.scope).toEqual(VG);
    expect(built[1].row).toBeNull();
  });
});

// An Update offered where the engine would refuse it is a button that can
// only fail, so the card asks the same judge "Update all" asks.
describe("which places can take an update", () => {
  it("offers one where an update is waiting and nothing holds it", () => {
    expect(places([VG], [row(VG)])[0].updatable).toBe(true);
  });

  it("offers none where nothing is waiting", () => {
    expect(
      places([VG], [row(VG, { updateAvailable: false })])[0].updatable,
    ).toBe(false);
  });

  it("offers none over a hand edit", () => {
    expect(
      places([VG], [row(VG, { blockedByLocalEdit: true })])[0].updatable,
    ).toBe(false);
  });

  it("offers none where the hold belongs to a bundle or parent", () => {
    expect(
      places([VG], [row(VG, { pinned: true, derived: true })])[0].updatable,
    ).toBe(false);
  });

  it("offers none for a kind the planner never updates one at a time", () => {
    const built = places(
      [VG],
      [{ ...row(VG), kind: "pi-extension" }],
      {},
      "pi-extension",
    );
    expect(built[0].updatable).toBe(false);
  });

  it("hands Update all only the places that can take one", () => {
    const built = places(
      [VG, HYPR],
      [row(VG), row(HYPR, { blockedByLocalEdit: true })],
    );

    expect(updatableRows(built).map((one) => one.scope)).toEqual([VG]);
  });
});
