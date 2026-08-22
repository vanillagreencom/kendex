import { describe, expect, it } from "vitest";
import { emptyDraft } from "@/lib/editor-draft";
import { changed, VG } from "@/lib/places-test-source";
import { manifestsOnScreen, readState } from "./customized-places";

// What each screen reads the standings from: which manifests are in hand,
// and how each of the two reads behind them went.

describe("readState", () => {
  it("tells a read still coming from one that came back with nothing", () => {
    expect(readState(false, null)).toBe("pending");
    expect(readState(false, "no network")).toBe("failed");
    expect(readState(true, null)).toBe("ready");
    // A read that answered is ready even if the last one before it failed.
    expect(readState(true, "no network")).toBe("ready");
  });
});

describe("manifestsOnScreen", () => {
  it("puts the draft in hand over the saved copy of the place being edited", () => {
    const saved = { global: emptyDraft(), "/work/vg": emptyDraft() };
    const manifests = manifestsOnScreen(saved, VG, changed());
    expect(manifests["/work/vg"]["skill-instructions"]).toEqual({
      gh: "use the CLI",
    });
    expect(manifests.global).toEqual(emptyDraft());
  });

  it("keeps every saved manifest when no draft is open", () => {
    const saved = { global: emptyDraft() };
    expect(manifestsOnScreen(saved, VG, null)).toBe(saved);
  });
});
