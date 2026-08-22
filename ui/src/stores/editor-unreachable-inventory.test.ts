import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
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

// The other half of the same read. A place's manifest and the choices its
// form offers are fetched together and answer different questions, so one
// failing must not speak for the other: a manifest that read fine still
// draws its marks, and a form with nothing to offer says so rather than
// offering the last place's skills to a save about this one.
describe("when only the inventory read fails", () => {
  it("keeps the manifest and leaves the place readable", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "read" },
    });
    vi.mocked(commands.editorInventory).mockRejectedValue(
      new Error("the bridge went away"),
    );

    await useEditorStore.getState().load({ scope: "global" });

    const state = useEditorStore.getState();
    expect(Object.keys(state.unreadPlaces)).not.toContain("global");
    expect(state.saved.global).toBeDefined();
    // The failure is still said out loud rather than swallowed.
    expect(state.error).toContain("bridge went away");
  });
});

// The choices a form offers belong to the place it is about. After a move
// the inventory in hand belongs to where you were — so keeping it when the
// new place's read fails offers one project's skills while saving another
// project's file. The typed draft is the case that matters: it comes back
// to its own place, and the choices beside it must not follow it there.
describe("returning to a parked draft when its inventory will not read", () => {
  const stocked = {
    declaredAgents: [],
    declaredSkills: ["from-the-other-place"],
    availableSkills: ["from-the-other-place"],
    harnesses: [],
    hookEvents: [],
  };

  it("offers nothing rather than the place you came from", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "read" },
    });
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "ok",
      data: stocked,
    });

    // Typing at one place, then away to another: the draft parks.
    await useEditorStore.getState().setScope({ scope: "global" });
    useEditorStore.setState({
      draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
      dirty: true,
    });
    await useEditorStore
      .getState()
      .setScope({ scope: "project", root: "/work/vg" });
    expect(useEditorStore.getState().inventory).toEqual(stocked);

    // Back again, and this place's inventory will not come. The draft
    // returns — it is the person's — and the choices do not.
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "error",
      error: "the inventory would not read",
    });
    await useEditorStore.getState().setScope({ scope: "global" });

    const state = useEditorStore.getState();
    expect(state.dirty).toBe(true);
    expect(state.draft?.["skill-instructions"]).toEqual({ gh: "mine" });
    expect(state.inventory).toBeNull();
    expect(state.error).toContain("would not read");
  });
});

// The move itself, before any read answers. The draft travels with the
// person; the choices belong to the place, so between leaving one and
// hearing from the other the form has nothing of its own to offer — and a
// manifest read that fails leaves it that way rather than stocked from
// where you were.
describe("the moment of moving between places", () => {
  const stocked = {
    declaredAgents: [],
    declaredSkills: ["from-the-other-place"],
    availableSkills: ["from-the-other-place"],
    harnesses: [],
    hookEvents: [],
  };

  it("offers nothing until this place answers, and after it fails to", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "read" },
    });
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "ok",
      data: stocked,
    });
    await useEditorStore.getState().setScope({ scope: "global" });
    expect(useEditorStore.getState().inventory).toEqual(stocked);

    // The next place's manifest will not read at all.
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "error",
      error: "would not parse",
    });
    const moving = useEditorStore
      .getState()
      .setScope({ scope: "project", root: "/work/vg" });
    // Before anything lands: the form is already this place's, and empty.
    expect(useEditorStore.getState().inventory).toBeNull();
    await moving;
    // And a failed read leaves it empty rather than stocked from before.
    expect(useEditorStore.getState().inventory).toBeNull();
  });
});
