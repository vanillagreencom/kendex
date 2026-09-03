import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  EditorInventory,
  Scope,
  ScopeSettings,
  WriteRefused,
} from "@/bindings";
import { commands } from "@/bindings";
import { placeFacts, placesSource } from "@/lib/customized-places";
import { groupItems } from "@/lib/derive";
import { emptyDraft, setInstruction } from "@/lib/editor-draft";
import { markFor } from "@/lib/package-mark";
import { scopeKey } from "@/lib/scope";
import { openInventory, useEditorStore } from "./editor";

// The real module comes through, with only the commands stubbed: the
// constants it exports are the numbers the code under test writes into a
// draft, and a second copy of one here is the drift the export removed.
vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    getScopeSettings: vi.fn(),
    saveCustomize: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
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

const settings = (base: string | null = "s1"): ScopeSettings => ({
  applies: true,
  skills: [
    {
      skill: "gh",
      template: {
        state: "rows",
        rows: [
          {
            key: "GH_MODE",
            explainer: ["what it does"],
            default: "enforce",
            current: { state: "value", value: "enforce", line: 3 },
          },
        ],
      },
    },
  ],
  base,
});

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const edit = {
  skill: "gh",
  key: "GH_MODE",
  value: { kind: "set" as const, value: "advise" },
};

