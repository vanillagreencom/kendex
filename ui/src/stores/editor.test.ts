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
import { placeRead } from "@/test/settings-read";
import { openInventory, useEditorStore } from "./editor";

// The real module comes through, with only the commands stubbed: the
// constants it exports are the numbers the code under test writes into a
// draft, and a second copy of one here would be the drift the export
// exists to prevent.
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
  ...placeRead,
  skills: [
    {
      skill: "gh",
      template: {
        state: "rows",
        secrets: [],
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

const secretEdit = {
  skill: "linear",
  key: "LINEAR_API_KEY",
  value: { kind: "set" as const, value: "lin_api_dummy" },
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
      // Every field a case can leave behind. The store is one module-level
      // value, so a field missing from this reset carries into the next
      // case: a picked private file left here put a secret half on the
      // settings-only save below.
      secretEdits: [],
      secretFile: null,
      confirming: false,
      manifestFile: null,
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      null,
    );
  });

  /// A manifest saved with a package deleted out of it takes that package
  /// away, so this route runs the leaving package's uninstaller like any
  /// other removal — and the editor is the one write that does not go
  /// through the update commands, so it says so itself.
  it("reports only the repository account of a successful save", async () => {
    const account =
      "commit-guards: running scripts/install-git-hooks --uninstall";
    const rows = [
      {
        name: "removed an armed package",
        response: { status: "ok", data: { undone: [account] } },
        message: true,
        stale: false,
      },
      {
        name: "no armed package removed",
        response: { status: "ok", data: {} },
        message: false,
        stale: false,
      },
      {
        name: "stale refusal",
        response: { status: "error", error: { kind: "stale" } },
        message: false,
        stale: true,
      },
    ] as const;
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      vi.mocked(toast.message).mockClear();
      vi.mocked(commands.getManifest).mockResolvedValue({
        status: "ok",
        data: { manifest: null, base: "b1", file: "kendex.toml" },
      });
      await useEditorStore.getState().load();
      vi.mocked(commands.saveCustomize).mockResolvedValue(
        row.response as Awaited<ReturnType<typeof commands.saveCustomize>>,
      );
      useEditorStore
        .getState()
        .edit((draft) =>
          setInstruction(draft, "skill-instructions", "gh", "x"),
        );
      await useEditorStore.getState().save();
      if (row.message)
        expect(toast.message, row.name).toHaveBeenCalledWith(account);
      else expect(toast.message, row.name).not.toHaveBeenCalled();
      if (row.stale)
        expect(useEditorStore.getState().stale, row.name).toBe(true);
    }
  });

  /// A credential goes to the private file, so it travels as its own
  /// draft with that file's own base — and it names the destination the
  /// fields were read against, so a project pointed elsewhere in between
  /// is refused rather than written.
  it("carries a credential as its own draft, bound to the private file", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    await useEditorStore.getState().load();
    useEditorStore.getState().editSecret(secretEdit);
    expect(useEditorStore.getState().dirty).toBe(true);

    await useEditorStore.getState().save();
    expect(commands.saveCustomize).toHaveBeenCalledWith(
      { scope: "global" },
      null,
      null,
      { edits: [secretEdit], file: ".env.local", choose: false, base: "p1" },
    );
  });

  /// Naming a private file is a save of its own. The choice is written
  /// into the settings file as the key both package loaders read, so it
  /// must not wait for somebody to also type a credential — the page has
  /// already promised that saving records it.
  it("saves a chosen private file with no credential typed", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    await useEditorStore.getState().load();
    await useEditorStore.getState().pickSecretFile(".env.secrets");
    expect(useEditorStore.getState().dirty).toBe(true);

    await useEditorStore.getState().save();
    expect(commands.saveCustomize).toHaveBeenCalledWith(
      { scope: "global" },
      null,
      null,
      { edits: [], file: ".env.local", choose: true, base: "p1" },
    );
  });

  /// The inverse: picking the file the project already names changes
  /// nothing, so the save carries no secret half at all rather than
  /// re-writing a key that is already there.
  it("sends no secret half for a pick the project already holds", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    const held = settings();
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: {
        ...held,
        secrets: {
          destination: {
            file: ".env.secrets",
            chosen: true,
            state: { state: "ready" },
          },
          candidates: [],
          base: "p1",
        },
      },
    });
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: {} as AuditView_Serialize,
    });
    await useEditorStore.getState().load();
    await useEditorStore.getState().pickSecretFile(".env.secrets");
    useEditorStore
      .getState()
      .edit((draft) => setInstruction(draft, "skill-instructions", "gh", "x"));

    await useEditorStore.getState().save();
    expect(commands.saveCustomize).toHaveBeenCalledWith(
      { scope: "global" },
      expect.anything(),
      null,
      null,
    );
  });

  /// The edits in hand were made against the bases the fields were read
  /// with, and those bases are what the save carries back so a file
  /// something else has written is refused. Adopting the confirmation
  /// read's bases would replace them after the fact and turn that refusal
  /// into an overwrite of somebody's newer value.
  it("offers the reload when a file moved between typing and Save", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    await useEditorStore.getState().load();
    useEditorStore.getState().editSecret(secretEdit);

    // Somebody else writes the private file between typing and Save.
    const held = settings();
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: {
        ...held,
        secrets: { ...held.secrets, base: "p2" } as NonNullable<
          ScopeSettings["secrets"]
        >,
      },
    });

    await useEditorStore.getState().requestSave();
    expect(useEditorStore.getState().stale).toBe(true);
    expect(useEditorStore.getState().confirming).toBe(false);
    expect(commands.saveCustomize).not.toHaveBeenCalled();
    // The draft is kept: the reload is a choice, not something taken.
    expect(useEditorStore.getState().secretEdits).toEqual([secretEdit]);
  });

  /// One rule for every read this store sends, in one table.
  ///
  /// Each site used to decide for itself whether a landed answer still
  /// belonged on screen, and each checked one half: the scope but not the
  /// picked file. A settings read committed into a scope the editor had
  /// left, and two quick picks resolving out of order left the rows
  /// describing one file while the draft targeted another. The rule is one
  /// helper now, so a site cannot hold half of it — these rows drive all
  /// three sites through the same question.
  it("refuses every read the page has stopped asking for", async () => {
    const settle: Record<string, (value: unknown) => void> = {};
    const readOf = (file: string | null) => ({
      status: "ok" as const,
      data: {
        ...settings(),
        secrets: {
          destination: {
            file: file ?? ".env.local",
            chosen: false,
            state: { state: "ready" as const },
          },
          candidates: [],
          base: "p1",
        },
      },
    });

    const rows: {
      name: string;
      send: () => Promise<void>;
      moveOn: () => void;
      wanted: string;
    }[] = [
      {
        name: "a pick overtaken by a later pick",
        send: () => useEditorStore.getState().pickSecretFile(".env.a"),
        moveOn: () => useEditorStore.setState({ secretFile: ".env.b" }),
        wanted: ".env.b",
      },
      {
        name: "a pick overtaken by a place change",
        send: () => useEditorStore.getState().pickSecretFile(".env.a"),
        moveOn: () => useEditorStore.setState({ scope: VG }),
        wanted: ".env.a",
      },
      {
        name: "a confirmation read overtaken by a pick",
        send: () => useEditorStore.getState().requestSave(),
        moveOn: () => useEditorStore.setState({ secretFile: ".env.b" }),
        wanted: ".env.b",
      },
    ];

    for (const row of rows) {
      useEditorStore.setState({
        scope: { scope: "global" },
        settings: null,
        secretFile: null,
        confirming: false,
      });
      vi.mocked(commands.getScopeSettings).mockImplementation(
        (_scope, file) =>
          new Promise((resolve) => {
            settle[row.name] = () => resolve(readOf(file));
          }),
      );
      const sent = row.send();
      row.moveOn();
      settle[row.name]?.(null);
      await sent;
      // The answer to a question nobody is asking any more never lands.
      expect(useEditorStore.getState().settings, row.name).toBeNull();
      expect(useEditorStore.getState().secretFile, row.name).toBe(
        row.wanted === ".env.a" ? ".env.a" : row.wanted,
      );
      expect(useEditorStore.getState().confirming, row.name).toBe(false);
    }

    // The control: the same read, with the page still asking, lands.
    useEditorStore.setState({
      scope: { scope: "global" },
      settings: null,
      secretFile: null,
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue(readOf(".env.a"));
    await useEditorStore.getState().pickSecretFile(".env.a");
    expect(useEditorStore.getState().settings).not.toBeNull();
  });

  /// A destination that changed name moves the place even when neither
  /// file exists, so neither base moved. Saving then would put a
  /// credential typed for one file into another.
  it("treats a changed destination name as a file that moved", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    const absent = (file: string) => ({
      status: "ok" as const,
      data: {
        ...settings(),
        secrets: {
          destination: {
            file,
            chosen: false,
            state: { state: "missing" as const, ignore: null },
          },
          candidates: [],
          base: null,
        },
      },
    });
    vi.mocked(commands.getScopeSettings).mockResolvedValue(absent(".env.one"));
    await useEditorStore.getState().load();
    useEditorStore.getState().editSecret(secretEdit);

    // Both bases stay null; only the name moves.
    vi.mocked(commands.getScopeSettings).mockResolvedValue(absent(".env.two"));
    await useEditorStore.getState().requestSave();
    expect(useEditorStore.getState().stale).toBe(true);
    expect(useEditorStore.getState().confirming).toBe(false);
    expect(commands.saveCustomize).not.toHaveBeenCalled();
  });

  /// Discard is this same reload, so it must come back to the project's
  /// own destination. A pick left in hand with nothing on screen saying so
  /// would be recorded by a later unrelated edit.
  it("clears a picked private file on reload", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    await useEditorStore.getState().load();
    await useEditorStore.getState().pickSecretFile(".env.secrets");
    expect(useEditorStore.getState().secretFile).toBe(".env.secrets");

    await useEditorStore.getState().load();
    expect(useEditorStore.getState().secretFile).toBeNull();
    expect(useEditorStore.getState().dirty).toBe(false);
    // And the read that reload made asked for the project's own answer.
    expect(commands.getScopeSettings).toHaveBeenLastCalledWith(
      { scope: "global" },
      null,
    );
  });

  /// Dirty is derived from every draft rather than set where one changes.
  /// Set by hand it survived the change that emptied it: taking back the
  /// last credential answer left the Save bar up over nothing, and picking
  /// the file a project already names raised it over no change at all.
  it("derives dirty from what is actually unsaved", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    await useEditorStore.getState().load();

    useEditorStore.getState().editSecret(secretEdit);
    expect(useEditorStore.getState().dirty).toBe(true);
    useEditorStore.getState().setSecretEdits([]);
    expect(useEditorStore.getState().dirty).toBe(false);

    // A pick the project already holds is not a change either.
    const held = settings();
    vi.mocked(commands.getScopeSettings).mockResolvedValue({
      status: "ok",
      data: {
        ...held,
        secrets: {
          destination: {
            file: ".env.secrets",
            chosen: true,
            state: { state: "ready" },
          },
          candidates: [],
          base: "p1",
        },
      },
    });
    await useEditorStore.getState().pickSecretFile(".env.secrets");
    expect(useEditorStore.getState().dirty).toBe(false);
  });

  /// Pressing Save writes nothing. The summary is built from a read taken
  /// as it opens, because a project pointed at another private file since
  /// the fields were filled in would otherwise be confirmed against the
  /// file it used to have.
  it("reads the place again and opens the summary rather than saving", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    await useEditorStore.getState().load();
    useEditorStore.getState().editSecret(secretEdit);
    vi.mocked(commands.getScopeSettings).mockClear();

    await useEditorStore.getState().requestSave();
    expect(useEditorStore.getState().confirming).toBe(true);
    expect(commands.getScopeSettings).toHaveBeenCalledTimes(1);
    expect(commands.saveCustomize).not.toHaveBeenCalled();

    // And cancelling writes nothing while the draft stands.
    useEditorStore.getState().cancelSave();
    expect(useEditorStore.getState().confirming).toBe(false);
    expect(useEditorStore.getState().secretEdits).toEqual([secretEdit]);
    expect(commands.saveCustomize).not.toHaveBeenCalled();
  });

  /// Picking another private file is a read, never an assumption: whether
  /// git carries it and which credentials it already holds are answers
  /// about that file, and neither can be guessed from its name.
  it("reads the place against a picked private file", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
    });
    await useEditorStore.getState().load();
    vi.mocked(commands.getScopeSettings).mockClear();

    await useEditorStore.getState().pickSecretFile(".env.secrets");
    expect(commands.getScopeSettings).toHaveBeenCalledWith(
      { scope: "global" },
      ".env.secrets",
    );
    expect(useEditorStore.getState().secretFile).toBe(".env.secrets");
  });

  /// The manifest is not the settings file: a settings change reconciles
  /// the scope against the manifest on disk, and sending the copy on
  /// screen back would rewrite a kendex.toml nobody touched.
  it("carries no manifest for a save that only changes settings", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      null,
    );
  });

  /// The base travels with the rows it was read beside: sent the base of
  /// a file these rows did not come from, a save would write over
  /// somebody else's newer copy instead of being refused.
  it("presents the settings base its rows were read with", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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

  /// A place read once and unreadable since is unknown. Left in
  /// `savedSettings`, its entry reads as a completed read, and the
  /// Library row, the package header and the Customize index go on
  /// answering stock or customized off a file nobody can read.
  it("unsays a settings answer whose next read failed", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
        data: {
          manifest: null,
          base: `manifest-${scopeKey(scope)}`,
          file: "kendex.toml",
        },
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
            data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
      data: { manifest: null, base: "b1", file: "kendex.toml" },
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
  /// transport failure that escaped here would leave the busy flag falling
  /// with nothing shown. It folds into the refusal's place as the message
  /// alone (`bindings.test.ts`), which is neither arm of `WriteRefused`:
  /// read by `kind` it would miss the stale arm this reader tests first and
  /// fall to the else, showing a blank error — the same silence by another
  /// route.
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
      data: { manifest: null, base: "b2", file: "kendex.toml" },
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
  const group = groupItems([item(VG), item(HYPR)] as never, () => null)[0];

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
                file: "kendex.toml",
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
            data: {
              manifest: CUSTOMIZED as never,
              base: null,
              file: "kendex.toml",
            },
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
