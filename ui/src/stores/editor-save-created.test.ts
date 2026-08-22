// A write that puts down more than it was handed. Creating the file seeds
// the default source and this machine's harnesses; any save can derive a
// name for a custom hook that arrived without one. Either way the file that
// lands is not the copy that went, and typing made from that copy never
// held the difference — so treating it as descended from the file would let
// its next save write that away, with nothing refused and nothing said.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  Manifest_Serialize,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { setInstruction } from "@/lib/editor-draft";
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

const scope: Scope = { scope: "global" };
const elsewhere: Scope = { scope: "project", root: "/work/vg" };

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

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

const type = (note: string) =>
  useEditorStore
    .getState()
    .edit((draft) => setInstruction(draft, "skill-instructions", "gh", note));

/** Open a place whose file does not exist yet and type in it. */
const openEmptyAndType = async () => {
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
  expect(useEditorStore.getState().base).toBeNull();
  type("first");
};

/** What the creation put on disk: the copy that was sent plus the seed the
 *  caller never held. */
const created: Manifest_Serialize = {
  schema: 1,
  install: { harnesses: ["claude"] },
  sources: { kendex: { repo: "vanillagreencom/kendex", enabled: true } },
  "skill-instructions": { gh: "first" },
};

/** The write that creates the file, held open so typing can land inside it.
 *  Landing puts the file where the re-read afterwards will find it. */
const creatingWrite = () => {
  const write = deferred<Awaited<ReturnType<typeof commands.updateManifest>>>();
  vi.mocked(commands.updateManifest).mockReturnValueOnce(write.promise);
  return {
    saving: useEditorStore.getState().save(),
    land: () => {
      vi.mocked(commands.getManifest).mockResolvedValue({
        status: "ok",
        data: { manifest: created, base: "created" },
      });
      write.resolve({
        status: "ok",
        data: { view: audited(), base: "created", wroteMore: true },
      });
    },
  };
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
  // No file here yet, which is what makes the write below a creation.
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: null, base: null },
  });
});

describe("the write that creates a place's file", () => {
  it("refuses typing that arrived while it was away", async () => {
    await openEmptyAndType();
    const write = creatingWrite();
    type("second");
    write.land();
    await write.saving;

    const after = useEditorStore.getState();
    // Still theirs to save, and still on screen — nothing was taken.
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "second" });
    expect(after.dirty).toBe(true);
    // But it never held the seed, so it does not get to speak for the file
    // the creation made.
    expect(after.base).not.toBe("created");
    expect(after.outdated).toBe("global");

    // Which is the point: the next press is refused rather than writing the
    // seed back out of existence.
    vi.mocked(commands.updateManifest).mockClear();
    await useEditorStore.getState().save();
    expect(commands.updateManifest).not.toHaveBeenCalled();
  });

  // The write answering is not the file arriving: the seed is only in hand
  // once the re-read lands, and the Save bar comes down before it does.
  it("refuses typing that arrived before the file came back", async () => {
    await openEmptyAndType();
    const write = creatingWrite();
    // The re-read the save ends with is held open, which is the window.
    const reread = deferred<Awaited<ReturnType<typeof commands.getManifest>>>();
    vi.mocked(commands.getManifest).mockReturnValueOnce(reread.promise);
    write.land();
    // Nothing typed while the write was away, so this is the copy that went.
    await Promise.resolve();
    type("second");
    reread.resolve({
      status: "ok",
      data: { manifest: created, base: "created" },
    });
    await write.saving;

    const after = useEditorStore.getState();
    expect(after.draft?.["skill-instructions"]).toEqual({ gh: "second" });
    expect(after.dirty).toBe(true);
    // The re-read found typing it must not take, so the refusal stands and
    // the seed cannot be written away by the next press.
    expect(after.outdated).toBe("global");
    vi.mocked(commands.updateManifest).mockClear();
    await useEditorStore.getState().save();
    expect(commands.updateManifest).not.toHaveBeenCalled();
  });

  it("settles the copy that went, seed and all", async () => {
    await openEmptyAndType();
    const write = creatingWrite();
    write.land();
    await write.saving;

    const after = useEditorStore.getState();
    // Nothing was typed over it, so the file is what is on screen.
    expect(after.dirty).toBe(false);
    expect(after.base).toBe("created");
    expect(after.outdated).toBeNull();
  });

  it("refuses a copy parked elsewhere while it was away", async () => {
    await openEmptyAndType();
    const write = creatingWrite();
    type("second");
    // The reader clicks through to another place before the write answers,
    // which parks the copy in hand at the place being written.
    await useEditorStore.getState().setScope(elsewhere);
    write.land();
    await write.saving;

    const parked = useEditorStore.getState().held.global;
    expect(parked?.draft?.["skill-instructions"]).toEqual({ gh: "second" });
    // It kept the base it was read against — absent — so the file it does
    // not match refuses it on its own evidence when its place is opened.
    expect(parked?.base).not.toBe("created");
  });
});
