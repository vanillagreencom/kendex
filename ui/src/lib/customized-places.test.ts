import { describe, expect, it } from "vitest";
import type { Scope, UpdateRow } from "@/bindings";
import type { Draft } from "@/lib/editor-draft";
import { libraryMark } from "@/lib/place-marks";
import {
  customizedHere,
  indexCustomized,
  indexRows,
  type PlacesSource,
  placeStandings,
} from "./customized-places";

const GLOBAL: Scope = { scope: "global" };
const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const empty = (): Draft => ({ schema: 1, install: {} });

const withSetting = (): Draft => ({
  schema: 1,
  install: {},
  "skill-instructions": { gh: "mine" },
});

function row(scope: Scope, over: Partial<UpdateRow> = {}): UpdateRow {
  return {
    scope,
    kind: "skill",
    name: "gh",
    source: "cat",
    repo: "o/r",
    repoIdentity: "o/r",
    current: null,
    latest: null,
    updateAvailable: false,
    pinned: false,
    holdOwner: null,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forkableHarness: null,
    canDiscard: false,
    forked: false,
    ...over,
  } as UpdateRow;
}

function source(over: Partial<PlacesSource> = {}): PlacesSource {
  const manifests = over.manifests ?? {};
  return {
    manifests,
    rows: new Map(),
    updatesLoaded: true,
    settings: indexCustomized(manifests),
    ...over,
  };
}

describe("placeStandings", () => {
  it("marks only the place that holds the change", () => {
    const s = source({
      manifests: {
        global: empty(),
        "/work/vg": withSetting(),
        "/work/hyprtrade": empty(),
      },
      rows: indexRows([row(GLOBAL), row(VG), row(HYPR)]),
    });
    const got = placeStandings(s, "skill", "gh", [GLOBAL, VG, HYPR]);
    expect(got.map((p) => p.standing)).toEqual([
      "stock",
      "customized",
      "stock",
    ]);
    expect(got[1].why).toBe("settings");
  });

  it("counts a hand-edited place even when nothing is out of date", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: indexRows([row(VG, { blockedByLocalEdit: true })]),
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("edited");
  });

  it("counts a forked place from its own manifest", () => {
    const forkedDraft: Draft = {
      schema: 1,
      install: {},
      forks: { skill: { gh: { source: "local", "forked-at": "2026-01-01" } } },
    };
    const s = source({ manifests: { "/work/vg": forkedDraft } });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("forked");
  });

  // A place the app never read must not be reported as the author wrote
  // it: not knowing and knowing it is clean are different answers.
  it("leaves a place whose manifest was never read unknown", () => {
    const s = source({ manifests: {}, rows: indexRows([row(VG)]) });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  it("leaves a local-source place unknown: the engine has no row for it", () => {
    const s = source({ manifests: { "/work/vg": empty() }, rows: new Map() });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  it("does not call a place stock before the update read has landed", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: new Map(),
      updatesLoaded: false,
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  // The row is re-read with the write; the saved manifest is not. Reading
  // only the manifest loses the fork at the moment it is made.
  it("takes a fork the row knows about but the saved manifest predates", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: indexRows([row(VG, { forked: true })]),
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("forked");
  });
});

describe("customizedHere", () => {
  // The Library marks a hand-edited package "Customized in vg"; the page
  // headed "Customized packages" for vg has to list it, or the mark leads
  // to a page that denies it.
  it("lists a hand-edit-only package the Library row marks", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: indexRows([row(VG, { blockedByLocalEdit: true })]),
    });
    expect(libraryMark(placeStandings(s, "skill", "gh", [VG]))?.label).toBe(
      "Customized in vg",
    );
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", why: "edited" },
    ]);
  });

  it("lists a fork recorded in the manifest, with its settings", () => {
    const manifest: Draft = {
      ...withSetting(),
      forks: { skill: { gh: { source: "cat", repo: "o/r" } as never } },
    };
    const s = source({ manifests: { "/work/vg": manifest } });
    expect(customizedHere(s, VG)).toMatchObject([
      {
        kind: "skill",
        name: "gh",
        why: "forked",
        customization: { instructions: "mine" },
      },
    ]);
  });

  it("lists a settings-only package with what was set", () => {
    const s = source({ manifests: { "/work/vg": withSetting() } });
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", why: "settings" },
    ]);
  });

  it("leaves out stock rows and other places' settings", () => {
    const s = source({
      manifests: { "/work/vg": empty(), "/work/hyprtrade": withSetting() },
      rows: indexRows([row(VG), row(HYPR, { blockedByLocalEdit: true })]),
    });
    expect(customizedHere(s, VG)).toEqual([]);
  });

  // Before the update read lands, a hand edit is not a fact anyone holds;
  // the list is the manifest's until it does, never a guess.
  it("holds a hand edit back until the update read has landed", () => {
    const s = source({
      manifests: { "/work/vg": withSetting() },
      rows: indexRows([
        row(VG, { blockedByLocalEdit: true }),
        row(VG, { kind: "agent", name: "orch", blockedByLocalEdit: true }),
      ]),
      updatesLoaded: false,
    });
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", why: "settings" },
    ]);
  });

  it("orders agents before skills, each by name", () => {
    const s = source({
      manifests: { "/work/vg": withSetting() },
      rows: indexRows([
        row(VG, { name: "zed", blockedByLocalEdit: true }),
        row(VG, { kind: "agent", name: "orch", forked: true }),
      ]),
    });
    expect(customizedHere(s, VG).map((r) => `${r.kind}:${r.name}`)).toEqual([
      "agent:orch",
      "skill:gh",
      "skill:zed",
    ]);
  });
});
