import { describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import {
  EDITED_CANT_UPDATE_NOTE,
  HELD_BY_OWNER_NOTE,
} from "@/lib/copy-updates";
import {
  availableUpdateCount,
  availableUpdatesIn,
  groupUpdates,
  outOfDateIn,
  packageCount,
  placeCount,
  placeName,
  placesWithUpdates,
  skippedPlaces,
  updatablePlaces,
  updateWithheld,
  visibleUpdates,
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
  requiredBy: [],
  removedUpstream: false,
  noPerPackageUpdate: null,
  mixed: false,
  forked: false,
  forkEdited: false,
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

  // The Updates page's "N updates across M places": a row is one package in
  // one place, so the places are counted apart from the rows.
  it("counts places, not rows", () => {
    const CASES = [
      { rows: [row("gh", null), row("gh", "/a"), row("x", "/a")], places: 2 },
      { rows: [row("gh", "/a"), row("x", "/a")], places: 1 },
      { rows: [row("gh", null)], places: 1 },
    ];
    expect(CASES).toHaveLength(3);
    for (const { rows, places } of CASES) {
      expect(placeCount(rows), `${rows.length} rows`).toBe(places);
    }
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

// "Update this project's packages" is a choice beside "update all", and
// the places it offers are the ones a run could actually write in.
describe("the places an update can be offered for", () => {
  const edited = {
    blockedByLocalEdit: true,
    editedHarnesses: ["claude" as const],
  };

  it("keeps every row of a place it offers, not only the takeable ones", () => {
    const places = placesWithUpdates([
      row("gh", "/a"),
      row("dev", "/a", edited),
      row("orch", "/b"),
    ]);
    expect(places).toHaveLength(2);
    expect(places[0].scope).toEqual({ scope: "project", root: "/a" });
    // Both of /a's rows travel, so the dialog for that place can say what
    // it leaves alone there.
    expect(places[0].rows.map((r) => r.name)).toEqual(["gh", "dev"]);
    expect(places[1].rows.map((r) => r.name)).toEqual(["orch"]);
  });

  it("offers no place where nothing could be written", () => {
    expect(
      placesWithUpdates([row("dev", "/a", edited), row("gh", "/a", edited)]),
    ).toHaveLength(0);
    expect(placesWithUpdates([])).toHaveLength(0);
  });
});

// One predicate for every count of a place's updates, so a card and Home
// can never disagree about one machine.
describe("what a place counts as out of date", () => {
  it("counts its own packages once, and no other place's", () => {
    const rows = [
      row("gh", "/a"),
      row("gh", "/b"),
      row("dev", "/a"),
      row("muted", "/a", { ignored: true }),
      row("current", "/a", { updateAvailable: false }),
    ];
    expect(outOfDateIn(rows, { scope: "project", root: "/a" })).toBe(2);
    expect(outOfDateIn(rows, { scope: "project", root: "/b" })).toBe(1);
    expect(outOfDateIn(rows, { scope: "global" })).toBe(0);
  });

  // News that is not a newer version belongs on the Updates page, which
  // lists it and tags it, and NOT in a count whose words promise an update:
  // core builds such a row with no `latest` and no update to take, so a
  // card counting it would draw a line whose review has nothing in it.
  it("counts no package that has no update to take", () => {
    const news = [
      {
        name: "gone from its source",
        extra: { updateAvailable: false, removedUpstream: true },
      },
      {
        name: "installs disagreeing on a version",
        extra: { updateAvailable: false, mixed: true },
      },
      { name: "muted", extra: { ignored: true } },
    ];
    expect(news).toHaveLength(3);
    for (const one of news) {
      const rows = [row("gh", "/a", one.extra)];
      expect(
        outOfDateIn(rows, { scope: "project", root: "/a" }),
        one.name,
      ).toBe(0);
      expect(
        availableUpdatesIn(rows, { scope: "project", root: "/a" }),
        one.name,
      ).toHaveLength(0);
      // Still the Updates page's business, so its own list keeps it.
      expect(visibleUpdates(rows).length, one.name).toBe(
        one.extra.ignored ? 0 : 1,
      );
    }
  });

  // The control: a row with a version to move to is counted, and is what
  // the review acts on.
  it("counts a package with a newer version, and hands it to the review", () => {
    const rows = [row("gh", "/a")];
    expect(outOfDateIn(rows, { scope: "project", root: "/a" })).toBe(1);
    expect(
      availableUpdatesIn(rows, { scope: "project", root: "/a" }).map(
        (r) => r.name,
      ),
    ).toEqual(["gh"]);
  });

  // Home's number and a card's number are the same rule, one machine-wide
  // and one narrowed, so they cannot come apart.
  it("counts machine-wide by the same rule", () => {
    const rows = [
      row("gh", "/a"),
      row("gh", "/b"),
      row("dev", "/a"),
      row("gone", "/a", { updateAvailable: false, removedUpstream: true }),
    ];
    expect(availableUpdateCount(rows)).toBe(2);
    expect(outOfDateIn(rows, { scope: "project", root: "/a" })).toBe(2);
  });
});
