import { describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import {
  groupUpdates,
  packageCount,
  placeName,
  skippedPlaces,
  updatablePlaces,
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
  derived: false,
  removedUpstream: false,
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
      row("gh", "/a", { repo: "vanillagreencom/vstack" }),
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