describe("editor store", () => {
  beforeEach(() => {
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: null,
      base: null,
      saved: {},
      inventories: {},
      settings: null,
      settingsEdits: [],
      savedSettings: {},
      dirty: false,
      manifestDirty: false,
      loading: false,
      saving: false,
      error: null,
      stale: false,
    });
    vi.clearAllMocks();
    vi.mocked(commands.editorInventory).mockResolvedValue(inventory());
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: settings(),
    });
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

    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    useEditorStore
      .getState()
      .edit((draft) => setInstruction(draft, "skill-instructions", "gh", "x"));
    await useEditorStore.getState().save();
    expect(commands.saveCustomize).toHaveBeenCalledWith(
      { scope: "global" },
      {
        manifest: setInstruction(emptyDraft(), "skill-instructions", "gh", "x"),
        base: "b1",
      },
      null,
    );
  });

  /// A manifest saved with a package deleted out of it takes that package
  /// away, so this route runs the leaving package's uninstaller like any
  /// other removal — and the editor is the one write that does not go
  /// through the update commands, so it says so itself.
  it("says what a save that dropped a package ran in the repository", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {
        ...({} as AuditView_Serialize),
        undone: [
          "growth-guards: running scripts/install-git-hooks --uninstall",
        ],
      },
    });
    useEditorStore
      .getState()
      .edit((draft) => setInstruction(draft, "skill-instructions", "gh", "x"));

    await useEditorStore.getState().save();

    expect(toast.message).toHaveBeenCalledWith(
      "growth-guards: running scripts/install-git-hooks --uninstall",
    );
  });

  it("stays quiet when a save took no armed package away", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    useEditorStore
      .getState()
      .edit((draft) => setInstruction(draft, "skill-instructions", "gh", "x"));

    await useEditorStore.getState().save();

    expect(toast.message).not.toHaveBeenCalled();
  });

  it("stays quiet when a save is refused as stale", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    useEditorStore
      .getState()
      .edit((draft) => setInstruction(draft, "skill-instructions", "gh", "x"));

    await useEditorStore.getState().save();

    expect(useEditorStore.getState().stale).toBe(true);
    expect(toast.message).not.toHaveBeenCalled();
  });

  /// The manifest is not the settings file: a settings change reconciles
  /// the scope against the manifest on disk, and sending the copy on
  /// screen back would rewrite a kendex.toml nobody touched.
  it("carries no manifest for a save that only changes settings", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    await useEditorStore.getState().load();
    useEditorStore.getState().editSetting(edit);
    expect(useEditorStore.getState().dirty).toBe(true);

    await useEditorStore.getState().save();
    expect(commands.saveCustomize).toHaveBeenCalledWith(
      { scope: "global" },
      null,
      { edits: [edit], base: "s1" },
    );
  });

  /// The base travels with the rows it was read beside: sent the base of
  /// a file these rows did not come from, a save would write over
  /// somebody else's newer copy instead of being refused.
  it("presents the settings base its rows were read with", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: settings("s2"),
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().settings?.base).toBe("s2");
    expect(useEditorStore.getState().savedSettings.global?.base).toBe("s2");
  });

  /// A read nobody could make is said out loud: a Settings section that
  /// is merely missing looks exactly like a skill that ships none.
  it("says so when the settings read fails", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().settings).toBeNull();
    expect(useEditorStore.getState().error).toBe("permission denied");
    expect(useEditorStore.getState().savedSettings.global).toBeUndefined();
  });

  /// A place read once and unreadable since is no longer known. Left in
  /// `savedSettings`, its entry reads as a completed read, and the
  /// Library row, the package header and the Customize index go on
  /// answering stock or customized off a file nobody can read.
  it("unsays a settings answer whose next read failed", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().savedSettings.global).toBeDefined();

    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });
    await useEditorStore.getState().load();

    const { savedSettings } = useEditorStore.getState();
    expect(savedSettings.global).toBeUndefined();
    // The consumers' own answer, not just the record: unknown, never the
    // fact the last successful read left behind.
    const places = placesSource({}, [], true, savedSettings);
    expect(placeFacts(places, "skill", "gh", { scope: "global" }).values).toBe(
      null,
    );
  });

  /// The same record, the same rule, when it is the manifest read that
  /// failed: a settings answer this pass could not make is dropped
  /// rather than carried over from the pass before it.
  it("unsays it too when the manifest read is what failed", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().savedSettings.global).toBeDefined();

    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "error",
      error: "kendex.toml is unreadable",
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().savedSettings.global).toBeUndefined();
  });

  /// A person opens one project and then another before the first one's
  /// reads return. The older result landing on top would put one
  /// project's rows, and its base, under the other project's name — and
  /// an edit made against them writes the value into the wrong
  /// project's settings file, which is the worst this surface can do.
  it("drops a load the editor has already moved on from", async () => {
    const settled: Record<string, () => void> = {};
    vi.mocked(commands.getManifest).mockImplementation((scope: Scope) =>
      Promise.resolve({
        status: "ok",
        data: { manifest: null, base: `manifest-${scopeKey(scope)}` },
      }),
    );
    vi.mocked(commands.getScopeSettings).mockImplementation(
      (scope: Scope) =>
        new Promise((resolve) => {
          settled[scopeKey(scope)] = () =>
            resolve({ status: "ok", data: settings(scopeKey(scope)) });
        }),
    );

    const first = useEditorStore.getState().setScope(VG);
    const second = useEditorStore.getState().setScope(HYPR);
    settled[scopeKey(HYPR)]();
    await second;
    settled[scopeKey(VG)]();
    await first;

    const state = useEditorStore.getState();
    expect(state.scope).toEqual(HYPR);
    expect(state.base).toBe(`manifest-${scopeKey(HYPR)}`);
    expect(state.settings?.base).toBe(scopeKey(HYPR));
    // Its place's record is another question, and this read is still the
    // only one that asked: the page having moved on does not make what
    // it read untrue, so the mark for that place keeps its answer.
    expect(state.savedSettings[scopeKey(VG)]?.base).toBe(scopeKey(VG));
    expect(state.loading).toBe(false);
  });

  /// The same rule on the other setter: a superseded load whose manifest
  /// read failed must not blank the place the editor actually shows, nor
  /// put its own error on screen.
  it("drops a superseded load whose manifest read failed", async () => {
    let failLate = () => {};
    vi.mocked(commands.getManifest).mockImplementation((scope: Scope) =>
      scopeKey(scope) === scopeKey(VG)
        ? new Promise((resolve) => {
            failLate = () => resolve({ status: "error", error: "gone" });
          })
        : Promise.resolve({
            status: "ok",
            data: { manifest: null, base: "b1" },
          }),
    );

    const first = useEditorStore.getState().setScope(VG);
    const second = useEditorStore.getState().setScope(HYPR);
    await second;
    failLate();
    await first;

    const state = useEditorStore.getState();
    expect(state.scope).toEqual(HYPR);
    expect(state.draft).toEqual(emptyDraft());
    expect(state.error).toBeNull();
  });

  /// The same drop-on-failure rule the single read obeys: presence in
  /// the record is what says a read landed, and a startup pass that
  /// could not read a place unsays the last answer for it.
  it("drops a place the startup pass could not read", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().savedSettings.global).toBeDefined();

    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });
    await useEditorStore.getState().loadAll();
    expect(useEditorStore.getState().savedSettings.global).toBeUndefined();
  });

  /// Open means both halves landed. Treating a place whose settings read
  /// failed as open means coming back to it never retries, and a skill
  /// installed in one place has no other pill to switch to.
  it("reopens a place whose settings read failed, and only that", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });
    await useEditorStore.getState().openScope(VG);
    expect(useEditorStore.getState().settings).toBeNull();
    expect(commands.getScopeSettings).toHaveBeenCalledTimes(1);

    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: settings("s1"),
    });
    await useEditorStore.getState().openScope(VG);
    expect(useEditorStore.getState().settings?.base).toBe("s1");
    expect(commands.getScopeSettings).toHaveBeenCalledTimes(2);

    // And a place both halves landed for is left alone: the retry is for
    // the read that failed, not a reload on every visit.
    await useEditorStore.getState().openScope(VG);
    expect(commands.getScopeSettings).toHaveBeenCalledTimes(2);
  });

  /// Reload is the discard: settings edits are the second draft the one
  /// Save bar carries, so they go with the manifest draft rather than
  /// surviving into a save the person thought they had thrown away.
  it("drops settings edits on a reload", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1" },
    });
    await useEditorStore.getState().load();
    useEditorStore.getState().editSetting(edit);
    await useEditorStore.getState().load();
    expect(useEditorStore.getState().settingsEdits).toEqual([]);
    expect(useEditorStore.getState().dirty).toBe(false);
  });

  /// A stale refusal is a choice, not a failure: it must reach the page
  /// as the reload offer, never as a raw error — and a real failure must
  /// stay an error, never the reload offer.
  it("renders a stale refusal as the reload choice and a failure as an error", async () => {
    useEditorStore.setState({ draft: emptyDraft(), base: "b1" });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    await useEditorStore.getState().save();
    expect(useEditorStore.getState().stale).toBe(true);
    expect(useEditorStore.getState().error).toBeNull();

    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "disk is full" },
    });
    await useEditorStore.getState().save();
    expect(useEditorStore.getState().stale).toBe(false);
    expect(useEditorStore.getState().error).toBe("disk is full");
  });

  /// Save is fired and forgotten — `onSave={() => void save()}` — so a
  /// transport failure that escaped here left the busy flag falling with
  /// nothing shown. It folds into the refusal's place as the message alone
  /// (`bindings.test.ts`), which is neither arm of `WriteRefused`: read by
  /// `kind` it misses the stale arm this reader tests first and falls to the
  /// else, showing a blank error — the same silence by another route.
  it("shows the message when the transport failed rather than the engine refusing", async () => {
    useEditorStore.setState({ draft: emptyDraft(), base: "b1" });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: "the channel is gone" as unknown as WriteRefused,
    });

    await useEditorStore.getState().save();

    expect(useEditorStore.getState().error).toBe("the channel is gone");
    expect(useEditorStore.getState().stale).toBe(false);
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

