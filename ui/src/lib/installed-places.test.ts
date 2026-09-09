import { describe, expect, it } from "vitest";
import type { ProvenanceRow, Scope } from "@/bindings";
import {
  bundlePlaces,
  installedPlaces,
  placesKey,
} from "@/lib/installed-places";
import { subscription } from "@/stores/marketplaces-shared";

const catalog = subscription({ scope: "global" }, "kendex");
const hyprtrade: Scope = { scope: "project", root: "/home/me/hyprtrade" };
const vg: Scope = { scope: "project", root: "/home/me/vg" };

const installed = (
  scope: Scope,
  name: string,
  source: string,
  repo: string,
  harness: ProvenanceRow["harness"] = "claude",
): ProvenanceRow => ({
  scope,
  kind: "skill",
  name,
  harness,
  // One row per file, and the package the records say it is: this fixture
  // is about installations a marketplace put there.
  at: `${scope.scope === "project" ? scope.root : ""}/.${harness}/skills/${name}`,
  origin: { origin: "marketplace", source, repo },
  package: { kind: "skill", name },
});

// A subscription is a (scope, source, repository), not a name: the same
// alias can be declared in the personal manifest and in a project's,
// pointing at different repositories. A place named from the alias alone
// credits this marketplace with somebody else's installations.
describe("where a marketplace's packages are installed", () => {
  it("names the places holding it, and only from this marketplace", () => {
    const rows = [
      installed(hyprtrade, "gh", "kendex", "a/b"),
      // The same package, the same place, a second harness. One place.
      installed(hyprtrade, "gh", "kendex", "a/b", "codex"),
      // The alias this page carries, pointing somewhere else: another
      // subscription's installation, not this marketplace's.
      installed({ scope: "global" }, "gh", "kendex", "z/other"),
      // A different source entirely — a collision, which Status says.
      installed(vg, "gh", "other", "c/d"),
    ];

    const places = installedPlaces(rows, catalog, "a/b");

    expect([...places.keys()]).toEqual([placesKey("skill", "gh")]);
    expect(places.get(placesKey("skill", "gh"))).toEqual([hyprtrade]);
  });

  // A path-backed subscription has no repository at all, so a join keyed on
  // the declaration's own `repo` would leave every row of one unplaced.
  // Both sides carry what the subscription resolved to — a canonical path
  // here — which is what the lock recorded.
  it("names places for a subscription backed by a path", () => {
    const places = installedPlaces(
      [installed(hyprtrade, "gh", "kendex", "/home/me/catalogs/kit")],
      catalog,
      "/home/me/catalogs/kit",
    );

    expect(places.get(placesKey("skill", "gh"))).toEqual([hyprtrade]);
  });

  // Personal leads wherever places are listed, so a package's places and its
  // marketplace's own list of places never read in two orders on one page.
  it("orders personal before projects", () => {
    const places = installedPlaces(
      [
        installed(vg, "gh", "kendex", "a/b"),
        installed({ scope: "global" }, "gh", "kendex", "a/b"),
        installed(hyprtrade, "gh", "kendex", "a/b"),
      ],
      catalog,
      "a/b",
    );

    expect(places.get(placesKey("skill", "gh"))).toEqual([
      { scope: "global" },
      hyprtrade,
      vg,
    ]);
  });

  // A page that has not read the catalog knows no resolved reference, and a
  // repository nobody subscribes to owns no installation at all. Neither
  // answers from the alias alone.
  it("answers nothing without a resolved reference or a subscription", () => {
    const rows = [installed(hyprtrade, "gh", "kendex", "a/b")];

    expect(installedPlaces(rows, catalog, null).size).toBe(0);
    expect(installedPlaces(rows, { by: "repo", repo: "a/b" }, "a/b").size).toBe(
      0,
    );
  });
});

// A set is installed in a place the moment part of it is — the card's badge
// says how much — so a member that landed somewhere else still names that
// place, once.
describe("where a curated set is installed", () => {
  it("unions its members' places and names each one once", () => {
    const places = installedPlaces(
      [
        installed({ scope: "global" }, "gh", "kendex", "a/b"),
        installed(hyprtrade, "gh", "kendex", "a/b"),
        installed(hyprtrade, "review", "kendex", "a/b"),
      ],
      catalog,
      "a/b",
    );

    expect(
      bundlePlaces(places, [
        { kind: "skill", name: "gh" },
        { kind: "skill", name: "review" },
        { kind: "skill", name: "never-installed" },
      ]),
    ).toEqual([{ scope: "global" }, hyprtrade]);
  });
});
