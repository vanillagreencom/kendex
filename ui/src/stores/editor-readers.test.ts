import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { whyUnread } from "./editor-order";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

// A save ends by re-reading and re-scanning; those stores have their own
// tests, and here they would only add IPC this file does not mock.
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: async () => {} }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: async () => {} }) },
}));

const A: Scope = { scope: "project", root: "/work/a" };
const B: Scope = { scope: "project", root: "/work/b" };

const audited = (): AuditView_Serialize => ({
  scope: A,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
});

const manifest = (note: string): Manifest_Serialize => ({
  schema: 1,
  install: {},
  "skill-instructions": { gh: note },
});

/** A read of a place: its manifest and what the file was when it was read. */
const read = (note: string) => ({ manifest: manifest(note), base: note });

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

beforeEach(() => {
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
    dirty: false,
    error: null,
  });
});

// Two readers never draw the editor: the pass that reads every place for
// the marks, and the re-read a save ends with. Neither may leave the
// surface waiting on a read that was never going to fill it.
describe("reads that draw no editor", () => {
  it("is not left spinning by a manifest pass that overtakes it", async () => {
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    let held = true;
    vi.mocked(commands.getManifest).mockImplementation(() =>
      held ? slow.promise : Promise.resolve({ status: "ok", data: read("a") }),
    );
    const opening = useEditorStore.getState().setScope(A);
    held = false;
    await useEditorStore.getState().loadAll();
    slow.resolve({ status: "ok", data: read("a") });
    await opening;

    const state = useEditorStore.getState();
    expect(state.loading).toBe(false);
    expect(state.draft?.["skill-instructions"]).toEqual({ gh: "a" });
  });

  it("is not left spinning by a save re-reading the place it wrote", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("a"),
    });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "ok",
      data: { view: audited(), base: "written", wroteMore: false },
    });
    await useEditorStore.getState().setScope(A);
    const saving = useEditorStore.getState().save();
    // The reader moves on while the save is still writing; its re-read of A
    // lands after B's, and A is not the place on screen any more.
    const opening = useEditorStore.getState().setScope(B);
    await saving;
    await opening;

    const state = useEditorStore.getState();
    expect(state.loading).toBe(false);
    expect(state.scope).toEqual(B);
    expect(state.draft).not.toBe(null);
  });
});

// The pass fires from three places that overlap. Which lands last must not
// decide what the marks say happened.
describe("manifest passes that overlap", () => {
  const settings = () => useSettingsStore.setState({ settings: { schema: 1 } });

  it("lets the newest pass own the status, in both arms", async () => {
    settings();
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    // By call, not by a flag: each pass reaches its read on its own
    // microtask, so a flag flipped between them decides nothing.
    let call = 0;
    vi.mocked(commands.getManifest).mockImplementation(() => {
      call += 1;
      return call === 1
        ? slow.promise
        : Promise.resolve({ status: "error", error: "gone" });
    });
    const older = useEditorStore.getState().loadAll();
    await useEditorStore.getState().loadAll();
    expect(whyUnread(useEditorStore.getState())).toContain("gone");

    // The older pass succeeds, late. Clearing the newer failure here would
    // hand the marks a banner-free screen for a read that did fail.
    slow.resolve({ status: "ok", data: { manifest: null, base: null } });
    await older;
    expect(whyUnread(useEditorStore.getState())).toContain("gone");
    expect(useEditorStore.getState().manifestsReading).toBe(false);
  });

  it("keeps reading until the last pass lands, not the first", async () => {
    settings();
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    let call = 0;
    vi.mocked(commands.getManifest).mockImplementation(() => {
      call += 1;
      return call === 1
        ? slow.promise
        : Promise.resolve({
            status: "ok",
            data: { manifest: null, base: null },
          });
    });
    const older = useEditorStore.getState().loadAll();
    await useEditorStore.getState().loadAll();
    expect(useEditorStore.getState().manifestsReading).toBe(true);
    slow.resolve({ status: "ok", data: { manifest: null, base: null } });
    await older;
    expect(useEditorStore.getState().manifestsReading).toBe(false);
  });
});

// A read that ends by rejecting has to say so: left silent it is an editor
// stuck on a spinner with nothing beneath it and no error to explain why.
describe("a read that rejects rather than answering", () => {
  it("says it could not open instead of waiting forever", async () => {
    vi.mocked(commands.getManifest).mockRejectedValue(new Error("no channel"));
    await useEditorStore.getState().setScope(A);
    const state = useEditorStore.getState();
    expect(state.loading).toBe(false);
    expect(state.draft).toBe(null);
    expect(state.error).toContain("no channel");
  });
});

// Unsaved work on a package page must survive arriving at another package:
// openScope points the editor without re-reading over what is in hand.
describe("pointing the editor at a place it already holds", () => {
  it("keeps the copy in hand rather than reading over it", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("saved"),
    });
    await useEditorStore.getState().setScope(A);
    useEditorStore.getState().edit((draft) => ({
      ...draft,
      "skill-instructions": { gh: "typed, unsaved" },
    }));
    await useEditorStore.getState().openScope(A);
    expect(useEditorStore.getState().draft?.["skill-instructions"]).toEqual({
      gh: "typed, unsaved",
    });
    expect(useEditorStore.getState().dirty).toBe(true);
  });
});
