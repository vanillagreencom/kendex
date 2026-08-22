import { describe, expect, it } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { changed, EVERYWHERE, source } from "@/lib/places-test-source";
import {
  indexRows,
  type PlacesSource,
  placeStandings,
} from "./customized-places";
import { emptyDraft } from "./editor-draft";

const states = (over: Partial<PlacesSource> = {}) =>
  placeStandings(source(over), "skill", "gh", EVERYWHERE).map(
    (one) => one.state,
  );

// What a mark says while the reads behind it are still going, and after one
// of them could not answer. Three states, and the difference between them
// is the whole point: a place nobody has asked about, a place being asked
// about now, and a place whose read came back unable to say.
describe("a mark while its reads are in flight", () => {
  // A project registered after the first pass has neither manifest nor row
  // while its own reads run, and both stores still say a read succeeded —
  // theirs just is not among them yet.
  it("says a place added later is being checked, not unchecked", () => {
    const newcomer = {
      manifests: { global: emptyDraft(), "/work/vg": emptyDraft() },
      rows: indexRows([
        updateRow("gh", null, { updateAvailable: false }),
        updateRow("gh", "/work/vg", { updateAvailable: false }),
      ]),
    };
    // Both reads have come back once, and neither is running: nobody has
    // asked about this place, and the mark says so.
    expect(states(newcomer)).toEqual([
      "as-installed",
      "as-installed",
      "unknown",
    ]);
    // Now its reads are on their way.
    expect(states({ ...newcomer, manifestsReading: true })).toEqual([
      "as-installed",
      "as-installed",
      "checking",
    ]);
    expect(states({ ...newcomer, updatesReading: true })).toEqual([
      "as-installed",
      "as-installed",
      "checking",
    ]);
  });

  // A pass runs for every place at once. Places whose facts are already in
  // hand must sit still through it rather than blinking through "checking".
  it("leaves the places it already knows alone while a pass runs", () => {
    expect(states({ manifestsReading: true, updatesReading: true })).toEqual([
      "as-installed",
      "as-installed",
      "as-installed",
    ]);
  });

  it("says a place is still being checked while the reads are on their way", () => {
    expect(states({ updatesRead: "pending" })).toEqual([
      "checking",
      "checking",
      "checking",
    ]);
    // A manifest nobody has asked for yet is not one that failed.
    expect(
      states({
        manifests: { global: emptyDraft(), "/work/vg": emptyDraft() },
        manifestsRead: "pending",
      }),
    ).toEqual(["as-installed", "as-installed", "checking"]);
  });

  // A read that came back with nothing will not run again on its own, so
  // calling it in-flight promises a resolution that is never coming.
  it("says a failed read could not tell, never that it is still trying", () => {
    expect(states({ updatesRead: "failed" })).toEqual([
      "unknown",
      "unknown",
      "unknown",
    ]);
    expect(
      states({
        manifests: { global: emptyDraft(), "/work/vg": emptyDraft() },
        manifestsRead: "failed",
      }),
    ).toEqual(["as-installed", "as-installed", "unknown"]);
  });

  it("leaves a place whose manifest could not be read unknown", () => {
    expect(
      states({ manifests: { global: emptyDraft(), "/work/vg": emptyDraft() } }),
    ).toEqual(["as-installed", "as-installed", "unknown"]);
  });

  it("still marks a place the manifest changes when its files are unknown", () => {
    expect(
      states({
        manifests: {
          global: emptyDraft(),
          "/work/vg": changed(),
          "/work/hyprtrade": emptyDraft(),
        },
        rows: indexRows([updateRow("gh", null, { updateAvailable: false })]),
      }),
    ).toEqual(["as-installed", "customized", "unknown"]);
  });
});
