import { describe, expect, it } from "vitest";
import type {
  ItemKind,
  Origin,
  PackageMeta_Serialize,
  ProvenanceRow,
  Scope,
  UpdateRow,
} from "@/bindings";
import {
  packagePlaces,
  removablePlaces,
  type UpdatesStanding,
  updatableRows,
} from "@/lib/package-places";
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

/** A read that landed with nothing running behind it: the only state in
 *  which a row on screen is a confirmed current answer. */
const SETTLED: UpdatesStanding = {
  loaded: true,
  checking: false,
  overviewInFlight: false,
  pendingFollows: [],
};

const OURS: Origin = { origin: "marketplace", source: "cat", repo: "o/r" };

/** The join as it reads for places kendex owns. Vendor content carries no
 *  row at all, which is why a place is named here to be removable. */
const owned = (scopes: Scope[], origin: Origin = OURS): ProvenanceRow[] =>
  scopes.map((scope) => ({
    scope,
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin,
  }));

const places = (
  scopes: Scope[],
  rows: UpdateRow[],
  metas: Record<string, PackageMeta_Serialize | null> = {},
  kind: ItemKind = "skill",
  standing: UpdatesStanding = SETTLED,
  provenance: ProvenanceRow[] = owned(scopes),
) => packagePlaces(scopes, kind, "gh", rows, metas, standing, provenance);

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

  // The store keeps the last-known rows through a failed or running read
  // so the page does not blank, and refuses every commit-applying action
  // over them. A card reading those rows alone would offer an Update that
  // can only raise an error.
  it("offers none while the update read has not landed", () => {
    const held = { ...SETTLED, loaded: false };
    expect(places([VG], [row(VG)], {}, "skill", held)[0].updatable).toBe(false);
  });

  it("offers none while a check is running", () => {
    const held = { ...SETTLED, checking: true };
    expect(places([VG], [row(VG)], {}, "skill", held)[0].updatable).toBe(false);
  });

  it("offers none while a read that replaces every row is in flight", () => {
    const held = { ...SETTLED, overviewInFlight: true };
    expect(places([VG], [row(VG)], {}, "skill", held)[0].updatable).toBe(false);
  });

  // A follow switch reaches its own scope alone, so it holds that place
  // and leaves the package's other places live.
  it("holds only the place a follow switch is settling in", () => {
    const held = { ...SETTLED, pendingFollows: [{ scope: VG }] };
    const built = places([VG, HYPR], [row(VG), row(HYPR)], {}, "skill", held);

    expect(built[0].updatable).toBe(false);
    expect(built[1].updatable).toBe(true);
  });

  it("hands Update all only the places that can take one", () => {
    const built = places(
      [VG, HYPR],
      [row(VG), row(HYPR, { blockedByLocalEdit: true })],
    );

    expect(updatableRows(built).map((one) => one.scope)).toEqual([VG]);
  });
});

// `removeItem` removes what the manifest declares and what the lock owns.
// A copy the scan only observed, and content the tool ships itself, are
// neither — a Remove on those would leave the card exactly where it is.
describe("which places kendex can remove", () => {
  it("removes a place it declares", () => {
    expect(places([VG], [])[0].removable).toBe(true);
  });

  it("removes a place whose copy is the reader's own", () => {
    const own: Origin = { origin: "own", source: "own", forkedFrom: null };
    const built = places([VG], [], {}, "skill", SETTLED, owned([VG], own));

    expect(built[0].removable).toBe(true);
  });

  it("leaves a copy it only observed alone", () => {
    const built = places([VG], [], {}, "skill", SETTLED, [
      {
        scope: VG,
        kind: "skill",
        name: "gh",
        harness: "claude",
        origin: { origin: "unmanaged" },
      },
    ]);

    expect(built[0].removable).toBe(false);
  });

  // The join drops vendor content rather than calling it unmanaged, so a
  // place with no row at all is not ours either.
  it("leaves content the tool ships alone", () => {
    expect(places([VG], [], {}, "skill", SETTLED, [])[0].removable).toBe(false);
  });

  it("hands Remove all only the places it owns", () => {
    const built = places([VG, HYPR], [], {}, "skill", SETTLED, owned([VG]));

    expect(removablePlaces(built).map((one) => one.scope)).toEqual([VG]);
  });
});
