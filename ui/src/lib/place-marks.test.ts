import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { groupItems } from "@/lib/derive";
import { observedItem } from "@/lib/observed-test-item";
import {
  changed,
  EVERYWHERE,
  forkedHere,
  HYPR,
  plainManifests,
  source,
  VG,
} from "@/lib/places-test-source";
import {
  customizedPlaces,
  indexRows,
  placeStandings,
  standingIn,
} from "./customized-places";
import { type Draft, emptyDraft } from "./editor-draft";
import { customizeNav, markTarget, packageMarks } from "./place-marks";

// Where a mark leads once it is drawn, and which place each of a package
// page's own marks speaks for.

describe("markTarget", () => {
  it("leads a hand edit to its notice, even where the place is forked and overlaid", () => {
    // The notice renders for a fork too — its keep-as-your-own half is
    // spent, but the copy it kept is still there to put back — so the hand
    // edit outranks the overlay here as it does anywhere else.
    const both = {
      ...forkedHere(),
      "skill-instructions": { gh: "use the CLI" },
    };
    const standings = placeStandings(
      source({
        manifests: { ...plainManifests(), "/work/vg": both },
        rows: indexRows([
          updateRow("gh", null, { updateAvailable: false }),
          updateRow("gh", "/work/vg", {
            updateAvailable: false,
            forked: true,
            blockedByLocalEdit: true,
            canDiscard: true,
          }),
          updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
        ]),
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(markTarget(standings)).toEqual({ scope: VG });
  });

  it("leads to the tab that holds the settings, even where the place is forked", () => {
    // A fork is the standing state of this place; instructions typed on the
    // Customize tab are the thing someone went and did. The mark must not
    // walk past them to the overview.
    const both = {
      ...forkedHere(),
      "skill-instructions": { gh: "use the CLI" },
    };
    const standings = placeStandings(
      source({ manifests: { ...plainManifests(), "/work/vg": both } }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(markTarget(standings)).toEqual({
      scope: VG,
      view: { mode: "customize" },
    });
    expect(standingIn(standings, VG)?.forked).toBe(true);
  });

  const targetFor = (manifests: Record<string, Draft>) =>
    markTarget(
      placeStandings(source({ manifests }), "skill", "gh", EVERYWHERE),
    );
  const plain = {
    global: emptyDraft(),
    "/work/vg": emptyDraft(),
    "/work/hyprtrade": emptyDraft(),
  };

  it("opens the Customize tab of the place whose settings were changed", () => {
    expect(targetFor({ ...plain, "/work/vg": changed() })).toEqual({
      scope: VG,
      view: { mode: "customize" },
    });
  });

  it("opens the overview where the change is in the files", () => {
    expect(targetFor({ ...plain, "/work/vg": forkedHere() })).toEqual({
      scope: VG,
    });
  });

  it("leads nowhere when no place is changed", () => {
    expect(targetFor(plain)).toBe(null);
  });
});

describe("markTarget", () => {
  it("opens the first place the mark names, so the label can say where", () => {
    const standings = placeStandings(
      source({
        manifests: {
          global: emptyDraft(),
          "/work/vg": changed(),
          "/work/hyprtrade": changed(),
        },
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    // The Library's label names customizedPlaces[0]; the click must land
    // there, or the mark sends the reader somewhere it never mentioned.
    expect(markTarget(standings)?.scope).toEqual(
      customizedPlaces(standings)[0],
    );
    expect(customizedPlaces(standings)).toEqual([VG, HYPR]);
  });
});

describe("customizeNav", () => {
  it("opens the tab that wrote what the index is listing", () => {
    // Every row on the Customize index is an overlay written on that tab,
    // so landing on the overview would be landing away from it.
    expect(customizeNav({ kind: "skill", name: "gh", scope: VG })).toEqual([
      { kind: "skill", name: "gh", scope: VG },
      { mode: "customize" },
    ]);
  });
});

// Every fact a package page derives before it renders, from one call.
// Derived apart, they can disagree about which place the page is about —
// the header naming one, the actions writing another — so each case pins a
// different fact to the same opened place.
describe("packageMarks", () => {
  const installs = [
    observedItem({ name: "gh", scope: { scope: "global" }, path: "/h/gh" }),
    observedItem({ name: "gh", scope: VG, path: "/work/vg/gh" }),
    observedItem({ name: "gh", scope: HYPR, path: "/work/hyprtrade/gh" }),
  ];
  const marks = (opened: Scope, items = installs) =>
    packageMarks(
      source({
        manifests: { ...plainManifests(), "/work/vg": forkedHere() },
        rows: indexRows([
          updateRow("gh", null, { updateAvailable: false }),
          updateRow("gh", "/work/vg", { updateAvailable: false }),
          updateRow("gh", "/work/hyprtrade", {
            updateAvailable: false,
            blockedByLocalEdit: true,
          }),
        ]),
      }),
      groupItems(items)[0],
      opened,
    );

  it("is about the place the page was opened at, not the first install", () => {
    expect(marks(HYPR).primary?.path).toBe("/work/hyprtrade/gh");
    expect(marks(VG).primary?.path).toBe("/work/vg/gh");
  });

  it("speaks for the place the page was opened at, and only that one", () => {
    // Whatever the Customize tab has open, the header names the place the
    // installation, the actions and the notice below it are about.
    expect(marks(HYPR).selected?.scope).toEqual(HYPR);
    expect(marks(VG).selected?.scope).toEqual(VG);
  });

  it("reads the hand edit off the place the page is about", () => {
    expect(marks(HYPR).editedRow?.scope).toEqual(HYPR);
    expect(marks(VG).editedRow).toBe(null);
  });

  it("has no installation to speak for where the place holds none", () => {
    // The page's cue to leave the way the reader came, rather than
    // describing a location nobody asked about.
    expect(marks(HYPR, installs.slice(0, 2)).primary).toBe(null);
  });
});
