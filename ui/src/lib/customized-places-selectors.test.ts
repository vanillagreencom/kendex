import { describe, expect, it } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import {
  changed,
  EVERYWHERE,
  HYPR,
  plainManifests,
  source,
  VG,
} from "@/lib/places-test-source";
import {
  anyCustomized,
  customizedPlaces,
  editedRowIn,
  forkedPlaces,
  indexRows,
  type PlacesSource,
  placeStandings,
  rowIn,
  uncheckedPlaces,
} from "./customized-places";
import { type Draft, emptyDraft } from "./editor-draft";

// What a list of standings answers: which places are yours, which hold a
// fork, how many nothing could be said about, and the rows behind them.

describe("rowIn", () => {
  it("hands back one place's row, so a page reads it instead of scanning", () => {
    const places = source();
    expect(rowIn(places, "skill", "gh", VG)?.scope).toEqual(VG);
    expect(rowIn(places, "skill", "gh", { scope: "project", root: "/x" })).toBe(
      null,
    );
    expect(rowIn(places, "agent", "gh", VG)).toBe(null);
  });
});

describe("anyCustomized", () => {
  it("answers the colour key's question without building a list", () => {
    const standings = (manifests: Record<string, Draft>) =>
      placeStandings(source({ manifests }), "skill", "gh", EVERYWHERE);
    expect(anyCustomized(standings(plainManifests()))).toBe(false);
    expect(
      anyCustomized(standings({ ...plainManifests(), "/work/vg": changed() })),
    ).toBe(true);
  });
});

// The fork fact is about this package in this place, not about the place.

describe("the fork behind a standing", () => {
  it("falls back to the engine's row where the manifest could not be read", () => {
    // Two readers of the same fact, and a surface reading one of them
    // while the engine reads the other offers actions the engine refuses.
    const standings = placeStandings(
      source({
        manifests: { global: emptyDraft(), "/work/hyprtrade": emptyDraft() },
        rows: indexRows([
          updateRow("gh", null, { updateAvailable: false }),
          updateRow("gh", "/work/vg", { updateAvailable: false, forked: true }),
          updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
        ]),
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(forkedPlaces(standings)).toEqual([VG]);
  });

  it("reads the fork of this package, never of whatever else that place forked", () => {
    const otherFork = {
      ...emptyDraft(),
      forks: { skill: { rev: { source: "cat", "forked-at": "2026-08-01" } } },
    };
    const standings = placeStandings(
      source({ manifests: { ...plainManifests(), "/work/vg": otherFork } }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(forkedPlaces(standings)).toEqual([]);
    expect(customizedPlaces(standings)).toEqual([]);
  });
});

describe("uncheckedPlaces", () => {
  it("counts only the places a read came back unable to speak for", () => {
    const standings = (over: Partial<PlacesSource>) =>
      placeStandings(source(over), "skill", "gh", EVERYWHERE);
    const changedOne = {
      manifests: {
        global: emptyDraft(),
        "/work/vg": changed(),
        "/work/hyprtrade": emptyDraft(),
      },
    };
    expect(uncheckedPlaces(standings(changedOne))).toBe(0);
    // A read on its way is not one a mark must apologise for: every launch
    // would otherwise open by calling places unchecked and then take it back.
    expect(
      uncheckedPlaces(standings({ ...changedOne, updatesRead: "pending" })),
    ).toBe(0);
    expect(
      uncheckedPlaces(
        standings({
          ...changedOne,
          rows: indexRows([updateRow("gh", null, { updateAvailable: false })]),
        }),
      ),
    ).toBe(1);
  });
});

describe("editedRowIn", () => {
  const edited = (over: Parameters<typeof updateRow>[2]) =>
    source({
      rows: indexRows([
        updateRow("gh", "/work/vg", { updateAvailable: false, ...over }),
      ]),
    });

  it("is the row only where this place's files were edited by hand", () => {
    expect(
      editedRowIn(edited({ blockedByLocalEdit: true }), "skill", "gh", VG)
        ?.scope,
    ).toEqual(VG);
    // Any other row means no edit: the Update button stays on and the
    // keep-or-discard notice stays off.
    expect(editedRowIn(edited({}), "skill", "gh", VG)).toBe(null);
    expect(
      editedRowIn(edited({ blockedByLocalEdit: true }), "skill", "gh", HYPR),
    ).toBe(null);
  });
});

// The page's header, its edited-files notice and its Update button are all
// about one place each. One join answers for all of them.
