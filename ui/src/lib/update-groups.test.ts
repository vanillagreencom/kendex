import { describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import {
  EDITED_CANT_UPDATE_NOTE,
  HELD_BY_OWNER_NOTE,
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import { READ_LANDED, READ_PENDING, readFailed } from "@/lib/read-state";
import {
  groupUpdates,
  packageCount,
  pageUpdateWithheld,
  placeName,
  skippedPlaces,
  updatablePlaces,
  updateWithheld,
} from "./update-groups";

const row = (
  name: string,
  root: string | null,
  extra: Partial<UpdateRow> = {},
): UpdateRow => ({
  scope: root ? { scope: "project", root } : { scope: "global" },
  kind: "skill",
  name,
  source: "kendex",
  repo: "vanillagreencom/kendex",
  repoIdentity: "vanillagreencom/kendex",
  current: { commit: "1111111111", label: null, date: null },
  latest: { commit: "2222222222", label: null, date: null },
  updateAvailable: true,
  pinned: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: true,
  canTakeLatest: true,
  holdOwner: null,
  derived: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
  mixed: false,
  forked: false,
  ignored: false,
  ...extra,
});

describe("update groups", () => {
  it("folds one package's places into one group, in first-seen order", () => {
    const groups = groupUpdates([
      row("gh", null),
      row("review", "/home/x/acme"),
      row("gh", "/home/x/acme"),
      row("gh", "/home/x/shop"),
    ]);
    expect(groups.map((g) => [g.name, g.places.length])).toEqual([
      ["gh", 3],
      ["review", 1],
    ]);
    expect(groups[0].places.map((p) => placeName(p.scope))).toEqual([
      "User level",
      "acme",
      "shop",
    ]);
  });

  it("names a place by folder, disambiguated by parent only on a clash", () => {
    const work = { scope: "project", root: "/home/x/work/app" } as const;
    const clients = { scope: "project", root: "/home/x/clients/app/" } as const;
    const other = { scope: "project", root: "/home/x/shop" } as const;
    expect(placeName(clients)).toBe("app");
    expect(placeName(work, [work, other])).toBe("app");
    expect(placeName(work, [work, clients])).toBe("work/app");
    expect(placeName(clients, [work, clients])).toBe("clients/app");
    expect(placeName({ scope: "global" }, [work])).toBe("User level");
  });

  it("keeps same-named packages from different repositories apart", () => {
    const groups = groupUpdates([
      row("gh", "/a"),
      row("gh", "/b", { repo: "someone/else", repoIdentity: "someone/else" }),
    ]);
    expect(groups.map((g) => g.repoIdentity)).toEqual([
      "vanillagreencom/kendex",
      "someone/else",
    ]);
    expect(
      packageCount([
        row("gh", "/a"),
        row("gh", "/b", { repo: "x/y", repoIdentity: "x/y" }),
      ]),
    ).toBe(2);
  });

  it("keeps two spellings of one repository as one package", () => {
    const groups = groupUpdates([
      row("gh", "/a", { repo: "vanillagreencom/kendex" }),
      row("gh", "/b", { repo: "https://github.com/vanillagreencom/kendex" }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].places).toHaveLength(2);
  });

  it("grows the suffix until every clashing place reads apart", () => {
    const alice = { scope: "project", root: "/home/alice/work/app" } as const;
    const team = { scope: "project", root: "/mnt/team/work/app" } as const;
    const shop = { scope: "project", root: "/srv/shop" } as const;
    const all = [alice, team, shop];
    expect(placeName(alice, all)).toBe("alice/work/app");
    expect(placeName(team, all)).toBe("team/work/app");
    expect(placeName(shop, all)).toBe("shop");
    const twin = { scope: "project", root: "/home/alice/work/app/" } as const;
    expect(placeName(alice, [alice, twin])).toBe("/home/alice/work/app");
  });

  it("reads Windows roots by either separator", () => {
    const work = { scope: "project", root: "C:\\work\\app\\" } as const;
    const clients = { scope: "project", root: "C:\\clients\\app" } as const;
    expect(placeName(work)).toBe("app");
    expect(placeName(work, [work, clients])).toBe("work/app");
    expect(placeName(clients, [work, clients])).toBe("clients/app");
  });

  it("keeps a hook and a skill of the same name apart", () => {
    const groups = groupUpdates([
      row("gh", null),
      row("gh", null, { kind: "hook" }),
    ]);
    expect(groups).toHaveLength(2);
  });

  it("counts packages, not places", () => {
    expect(
      packageCount([row("gh", null), row("gh", "/a"), row("x", "/a")]),
    ).toBe(2);
  });

  it("leaves a place held by its owner out of a bulk update", () => {
    const rows = [
      row("gh", null, { derived: true, pinned: true }),
      row("gh", "/a", { derived: true }),
      row("gh", "/b", { pinned: true }),
      row("gh", "/c", {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
      }),
    ];
    expect(updatablePlaces(rows).map((p) => placeName(p.scope))).toEqual([
      "a",
      "b",
    ]);
    expect(skippedPlaces(rows).map((p) => placeName(p.scope))).toEqual([
      "User level",
      "c",
    ]);
  });

  // The plan refuses a kind it never derives, so an Update offered for one
  // could only fail. The refusal arrives on the row in core's own words —
  // nothing here works the kind out for itself — and a place it rejects
  // still has news, so it belongs to the skipped side rather than to
  // neither. A Pi extension is the case core actually emits: no update row
  // is ever built for a plugin, so a plugin row here would assert over a
  // state nothing produces.
  it("leaves a kind core refuses out of a bulk update", () => {
    const rows = [
      row("gh", "/a"),
      row("pi-hooks", "/b", {
        kind: "pi-extension",
        noPerPackageUpdate: "core will not update this one",
      }),
    ];
    expect(updatablePlaces(rows).map((p) => p.name)).toEqual(["gh"]);
    expect(skippedPlaces(rows).map((p) => p.name)).toEqual(["pi-hooks"]);
  });

  it("leaves edited places out of a bulk update", () => {
    const places = updatablePlaces([
      row("gh", null),
      row("gh", "/a", {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
      row("gh", "/b", { updateAvailable: false, removedUpstream: true }),
    ]);
    expect(places.map((p) => placeName(p.scope))).toEqual(["User level"]);
  });
});

// Every surface that offers Update reads this one function. It answers
// with the reason and nothing else: a gate derived from it can never hide
// a button it has no words for, which a verdict beside the note would
// let it do the first time a reason arrives without one.
describe("updateWithheld", () => {
  it("says nothing stands in the way of a plain following place", () => {
    expect(updateWithheld(row("gh", "/a"))).toBeNull();
  });

  // Having nothing newer is not a refusal — that place is current, and
  // each surface reads newness its own way.
  it("withholds nothing from a place that is already current", () => {
    expect(
      updateWithheld(row("gh", "/a", { updateAvailable: false })),
    ).toBeNull();
  });

  it("hands back core's own words for a kind core refuses", () => {
    const refusal = "REFUSED-BY-CORE: this kind moves another way";
    expect(
      updateWithheld(
        row("pi-hooks", "/a", {
          kind: "pi-extension",
          noPerPackageUpdate: refusal,
        }),
      ),
    ).toBe(refusal);
  });

  it("names the edit, and the owner's hold", () => {
    expect(updateWithheld(row("gh", "/a", { blockedByLocalEdit: true }))).toBe(
      EDITED_CANT_UPDATE_NOTE,
    );
    expect(
      updateWithheld(row("gh", "/a", { pinned: true, derived: true })),
    ).toBe(HELD_BY_OWNER_NOTE);
  });

  // The kind comes first: the others are reasons a row cannot be updated
  // right now, and that one is why it never can be here.
  it("leads with the kind when more than one applies", () => {
    const refusal = "REFUSED-BY-CORE";
    expect(
      updateWithheld(
        row("pi-hooks", "/a", {
          kind: "pi-extension",
          noPerPackageUpdate: refusal,
          blockedByLocalEdit: true,
        }),
      ),
    ).toBe(refusal);
  });
});

// The read behind the rows answers before the row does. Every state of it
// has a note, because the page's only update gate is whether this returns
// one — a state that cannot say why would hide the button in silence.
describe("pageUpdateWithheld", () => {
  /** A store standing: a landed read with nothing running, unless said
   *  otherwise. `checking` bars no row that exists — it decides only
   *  whether a place with no row has been ruled out or merely not reached
   *  yet. */
  const standing = (
    over: Partial<Parameters<typeof pageUpdateWithheld>[1]> = {},
  ) => ({
    read: READ_LANDED,
    checking: false,
    reading: false,
    pendingFollows: [],
    ...over,
  });

  it("says the check is running before the first read lands", () => {
    expect(pageUpdateWithheld(null, standing({ read: READ_PENDING }))).toBe(
      UPDATES_CHECKING,
    );
  });

  // A first read that failed leaves no rows either, exactly like one in
  // flight. Only the status tells them apart, and saying "checking" over a
  // read that already failed names a wrong cause.
  it("does not call a failed first read a check in progress", () => {
    expect(
      pageUpdateWithheld(null, standing({ read: readFailed("no network") })),
    ).toBe(UPDATE_NEEDS_CHECK_HERE);
  });

  // The shape a row-first reading gets wrong: a row is present, so it
  // answers off the row and never looks at the read under it.
  it("holds a row the first read has not answered for yet", () => {
    expect(
      pageUpdateWithheld(row("gh", "/a"), standing({ read: READ_PENDING })),
    ).toBe(UPDATES_CHECKING);
  });

  // A failed re-read keeps the rows it had. The row is there and withholds
  // nothing of its own, so only the read state stands between the reader
  // and an Update over rows nobody could confirm.
  it("holds a retained row under a failed re-read", () => {
    expect(
      pageUpdateWithheld(
        row("gh", "/a"),
        standing({ read: readFailed("no network") }),
      ),
    ).toBe(UPDATE_NEEDS_CHECK_HERE);
  });

  // A write is already running in this very place, so a second one would
  // contend for the same writer lock. Another place's flip does not.
  it("holds a row whose own place has a follow flip settling", () => {
    const here = row("gh", "/a");
    expect(
      pageUpdateWithheld(
        here,
        standing({ pendingFollows: [{ scope: here.scope }] }),
      ),
    ).toBe(UPDATE_NEEDS_CHECK_HERE);
    expect(
      pageUpdateWithheld(
        here,
        standing({ pendingFollows: [{ scope: { scope: "global" } }] }),
      ),
    ).toBeNull();
  });

  // The kind is derived from the kind, not from anything a read refreshes,
  // so no check can ever clear it and none may appear to. The Updates
  // table shows the refusal here too; the two surfaces must agree.
  it("gives the kind's refusal ahead of any state of the read", () => {
    const refused = row("pi-hooks", "/a", {
      kind: "pi-extension",
      noPerPackageUpdate: "core will not update this one",
    });
    for (const over of [
      {},
      { read: READ_PENDING },
      { read: readFailed("no network") },
      { checking: true },
      { pendingFollows: [{ scope: refused.scope }] },
    ]) {
      expect(pageUpdateWithheld(refused, standing(over))).toBe(
        "core will not update this one",
      );
    }
  });

  // The control on the whole ordering: a structural fix that over-refuses
  // is as wrong as one that under-explains. A landed read with nothing
  // running withholds nothing from a plain following place.
  it("withholds nothing from a plain row under a landed read", () => {
    expect(pageUpdateWithheld(row("gh", "/a"), standing())).toBeNull();
  });

  it("says so for a place a settled read never spoke for", () => {
    expect(pageUpdateWithheld(null, standing())).toBe(NO_UPDATE_STANDING_NOTE);
  });

  // The mirror of the wrong cause this round closed: ruling a place out
  // while the read that would cover it is still running claims a verdict
  // the check has not reached. The button is hidden either way; the
  // difference is whether the reason is true.
  it("does not rule a place out while a read is still running", () => {
    expect(pageUpdateWithheld(null, standing({ checking: true }))).toBe(
      UPDATES_CHECKING,
    );
  });

  // And the counterpart: a row that exists is not barred by either flag.
  it("still offers a row that exists while a read is running", () => {
    expect(
      pageUpdateWithheld(row("gh", "/a"), standing({ checking: true })),
    ).toBeNull();
  });

  it("hands a settled place to the shared reading", () => {
    expect(
      pageUpdateWithheld(
        row("gh", "/a", { blockedByLocalEdit: true }),
        standing(),
      ),
    ).toBe(EDITED_CANT_UPDATE_NOTE);
  });
});