// A place whose manifest cannot be read is unread, not whatever it last
// said. Left standing, the cached answer keeps the mark claiming a
// customization nobody can see any more — the one thing the third state
// ("unknown", never "stock") exists to prevent.
describe("loadPlaces after a read stops working", () => {
  const VG: Scope = { scope: "project", root: "/work/vg" };
  const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
  const CUSTOMIZED = {
    schema: 1,
    install: {},
    "skill-instructions": { gh: "mine" },
  };

  const item = (scope: Scope) => ({
    kind: "skill",
    name: "gh",
    scope,
    harness: "claude",
    path: "/x/.claude/skills/gh",
    fileState: "file",
    enabled: true,
    origin: null,
    description: "about gh",
    tags: [],
  });
  const group = groupItems([item(VG), item(HYPR)] as never)[0];

  const answer = (ok: boolean) =>
    vi.mocked(commands.getManifest).mockImplementation((scope) =>
      Promise.resolve(
        ok || scope.scope !== "project" || scope.root !== VG.root
          ? {
              status: "ok" as const,
              data: {
                manifest: (scope.scope === "project" && scope.root === VG.root
                  ? CUSTOMIZED
                  : { schema: 1, install: {} }) as never,
                base: null,
              },
            }
          : { status: "error" as const, error: "permission denied" },
      ),
    );

  // Both records come off the store the read filled: loadPlaces reads a
  // place's manifest and its settings together, and a mark drawn from one
  // of them alone would answer unknown for every place either way.
  const mark = () => {
    const { saved, savedSettings } = useEditorStore.getState();
    return markFor(saved, [], true, savedSettings, group);
  };

  it("drops the place it can no longer read instead of keeping its last answer", async () => {
    answer(true);
    await useEditorStore.getState().loadPlaces([VG, HYPR]);
    expect(mark()?.label).toBe("Customized in vg");

    answer(false);
    await useEditorStore.getState().loadPlaces([VG, HYPR]);
    expect(useEditorStore.getState().saved["/work/vg"]).toBeUndefined();
    expect(mark()).toBeNull();
  });

  it("leaves the places it was not asked about alone", async () => {
    useEditorStore.setState({ saved: { elsewhere: emptyDraft() } });
    answer(true);
    await useEditorStore.getState().loadPlaces([VG]);
    expect(useEditorStore.getState().saved.elsewhere).toEqual(emptyDraft());
  });
});

