import { describe, expect, it } from "vitest";
import type {
  HarnessId,
  ItemKind,
  ObservedItem,
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
  vendorAt,
} from "@/lib/package-places";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
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
  requiredBy: [],
  forked: false,
  mixed: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
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
  read: READ_LANDED,
  checking: false,
  reading: false,
  pendingFollows: [],
};

const OURS: Origin = { origin: "marketplace", source: "cat", repo: "o/r" };
const UNMANAGED: Origin = { origin: "unmanaged" };

/** One installation as the scan found it: a place holds one per harness. */
const install = (
  scope: Scope,
  harness: HarnessId = "claude",
  vendor: string | null = null,
): ObservedItem => ({
  kind: "skill",
  name: "gh",
  harness,
  scope,
  path: `/x/${harness}`,
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor,
});

/** One provenance row, which the join keys per harness the same way. */
const joined = (
  scope: Scope,
  origin: Origin,
  harness: HarnessId = "claude",
): ProvenanceRow => ({ scope, kind: "skill", name: "gh", harness, origin });

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
  installed: ObservedItem[] = scopes.map((scope) => install(scope)),
) =>
  packagePlaces(
    scopes,
    kind,
    "gh",
    rows,
    metas,
    standing,
    provenance,
    installed,
  );

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

  it("offers none for a kind core refuses", () => {
    const built = places(
      [VG],
      [
        {
          ...row(VG),
          kind: "pi-extension",
          noPerPackageUpdate: "core will not update this one",
        },
      ],
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
    const held = { ...SETTLED, read: READ_PENDING };
    expect(places([VG], [row(VG)], {}, "skill", held)[0].updatable).toBe(false);
  });

  it("offers none while a check is running", () => {
    const held = { ...SETTLED, checking: true };
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
      joined(VG, UNMANAGED),
    ]);

    expect(built[0].removable).toBe(false);
  });

  // A place holds one copy per harness and the join answers per harness.
  // Removing takes the declaration it finds and leaves the rest, so half
  // an answer is not an answer: the card would stay either way.
  it("leaves a place alone where one of its harnesses is unmanaged", () => {
    const built = places(
      [VG],
      [],
      {},
      "skill",
      SETTLED,
      [joined(VG, OURS, "claude"), joined(VG, UNMANAGED, "codex")],
      [install(VG, "claude"), install(VG, "codex")],
    );

    expect(built[0].removable).toBe(false);
  });

  // Vendor content is absent from the join by design, so a copy with no
  // row is one kendex knows nothing about, never one that is not there.
  it("leaves a place alone where one of its harnesses ships with the tool", () => {
    const built = places(
      [VG],
      [],
      {},
      "skill",
      SETTLED,
      [joined(VG, OURS, "claude")],
      [install(VG, "claude"), install(VG, "codex")],
    );

    expect(built[0].removable).toBe(false);
  });

  it("removes a place whose every harness is ours", () => {
    const built = places(
      [VG],
      [],
      {},
      "skill",
      SETTLED,
      [joined(VG, OURS, "claude"), joined(VG, OURS, "codex")],
      [install(VG, "claude"), install(VG, "codex")],
    );

    expect(built[0].removable).toBe(true);
  });

  // The join says nothing about a place the scan found nothing in.
  it("removes nothing where no installation was observed", () => {
    expect(
      places([VG], [], {}, "skill", SETTLED, owned([VG]), [])[0].removable,
    ).toBe(false);
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

// A place holds one installation per harness, and the safety reading merges
// every one of them. Reading the vendor off the first row alone answered for
// a set it does not speak for: a tool's bundled copy beside a copy the
// reader owns would have suppressed the second one's real score.
describe("vendorAt", () => {
  it("names the vendor when every copy in the place is theirs", () => {
    expect(
      vendorAt(
        [install(VG, "claude", "Anthropic"), install(VG, "codex", "Anthropic")],
        VG,
      ),
    ).toBe("Anthropic");
  });

  it("names nobody when one copy in the place is the reader's own", () => {
    expect(
      vendorAt([install(VG, "claude", "Anthropic"), install(VG, "codex")], VG),
    ).toBeNull();
  });

  // The reader's own copy is first here, so a check that stopped at row one
  // would get this right by luck and the case above wrong.
  it("names nobody whichever copy the scan happened to list first", () => {
    expect(
      vendorAt([install(VG, "codex"), install(VG, "claude", "Anthropic")], VG),
    ).toBeNull();
  });

  it("names nobody when the copies disagree about who ships them", () => {
    expect(
      vendorAt(
        [install(VG, "claude", "Anthropic"), install(VG, "codex", "OpenAI")],
        VG,
      ),
    ).toBeNull();
  });

  it("asks only the place it was given", () => {
    const installs = [
      install(VG, "claude"),
      install(HYPR, "claude", "Anthropic"),
    ];
    expect(vendorAt(installs, HYPR)).toBe("Anthropic");
    expect(vendorAt(installs, VG)).toBeNull();
  });

  it("names nobody where the package is not installed at all", () => {
    expect(vendorAt([install(VG, "claude", "Anthropic")], MINE)).toBeNull();
  });
});
