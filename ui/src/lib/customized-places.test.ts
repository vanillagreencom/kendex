import { describe, expect, it } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import {
  changed,
  EVERYWHERE,
  forkedHere,
  HYPR,
  source,
  VG,
} from "@/lib/places-test-source";
import {
  customizedPlaces,
  forkedPlaces,
  indexRows,
  type PlacesSource,
  placeStandings,
  standingIn,
} from "./customized-places";
import { type Draft, emptyDraft } from "./editor-draft";

const states = (over: Partial<PlacesSource> = {}) =>
  placeStandings(source(over), "skill", "gh", EVERYWHERE).map(
    (one) => one.state,
  );

describe("placeStandings", () => {
  it("marks the one place whose manifest changes the package", () => {
    expect(
      states({
        manifests: {
          global: emptyDraft(),
          "/work/vg": changed(),
          "/work/hyprtrade": emptyDraft(),
        },
      }),
    ).toEqual(["as-installed", "customized", "as-installed"]);
  });

  it("marks a place whose files were hand-edited while up to date", () => {
    const rows = indexRows([
      updateRow("gh", null, { updateAvailable: false }),
      updateRow("gh", "/work/vg", {
        updateAvailable: false,
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
      }),
      updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
    ]);
    expect(states({ rows })).toEqual([
      "as-installed",
      "customized",
      "as-installed",
    ]);
  });

  it("leaves a place with no update row unknown, never as installed", () => {
    const rows = indexRows([
      updateRow("gh", null, { updateAvailable: false }),
      updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
    ]);
    expect(states({ rows })).toEqual([
      "as-installed",
      "unknown",
      "as-installed",
    ]);
  });
  it("counts the places that are customized, not the installs", () => {
    const standings = placeStandings(
      source({
        manifests: {
          global: emptyDraft(),
          "/work/vg": changed(),
          "/work/hyprtrade": emptyDraft(),
        },
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(customizedPlaces(standings)).toEqual([VG]);
    expect(standingIn(standings, HYPR)?.state).toBe("as-installed");
    expect(standingIn(standings, { scope: "project", root: "/nowhere" })).toBe(
      null,
    );
  });

  it("matches a fork to the place it belongs to", () => {
    const standings = placeStandings(
      source({
        manifests: {
          global: emptyDraft(),
          "/work/vg": forkedHere(),
          "/work/hyprtrade": emptyDraft(),
        },
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(forkedPlaces(standings)).toEqual([VG]);
    expect(standingIn(standings, VG)?.state).toBe("customized");
  });

  it("knows a place is forked with no update standing to read", () => {
    const standings = placeStandings(
      source({
        manifests: {
          global: emptyDraft(),
          "/work/vg": forkedHere(),
          "/work/hyprtrade": emptyDraft(),
        },
        updatesRead: "pending",
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(forkedPlaces(standings)).toEqual([VG]);
    expect(standingIn(standings, HYPR)?.forked).toBe(false);
  });

  it("sends a fork and a hand edit to the files, and an overlay to the settings", () => {
    const change = (
      manifests: Record<string, Draft>,
      rows?: PlacesSource["rows"],
    ) =>
      placeStandings(
        source({ manifests, ...(rows ? { rows } : {}) }),
        "skill",
        "gh",
        EVERYWHERE,
      ).map((one) => one.change);
    const plain = {
      global: emptyDraft(),
      "/work/vg": emptyDraft(),
      "/work/hyprtrade": emptyDraft(),
    };
    expect(change({ ...plain, "/work/vg": changed() })).toEqual([
      null,
      "settings",
      null,
    ]);
    expect(change({ ...plain, "/work/vg": forkedHere() })).toEqual([
      null,
      "files",
      null,
    ]);
    expect(
      change(
        plain,
        indexRows([
          updateRow("gh", null, { updateAvailable: false }),
          updateRow("gh", "/work/vg", {
            updateAvailable: false,
            blockedByLocalEdit: true,
          }),
          updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
        ]),
      ),
    ).toEqual([null, "files", null]);
  });

  it("leads a hand edit to the files even where an overlay is also set", () => {
    const [, vg] = placeStandings(
      source({
        manifests: {
          global: emptyDraft(),
          "/work/vg": changed(),
          "/work/hyprtrade": emptyDraft(),
        },
        rows: indexRows([
          updateRow("gh", null, { updateAvailable: false }),
          updateRow("gh", "/work/vg", {
            updateAvailable: false,
            blockedByLocalEdit: true,
          }),
          updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
        ]),
      }),
      "skill",
      "gh",
      EVERYWHERE,
    );
    expect(vg.change).toBe("files");
  });

  it("reads another package's places as its own, never this one's", () => {
    expect(
      placeStandings(source(), "skill", "orch", EVERYWHERE).map((s) => s.state),
    ).toEqual(["unknown", "unknown", "unknown"]);
  });
});
