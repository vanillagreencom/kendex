import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { whyUnread } from "./editor-order";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    windowZoomState: vi.fn(),
  },
}));

beforeEach(() => {
  useSettingsStore.setState({
    settings: { schema: 1, projects: ["/work/vg"] },
  });
  vi.mocked(commands.editorInventory).mockResolvedValue({
    status: "ok",
    data: {
      declaredAgents: [],
      declaredSkills: [],
      availableSkills: [],
      harnesses: [],
      hookEvents: [],
    },
  });
  useEditorStore.setState({
    held: {},
    scope: { scope: "global" },
    draft: null,
    saved: {},
    manifestsLoaded: false,
    unreadPlaces: {},
    manifestsReading: false,
  });
});

// The marks read a place's manifest, and a place missing from `saved` is
// one they cannot speak for. Which of the two it is — never asked for, or
// asked for and refused — is the difference between a wait and a problem.
// A pass that cannot even find out which places there are got to none of
// them. What it still holds was read some time ago, and every mark drawn
// from it would be answering for a moment nobody has re-checked.
describe("a pass that could not reach any place", () => {
  it("leaves the manifests it kept, and lets none of them answer", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();
    // The control: a good pass leaves nothing unread.
    expect(useEditorStore.getState().saved["/work/vg"]).toBeDefined();
    expect(Object.keys(useEditorStore.getState().unreadPlaces)).toEqual([]);

    // The next pass cannot list the places at all.
    useSettingsStore.setState({ settings: null });
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: 100,
      launchRefused: false,
    });
    vi.mocked(commands.getSettings).mockRejectedValue(new Error("no settings"));
    await useEditorStore.getState().loadAll();

    const state = useEditorStore.getState();
    expect(state.manifestsLoaded).toBe(false);
    // Whatever the reason reads as, the pass has to have said one.
    expect(whyUnread(state)).toContain("settings");
    // Kept, so a mark does not vanish — and unread, so none of them speaks.
    expect(state.saved["/work/vg"]).toBeDefined();
    expect(Object.keys(state.unreadPlaces)).toContain("/work/vg");
    expect(Object.keys(state.unreadPlaces)).toContain("global");
  });
});

// The mark exists so a manifest kept from before a failure is not taken
// for current. A place whose own read then lands is current, and leaving
// the mark on would keep masking a place kendex can see.
describe("a place read on its own after a pass failed", () => {
  it("is no longer unread", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();
    useSettingsStore.setState({ settings: null });
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: 100,
      launchRefused: false,
    });
    vi.mocked(commands.getSettings).mockRejectedValue(new Error("no settings"));
    await useEditorStore.getState().loadAll();
    expect(Object.keys(useEditorStore.getState().unreadPlaces)).toContain(
      "global",
    );

    // Its own read lands.
    await useEditorStore.getState().load({ scope: "global" });
    expect(Object.keys(useEditorStore.getState().unreadPlaces)).not.toContain(
      "global",
    );
  });
});

// The mark travels with the reads, so it is ordered per place like the
// manifests are: a pass answers for the places it reached and for no
// others, and a read that lands about one place is not undone by an older
// pass that failed.
describe("how each place's read went", () => {
  it("marks a place whose own read failed, so its kept manifest is masked", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();
    expect(Object.keys(useEditorStore.getState().unreadPlaces)).toEqual([]);

    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "error",
      error: "would not parse",
    });
    await useEditorStore.getState().load({ scope: "global" });

    expect(Object.keys(useEditorStore.getState().unreadPlaces)).toContain(
      "global",
    );
    // Kept, so no mark vanishes mid-read — and masked, so it cannot speak.
    expect(useEditorStore.getState().saved.global).toBeDefined();
  });
});

// The two reads answer different questions, so one failing must not speak
// for the other: an inventory kendex could not fetch says nothing about
// whether this place's manifest was read.
