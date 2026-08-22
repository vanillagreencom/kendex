import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { whyUnread } from "./editor-order";
import { useSettingsStore } from "./settings";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

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
describe("reading every place's manifest", () => {
  it("keeps the reason a place would not read, naming the place", async () => {
    vi.mocked(commands.getManifest)
      .mockResolvedValueOnce({
        status: "ok",
        data: { manifest: null, base: null },
      })
      .mockResolvedValueOnce({ status: "error", error: "expected a table" })
      // The pass ends by re-reading the open place, whose draft is clean.
      .mockResolvedValue({
        status: "ok",
        data: { manifest: null, base: null },
      });
    await useEditorStore.getState().loadAll();
    const state = useEditorStore.getState();
    expect(state.manifestsLoaded).toBe(true);
    expect(state.saved["/work/vg"]).toBeUndefined();
    expect(whyUnread(state)).toContain("/work/vg");
    expect(whyUnread(state)).toContain("expected a table");
  });

  it("says nothing when every place read", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();
    expect(whyUnread(useEditorStore.getState())).toBe(null);
    expect(useEditorStore.getState().saved["/work/vg"]).toBeDefined();
  });
});

// The pass fires from three places that overlap — app start, every window
// focus, and the note's own retry — so which one lands last must not decide
// what every place's mark says.
// A project someone unregisters is read by no later pass, so anything kept
// for it can never be answered — the note would go on naming a place the
// app no longer has, with a retry that cannot reach it.
// The settings read is what says which projects there are. One that could
// not open the file resolves like any other, leaving nothing to list — and
// a pass that answered for the user's own place alone would report success
// while every project's packages read as untouched.
describe("a pass that could not find out which projects there are", () => {
  it("fails rather than answering for the global scope alone", async () => {
    useSettingsStore.setState({ settings: null });
    vi.mocked(commands.getSettings).mockResolvedValue({
      status: "error",
      error: "the settings file would not parse",
    });
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: 100,
      launchRefused: false,
    });

    // Counted from here: earlier cases in this file share the mock.
    vi.mocked(commands.getManifest).mockClear();

    await useEditorStore.getState().loadAll();

    const after = useEditorStore.getState();
    expect(after.manifestsLoaded).toBe(false);
    expect(whyUnread(after)).toContain("projects could not be read");
    // And nothing was read, so no place may answer as current.
    expect(commands.getManifest).not.toHaveBeenCalled();
  });
});

describe("a project that is no longer there", () => {
  // The pass ends by re-reading the place the editor is pointed at, and a
  // project just unregistered is still the one on screen. Reading it puts
  // back exactly what the prune took away, and no later pass asks for it
  // again — so the note would name it for good, and its retry would prune
  // and re-add it every press.
  // A pass takes its list of places when it starts and answers with it
  // much later. One that captured a project unregistered in between is
  // still carrying it, and nothing reads that scope again — so folding its
  // results in puts the project back for good.
  it("cannot be put back by a pass that was already running", async () => {
    const held = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    // The older pass reads global, then hangs on the project.
    vi.mocked(commands.getManifest)
      .mockResolvedValueOnce({
        status: "ok",
        data: { manifest: null, base: null },
      })
      .mockReturnValueOnce(held.promise);
    const older = useEditorStore.getState().loadAll();

    // The project is unregistered, and a newer pass runs to completion.
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();
    expect(Object.keys(useEditorStore.getState().saved)).toEqual(["global"]);

    // Only now does the older pass get its answer for the project.
    held.resolve({ status: "error", error: "no such directory" });
    await older;

    const after = useEditorStore.getState();
    expect(Object.keys(after.saved)).toEqual(["global"]);
    expect(Object.keys(after.unreadPlaces)).toEqual([]);
    expect(whyUnread(after)).toBeNull();
  });

  it("does not read the place on screen back after removing it", async () => {
    useEditorStore.setState({ scope: { scope: "project", root: "/work/vg" } });
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "error",
      error: "expected a table",
    });
    await useEditorStore.getState().loadAll();
    expect(Object.keys(useEditorStore.getState().unreadPlaces)).toContain(
      "/work/vg",
    );

    // Unregistered, so the next pass asks only for the rest — and the
    // directory it used to be is gone, so reading it on its own fails.
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    vi.mocked(commands.getManifest)
      .mockResolvedValueOnce({
        status: "ok",
        data: { manifest: null, base: null },
      })
      .mockResolvedValue({ status: "error", error: "no such directory" });
    await useEditorStore.getState().loadAll();

    const after = useEditorStore.getState();
    expect(Object.keys(after.unreadPlaces)).toEqual([]);
    expect(whyUnread(after)).toBeNull();
  });

  it("takes its manifest and its reason with it", async () => {
    vi.mocked(commands.getManifest)
      .mockResolvedValueOnce({
        status: "ok",
        data: { manifest: null, base: null },
      })
      .mockResolvedValueOnce({
        status: "error",
        error: "expected a table",
      });
    await useEditorStore.getState().loadAll();
    const failed = useEditorStore.getState();
    expect(Object.keys(failed.unreadPlaces)).toContain("/work/vg");
    expect(whyUnread(failed)).toContain("expected a table");

    // The project is unregistered, so the next pass asks only the rest.
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: null },
    });
    await useEditorStore.getState().loadAll();

    const after = useEditorStore.getState();
    expect(Object.keys(after.unreadPlaces)).toEqual([]);
    expect(whyUnread(after)).toBeNull();
    expect(Object.keys(after.saved)).toEqual(["global"]);
  });
});
