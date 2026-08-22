// What a person sees after pressing Save. Every other test around this
// store pins a refusal or a race — which read wins, which save is refused —
// and none of them pressed Save on an ordinary draft and looked at what was
// left on screen. `dirty` is that answer: the Save bar renders on it and the
// place chips are disabled by it, so a save that leaves it up leaves the
// feature's main action unfinished.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { setInstruction } from "@/lib/editor-draft";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";

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

const scope: Scope = { scope: "global" };

const audited = (): AuditView_Serialize => ({
  scope,
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

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

/** The Customize tab, opened on a real read and typed in — so the draft
 *  carries the base of the file it came from, as a save needs. */
const typedIn = async (note: string) => {
  // A fresh open, not a re-point: pointing the editor at the place it is
  // already on keeps whatever is in hand, which is the whole point of the
  // move, so the previous case's typing is cleared here rather than by it.
  useEditorStore.setState({
    outdated: null,
    saved: {},
    error: null,
    held: {},
    draft: null,
    base: null,
    dirty: false,
  });
  await useEditorStore.getState().setScope(scope);
  expect(useEditorStore.getState().base).toBe("on-disk");
  useEditorStore
    .getState()
    .edit((draft) => setInstruction(draft, "skill-instructions", "gh", note));
  expect(useEditorStore.getState().dirty).toBe(true);
};

beforeEach(() => {
  vi.clearAllMocks();
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
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: manifest("mine"), base: "on-disk" },
  });
  vi.mocked(commands.updateManifest).mockResolvedValue({
    status: "ok",
    data: { view: audited(), base: "written", wroteMore: false },
  });
});

describe("saving a customization", () => {
  it("writes what is on screen and leaves nothing unsaved", async () => {
    await typedIn("mine");

    // The file after the write is what its re-read finds.
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: manifest("mine"), base: "written" },
    });
    await useEditorStore.getState().save();

    const after = useEditorStore.getState();
    // The base rides with the copy: the write refuses without it.
    expect(commands.updateManifest).toHaveBeenCalledWith(
      scope,
      { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
      "on-disk",
    );
    // And what the file is now becomes the base for the next save.
    expect(useEditorStore.getState().base).toBe("written");
    // The Save bar renders on this, and the place chips are disabled by it.
    expect(after.dirty).toBe(false);
    expect(after.error).toBeNull();
    // And the marks read what the file now holds.
    expect(after.saved.global).toEqual(manifest("mine"));
  });

  it("keeps typing that arrived while the write was away", async () => {
    await typedIn("first");
    const write =
      deferred<Awaited<ReturnType<typeof commands.updateManifest>>>();
    vi.mocked(commands.updateManifest).mockReturnValueOnce(write.promise);

    const saving = useEditorStore.getState().save();
    // A second thought, typed before the write answers.
    useEditorStore
      .getState()
      .edit((draft) =>
        setInstruction(draft, "skill-instructions", "gh", "second"),
      );
    write.resolve({
      status: "ok",
      data: { view: audited(), base: "written", wroteMore: false },
    });
    await saving;

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "second" });
    // Newer than the file, so it is still the user's to save.
    expect(after.dirty).toBe(true);
    // And it descends from the write that just landed, so that is the file
    // its save carries — refusing it would refuse a change it made itself.
    expect(after.base).toBe("written");
  });

  it("leaves the draft unsaved when the write is refused", async () => {
    await typedIn("mine");
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "the settings file would not parse" },
    });

    await useEditorStore.getState().save();

    const after = useEditorStore.getState();
    expect(after.dirty).toBe(true);
    expect(after.error).toContain("would not parse");
  });
});

// The mark the app sets is what a caller remembers to do. This is what the
// file itself knows, and it holds when nobody remembered anything: the
// write carries the base its copy was read from, and a file that has become
// something else refuses it.
describe("a write against a file that moved underneath it", () => {
  const refused = () => ({
    status: "error" as const,
    error: { kind: "stale" as const },
  });

  it("keeps the typing, says why, and offers the reload", async () => {
    await typedIn("mine");
    // Nothing marked the place: this is the writer that never told the
    // editor it wrote, which is the case the mark cannot cover.
    expect(useEditorStore.getState().outdated).toBeNull();
    vi.mocked(commands.updateManifest).mockResolvedValue(refused());

    await useEditorStore.getState().save();

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "mine" });
    expect(after.dirty).toBe(true);
    expect(useProblemsStore.getState().dialog.title).toContain(
      "changed while you typed",
    );
    // Reloading is offered, and it is the deliberate discard.
    const reload = useProblemsStore
      .getState()
      .dialog.actions.find((action) => action.label.includes("Reload"));
    expect(reload).toBeDefined();
  });

  it("marks the place, so the next press needs no round trip", async () => {
    await typedIn("mine");
    vi.mocked(commands.updateManifest).mockResolvedValue(refused());
    await useEditorStore.getState().save();
    expect(useEditorStore.getState().outdated).toBe("global");

    vi.mocked(commands.updateManifest).mockClear();
    await useEditorStore.getState().save();

    expect(commands.updateManifest).not.toHaveBeenCalled();
  });

  it("takes the file back when the reload is taken", async () => {
    await typedIn("mine");
    vi.mocked(commands.updateManifest).mockResolvedValue(refused());
    await useEditorStore.getState().save();

    // What the other writer left behind.
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: manifest("theirs"), base: "theirs" },
    });
    const reload = useProblemsStore
      .getState()
      .dialog.actions.find((action) => action.label.includes("Reload"));
    reload?.onClick();
    await vi.waitUntil(() => useEditorStore.getState().base === "theirs");

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "theirs" });
    expect(after.dirty).toBe(false);
    expect(after.outdated).toBeNull();
  });
});
