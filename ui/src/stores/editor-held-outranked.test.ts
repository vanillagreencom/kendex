import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

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

const note = () =>
  useEditorStore.getState().draft?.["skill-instructions"]?.gh ?? null;

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

const type = (text: string) =>
  useEditorStore.getState().edit((draft) => ({
    ...draft,
    "skill-instructions": { gh: text },
  }));

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
  vi.mocked(commands.getManifest).mockImplementation(async (scope: Scope) => ({
    status: "ok" as const,
    data: read(scope.scope === "global" ? "global" : scope.root),
  }));
  useEditorStore.setState({
    held: {},
    scope: { scope: "global" },
    draft: null,
    base: null,
    saved: {},
    dirty: false,
    outdated: null,
    error: null,
  });
});

// Parking keeps a copy nobody has ruled on. A discard is a ruling, and it
// rules against the copy — so it has to reach a copy the move parked, or an
// explicit instruction to destroy typing is undone by a click.
describe("discarding while the read is in flight", () => {
  it("does not let a move bring the discarded edits back", async () => {
    await useEditorStore.getState().openScope(A);
    type("typed at a, then discarded");
    const reading =
      deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest).mockImplementationOnce(
      () => reading.promise,
    );
    const discarding = useEditorStore.getState().discard();
    // The Save bar is already down: the instruction landed before anything
    // was awaited, so there is nothing left for the move to park.
    expect(useEditorStore.getState().dirty).toBe(false);
    await useEditorStore.getState().openScope(B);
    expect(useEditorStore.getState().held).toEqual({});
    reading.resolve({ status: "ok", data: read("/work/a") });
    await discarding;

    await useEditorStore.getState().openScope(A);
    expect(note()).toBe("/work/a");
    expect(useEditorStore.getState().dirty).toBe(false);
  });

  it("reaches a copy parked at a place the editor is not on", async () => {
    await useEditorStore.getState().openScope(A);
    type("typed at a");
    await useEditorStore.getState().openScope(B);
    // The refusal offers this reload for the place it is about, which is
    // not the place on screen by the time it is taken.
    await useEditorStore.getState().load(A, { discardEdits: true });
    expect(useEditorStore.getState().held).toEqual({});
  });
});

// A save is the other ruling: it commits the copy. The response has to
// settle the parked copy for the place it wrote, or returning there brings
// back an already-saved draft carrying a base from before its own write —
// and the next save is refused over typing that is already on disk.
describe("saving while the editor moves away", () => {
  const landing = () => {
    const write =
      deferred<Awaited<ReturnType<typeof commands.updateManifest>>>();
    vi.mocked(commands.updateManifest).mockImplementationOnce(
      () => write.promise,
    );
    return write;
  };

  it("leaves nothing parked for a copy that is now on disk", async () => {
    await useEditorStore.getState().openScope(A);
    type("saved at a");
    const write = landing();
    const saving = useEditorStore.getState().save();
    await useEditorStore.getState().openScope(B);
    write.resolve({
      status: "ok",
      data: { view: audited(), base: "written", wroteMore: false },
    });
    await saving;

    expect(useEditorStore.getState().held).toEqual({});
    await useEditorStore.getState().openScope(A);
    expect(useEditorStore.getState().dirty).toBe(false);
    // The pre-write base did not come back with it, so the next save is
    // not refused for a change this save made itself.
    expect(useEditorStore.getState().base).toBe("/work/a");
  });

  it("gives typing that arrived mid-write the file its write left", async () => {
    await useEditorStore.getState().openScope(A);
    type("saved at a");
    const write = landing();
    const saving = useEditorStore.getState().save();
    type("and more, after the write left");
    await useEditorStore.getState().openScope(B);
    write.resolve({
      status: "ok",
      data: { view: audited(), base: "written", wroteMore: false },
    });
    await saving;

    await useEditorStore.getState().openScope(A);
    expect(note()).toBe("and more, after the write left");
    expect(useEditorStore.getState().dirty).toBe(true);
    expect(useEditorStore.getState().base).toBe("written");
  });
});
