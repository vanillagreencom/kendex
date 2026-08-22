import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: { getManifest: vi.fn(), editorInventory: vi.fn() },
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

// The window comes back and another process has rewritten the place the
// editor is on. A clean draft is the file's, not the person's: holding it
// leaves the form, the chips and the header showing settings that are
// already gone, and only the save would ever say so.
describe("a pass over the place the editor is on", () => {
  const onDisk = (note: string) => ({
    status: "ok" as const,
    data: {
      manifest: { schema: 1, install: {}, "skill-instructions": { gh: note } },
      base: note,
    },
  });

  it("puts the newer file in front of a draft with nothing typed in it", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue(onDisk("as it was"));
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().draft?.["skill-instructions"]).toEqual({
      gh: "as it was",
    });

    vi.mocked(commands.getManifest).mockResolvedValue(onDisk("rewritten"));
    await useEditorStore.getState().loadAll();

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "rewritten" });
    // The base comes with it, or the next save is refused for a change
    // nobody made.
    expect(after.base).toBe("rewritten");
  });

  it("leaves a draft with typing in it exactly where it is", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue(onDisk("as it was"));
    await useEditorStore.getState().load();
    useEditorStore.getState().edit((draft) => ({
      ...draft,
      "skill-instructions": { gh: "mine, unsaved" },
    }));

    vi.mocked(commands.getManifest).mockResolvedValue(onDisk("rewritten"));
    await useEditorStore.getState().loadAll();

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({
      gh: "mine, unsaved",
    });
    expect(after.dirty).toBe(true);
    // And the base stays the one that draft came from, which is what
    // refuses its save.
    expect(after.base).toBe("as it was");
  });
});
