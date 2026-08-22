// The four windows a caller can leave open between a write landing and the
// editor being told. These hold the helper itself to the rule rather than
// each caller in turn, since the list of callers is not fixed: the place is
// refused before anything is awaited, and no read replaces typing that
// arrives while it is on its way.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { whyUnread } from "./editor-order";
import { manifestRewritten } from "./manifest-sync";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), message: vi.fn(), info: vi.fn() },
}));

const scope = { scope: "global" as const };
const typed = { schema: 1, install: {}, "skill-instructions": { gh: "mine" } };

const inventory = {
  declaredAgents: [],
  declaredSkills: [],
  availableSkills: [],
  harnesses: [],
  hookEvents: [],
};

/** Typing arrives in the Customize tab. */
const type = () => useEditorStore.setState({ draft: typed, dirty: true });

/** The save the user presses in the window under test. */
const press = () => void useEditorStore.getState().save();

const refused = () => {
  expect(commands.updateManifest).not.toHaveBeenCalled();
  expect(useProblemsStore.getState().dialog.title).toContain(
    "changed while you typed",
  );
};

describe("the sync refuses before it reads", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    useEditorStore.setState({
      scope,
      draft: { schema: 1, install: {} },
      dirty: false,
      outdated: null,
      saved: {},
    });
    useProblemsStore.getState().closeError();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "ok",
      data: inventory,
    });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
  });

  it("refuses a save pressed while the manifests are still being read", async () => {
    type();
    // Not awaited: the press has to land inside the call, which is the
    // window this is about — awaiting it first would test nothing.
    const syncing = manifestRewritten(scope);
    press();
    await syncing;

    refused();
    expect(useEditorStore.getState().draft).toEqual(typed);
  });

  it("keeps typing that arrives while the re-read is on its way", async () => {
    // Something rewrote the file, which is what this is called about, so
    // the reads answer with the file it is now. Read 1 answers the pass
    // over every place; read 2 is its re-read of the open one, and the
    // typing lands while that is in flight.
    useEditorStore.setState({ base: "before" });
    let reads = 0;
    vi.mocked(commands.getManifest).mockImplementation(async () => {
      reads += 1;
      if (reads === 2) type();
      return { status: "ok", data: { manifest: null, base: "after" } };
    });

    await manifestRewritten(scope);

    const after = useEditorStore.getState();
    expect(after.draft).toEqual(typed);
    expect(after.dirty).toBe(true);
    expect(after.outdated).toBe("global");
    // The place's manifest still reached the marks, which is what the read
    // was for; only the draft was left alone.
    expect(after.saved.global).toBeDefined();
    press();
    refused();
  });

  it("takes the file back when the copy in hand is untouched", async () => {
    await manifestRewritten(scope);

    const after = useEditorStore.getState();
    expect(after.dirty).toBe(false);
    expect(after.outdated).toBeNull();
  });

  // Most of what calls this rewrites installed files and the lock and never
  // touches kendex.toml — an ordinary update is one. The mark is about the
  // file having moved under the copy in hand, so it is measured, not
  // assumed: a protection that cries wolf teaches people to reload away
  // their own typing.
  it("leaves a draft alone when the file never moved", async () => {
    useEditorStore.setState({ base: "unmoved" });
    type();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "unmoved" },
    });

    await manifestRewritten(scope);

    const after = useEditorStore.getState();
    expect(after.outdated).toBeNull();
    expect(after.draft).toEqual(typed);
    // And the save it was about to refuse reaches the write.
    await useEditorStore.getState().save();
    expect(commands.updateManifest).toHaveBeenCalled();
  });

  it("marks it when the file did move", async () => {
    useEditorStore.setState({ base: "before" });
    type();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "after" },
    });

    await manifestRewritten(scope);

    expect(useEditorStore.getState().outdated).toBe("global");
  });

  // A read that never arrives cannot report the file unmoved, and the caller
  // that started this walked away — so a rejection here has to be turned
  // into a refusal and a message rather than into a lost promise.
  it("keeps the place refused when the re-read never arrives", async () => {
    useEditorStore.setState({ base: "before", unreadPlaces: {} });
    type();
    vi.mocked(commands.getManifest)
      .mockResolvedValueOnce({
        status: "ok",
        data: { manifest: null, base: "before" },
      })
      .mockRejectedValueOnce(new Error("the channel closed"));

    await expect(manifestRewritten(scope)).resolves.toBeUndefined();

    const after = useEditorStore.getState();
    expect(after.outdated).toBe("global");
    expect(whyUnread(after)).toContain("the channel closed");
    expect(after.draft).toEqual(typed);
  });

  it("leaves a place it is not about alone", async () => {
    type();
    await manifestRewritten({ scope: "project", root: "/w/app" });

    expect(useEditorStore.getState().outdated).toBeNull();
  });
});
