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

/** A read of a place: its manifest and what the file was when it was read.
 *  The two travel together, so the tests hand them over together. */
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

// sends that pair to a file. A read that lands after a newer one must not
// be able to make them disagree.
describe("switching place while a read is in flight", () => {
  it("never lets a superseded read become the draft on screen", async () => {
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    const quick = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest)
      .mockImplementationOnce(() => slow.promise)
      .mockImplementationOnce(() => quick.promise);

    const first = useEditorStore.getState().setScope(A);
    const second = useEditorStore.getState().setScope(B);
    quick.resolve({ status: "ok", data: read("b") });
    await second;
    slow.resolve({ status: "ok", data: read("a") });
    await first;

    const state = useEditorStore.getState();
    expect(state.scope).toEqual(B);
    expect(state.draft?.["skill-instructions"]).toEqual({ gh: "b" });
    // The late read still knows its own place, so the marks keep it.
    expect(state.saved["/work/a"]?.["skill-instructions"]).toEqual({ gh: "a" });
  });

  // Discard rules on the typing that was there when it was pressed. Anyone
  // who keeps typing afterwards is writing something newer than the
  // instruction, and a read that lands later must not carry it away —
  // that is work nobody ruled on.
  it("keeps typing that arrives after a discard was pressed", async () => {
    useEditorStore.setState({
      scope: A,
      draft: { schema: 1, install: {}, "skill-instructions": { gh: "old" } },
      dirty: true,
    });
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest).mockImplementationOnce(() => slow.promise);

    const reading = useEditorStore.getState().discard();
    // The instruction landed: what was on screen when it was pressed is gone.
    expect(useEditorStore.getState().dirty).toBe(false);
    // Someone types again while the read is still on its way.
    useEditorStore.getState().edit((draft) => ({
      ...draft,
      "skill-instructions": { gh: "typed after" },
    }));
    slow.resolve({ status: "ok", data: read("from file") });
    await reading;

    const state = useEditorStore.getState();
    expect(state.draft?.["skill-instructions"]).toEqual({ gh: "typed after" });
    expect(state.dirty).toBe(true);
    // The read still knows its own place, so the marks take it.
    expect(state.saved["/work/a"]?.["skill-instructions"]).toEqual({
      gh: "from file",
    });
  });

  it("never lets a superseded failure blank the draft on screen", async () => {
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    const quick = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest)
      .mockImplementationOnce(() => slow.promise)
      .mockImplementationOnce(() => quick.promise);

    const first = useEditorStore.getState().setScope(A);
    const second = useEditorStore.getState().setScope(B);
    quick.resolve({ status: "ok", data: read("b") });
    await second;
    slow.resolve({ status: "error", error: "unreadable" });
    await first;

    const state = useEditorStore.getState();
    expect(state.draft?.["skill-instructions"]).toEqual({ gh: "b" });
    expect(state.error).toBe(null);
  });

  it("keeps the editor reading until the newest read lands", async () => {
    const slow = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    const quick = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest)
      .mockImplementationOnce(() => slow.promise)
      .mockImplementationOnce(() => quick.promise);

    const first = useEditorStore.getState().setScope(A);
    const second = useEditorStore.getState().setScope(B);
    slow.resolve({ status: "ok", data: read("a") });
    await first;
    // The superseded read came back; the one the editor is waiting on has
    // not, so clearing the spinner here would say the place is on screen.
    expect(useEditorStore.getState().loading).toBe(true);
    quick.resolve({ status: "ok", data: read("b") });
    await second;
    expect(useEditorStore.getState().loading).toBe(false);
  });

  it("writes the place the draft on screen belongs to", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("b"),
    });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "stop here" },
    });
    await useEditorStore.getState().setScope(B);
    await useEditorStore.getState().save();
    expect(vi.mocked(commands.updateManifest).mock.calls[0]?.[0]).toEqual(B);
  });
});

// A save is a write followed by a re-read, and the place on screen can move
// between the two. Everything after the await belongs to the place that was
// written, not to whichever place is open when the response lands.
describe("switching place while a save is in flight", () => {
  const inFlight = () => {
    const landing =
      deferred<Awaited<ReturnType<typeof commands.updateManifest>>>();
    vi.mocked(commands.updateManifest).mockImplementationOnce(
      () => landing.promise,
    );
    return landing;
  };

  it("names the place a failed save was about, not the one on screen", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("a"),
    });
    await useEditorStore.getState().setScope(A);
    const landing = inFlight();
    const saving = useEditorStore.getState().save();
    await useEditorStore.getState().setScope(B);
    landing.resolve({
      status: "error",
      error: { kind: "failed", message: "read-only" },
    });
    await saving;

    const state = useEditorStore.getState();
    expect(state.scope).toEqual(B);
    expect(state.error).toContain("read-only");
    expect(state.error).toContain("/work/a");
  });

  it("re-reads the place it wrote, never whichever is open now", async () => {
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("before"),
    });
    await useEditorStore.getState().setScope(A);
    const landing = inFlight();
    const saving = useEditorStore.getState().save();
    await useEditorStore.getState().setScope(B);
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: read("after"),
    });
    landing.resolve({
      status: "ok",
      data: { view: audited(), base: "after", wroteMore: false },
    });
    await saving;

    // A's mark reads its saved manifest, so a save that refreshed B instead
    // would leave A showing the state it had before the write.
    expect(
      useEditorStore.getState().saved["/work/a"]?.["skill-instructions"],
    ).toEqual({ gh: "after" });
    expect(useEditorStore.getState().scope).toEqual(B);
  });
});
