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

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((keep, fail) => {
    resolve = keep;
    reject = fail;
  });
  return { promise, resolve, reject };
}

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

describe("passes that overlap", () => {
  it("never lets an older pass revert a place a newer read answered for", async () => {
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    const issued = deferred<null>();
    let holding = true;
    vi.mocked(commands.getManifest).mockImplementation(() => {
      if (!holding) {
        return Promise.resolve({
          status: "ok",
          data: {
            manifest: {
              schema: 1,
              install: {},
              "skill-instructions": { gh: "typed" },
            },
            base: "typed",
          },
        });
      }
      issued.resolve(null);
      return slow.promise;
    });

    const pass = useEditorStore.getState().loadAll();
    await issued.promise;
    // A place read on its own while the pass is still in flight.
    holding = false;
    await useEditorStore.getState().setScope({
      scope: "project",
      root: "/work/vg",
    });
    slow.resolve({ status: "ok", data: { manifest: null, base: null } });
    await pass;

    expect(
      useEditorStore.getState().saved["/work/vg"]?.["skill-instructions"],
    ).toEqual({ gh: "typed" });
  });

  it("keeps a place's last good manifest when a later pass cannot read it", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: {
        manifest: {
          schema: 1,
          install: {},
          "skill-instructions": { gh: "mine" },
        },
        base: "mine-base",
      },
    });
    await useEditorStore.getState().loadAll();

    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "error",
      error: "expected a table",
    });
    await useEditorStore.getState().loadAll();

    const state = useEditorStore.getState();
    expect(state.saved["/work/vg"]?.["skill-instructions"]).toEqual({
      gh: "mine",
    });
    expect(whyUnread(state)).toContain("/work/vg");
  });

  it("treats a rejected read as a read that failed, not one still running", async () => {
    // Every place refusing is still a pass that ran: each read answers for
    // its own place, and the reason is named per place.
    vi.mocked(commands.getManifest).mockRejectedValue(new Error("no channel"));
    await useEditorStore.getState().loadAll();
    const state = useEditorStore.getState();
    expect(state.manifestsReading).toBe(false);
    expect(whyUnread(state)).toContain("no channel");
    expect(state.manifestsLoaded).toBe(true);
  });

  it("says the pass itself failed when it could not even list the places", async () => {
    useSettingsStore.setState({ settings: null });
    vi.spyOn(useSettingsStore.getState(), "load").mockRejectedValue(
      new Error("settings unreadable"),
    );
    await useEditorStore.getState().loadAll();
    const state = useEditorStore.getState();
    expect(state.manifestsReading).toBe(false);
    expect(whyUnread(state)).toContain("settings unreadable");
    expect(state.manifestsLoaded).toBe(false);
  });

  it("hands back the same object when a re-read says the same thing", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: {
        manifest: {
          schema: 1,
          install: {},
          "skill-instructions": { gh: "mine" },
        },
        base: "mine-base",
      },
    });
    await useEditorStore.getState().loadAll();
    const first = useEditorStore.getState().saved;
    await useEditorStore.getState().loadAll();
    // Identity is what the screens joining on this memoize against, so an
    // equal copy would re-render every row for news that is not news.
    expect(useEditorStore.getState().saved).toBe(first);
  });

  it("keeps the places that read when one of them rejects", async () => {
    // Each read answers for its own place: one bad manifest taking the
    // whole batch down would make every readable place unknown.
    useSettingsStore.setState({
      settings: { schema: 1, projects: ["/work/vg", "/work/hyprtrade"] },
    });
    vi.mocked(commands.getManifest).mockImplementation((scope) =>
      scope.scope === "project" && scope.root === "/work/vg"
        ? Promise.reject(new Error("no channel"))
        : Promise.resolve({
            status: "ok",
            data: {
              manifest: {
                schema: 1,
                install: {},
                "skill-instructions": { gh: "read" },
              },
              base: "read",
            },
          }),
    );

    await useEditorStore.getState().loadAll();
    const state = useEditorStore.getState();
    expect(state.saved.global?.["skill-instructions"]).toEqual({ gh: "read" });
    expect(state.saved["/work/hyprtrade"]?.["skill-instructions"]).toEqual({
      gh: "read",
    });
    expect(state.saved["/work/vg"]).toBeUndefined();
    expect(whyUnread(state)).toContain("/work/vg");
    expect(whyUnread(state)).toContain("no channel");
    expect(state.manifestsLoaded).toBe(true);
  });
});