// Switching a place chip goes through setScope/load, not loadPlaces. A
// cache that is only written on success keeps the last place's answer,
// and the mark and the Skills section then read it as this place's.
describe("a place the editor switches to and cannot read", () => {
  const VG: Scope = { scope: "project", root: "/work/vg" };
  const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
  const CUSTOMIZED = {
    schema: 1,
    install: {},
    "skill-instructions": { gh: "mine" },
  };
  const forVG = { declaredAgents: ["orch"] } as unknown as EditorInventory;
  const forHYPR = { declaredAgents: ["scout"] } as unknown as EditorInventory;

  const manifestReads = (ok: boolean) =>
    vi.mocked(commands.getManifest).mockResolvedValue(
      ok
        ? {
            status: "ok",
            data: { manifest: CUSTOMIZED as never, base: null },
          }
        : { status: "error", error: "permission denied" },
    );
  const inventoryReads = (data: EditorInventory | null) =>
    vi
      .mocked(commands.editorInventory)
      .mockResolvedValue(
        data
          ? { status: "ok", data }
          : { status: "error", error: "no sources" },
      );

  // Read once, so there is a cached answer to go stale, then read again
  // and fail. Without the first read this proves nothing.
  it("drops the manifest it read before rather than keeping it", async () => {
    manifestReads(true);
    inventoryReads(forHYPR);
    await useEditorStore.getState().setScope(HYPR);
    expect(useEditorStore.getState().saved["/work/hyprtrade"]).toBeDefined();

    manifestReads(false);
    await useEditorStore.getState().setScope(VG);
    await useEditorStore.getState().setScope(HYPR);
    expect(useEditorStore.getState().saved["/work/hyprtrade"]).toBeUndefined();
  });

  it("drops the inventory it read before rather than keeping it", async () => {
    manifestReads(true);
    inventoryReads(forHYPR);
    await useEditorStore.getState().setScope(HYPR);
    expect(openInventory(useEditorStore.getState())).toBe(forHYPR);

    inventoryReads(null);
    await useEditorStore.getState().setScope(VG);
    await useEditorStore.getState().setScope(HYPR);
    expect(openInventory(useEditorStore.getState())).toBeNull();
    expect(useEditorStore.getState().error).toBe("no sources");
  });

  // The point of keying these by scope: another place's answer is not
  // reachable from here, whatever the reads did.
  it("never serves one place's inventory as another's", () => {
    useEditorStore.setState({
      scope: HYPR,
      inventories: { "/work/vg": forVG },
    });
    expect(openInventory(useEditorStore.getState())).toBeNull();

    useEditorStore.setState({ scope: VG });
    expect(openInventory(useEditorStore.getState())).toBe(forVG);
  });
});
