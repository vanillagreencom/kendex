import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView_Serialize, EditorInventory } from "@/bindings";
import { commands } from "@/bindings";
import { emptyDraft } from "@/lib/editor-draft";
import { useEditorStore } from "./editor";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./settings", () => ({
  useSettingsStore: { getState: () => ({ settings: null, load: vi.fn() }) },
}));

const inventory = () => ({
  status: "ok" as const,
  data: {} as EditorInventory,
});

describe("editor store", () => {
  beforeEach(() => {
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: null,
      base: null,
      inventory: null,
      saved: {},
      dirty: false,
      loading: false,
      saving: false,
      error: null,
      stale: false,
    });
    vi.clearAllMocks();
    vi.mocked(commands.editorInventory).mockResolvedValue(inventory());
  });

  /// The base is what makes an existing manifest saveable at all: read
  /// with the copy, presented with the save. Sent null, every save of an
  /// existing file would be refused as a copy that predates it.
  it("holds the base it read and presents it with the save", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().base).toBe("b1");

    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    await useEditorStore.getState().save();
    expect(commands.updateManifest).toHaveBeenCalledWith(
      { scope: "global" },
      emptyDraft(),
      "b1",
    );
  });

  /// A stale refusal is a choice, not a failure: it must reach the page
  /// as the reload offer, never as a raw error — and a real failure must
  /// stay an error, never the reload offer.
  it("renders a stale refusal as the reload choice and a failure as an error", async () => {
    useEditorStore.setState({ draft: emptyDraft(), base: "b1" });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    await useEditorStore.getState().save();
    expect(useEditorStore.getState().stale).toBe(true);
    expect(useEditorStore.getState().error).toBeNull();

    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "disk is full" },
    });
    await useEditorStore.getState().save();
    expect(useEditorStore.getState().stale).toBe(false);
    expect(useEditorStore.getState().error).toBe("disk is full");
  });

  /// The reload is the way out of a stale refusal: it replaces the copy
  /// and its base together and clears the refusal, so the next save
  /// presents the base of the file it will actually be compared against.
  it("reload after a stale refusal takes the fresh copy and clears the refusal", async () => {
    useEditorStore.setState({
      draft: { schema: 1, "skill-instructions": { all: "unsaved edit" } },
      base: "b1",
      dirty: true,
      stale: true,
    });
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b2" },
    });

    await useEditorStore.getState().load();

    const state = useEditorStore.getState();
    expect(state.stale).toBe(false);
    expect(state.base).toBe("b2");
    expect(state.draft).toEqual(emptyDraft());
    expect(state.dirty).toBe(false);
  });
});
