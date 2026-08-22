import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Manifest_Serialize, Scope } from "@/bindings";
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

const manifest = (note: string): Manifest_Serialize => ({
  schema: 1,
  install: {},
  "skill-instructions": { gh: note },
});

/** A read of a place: its manifest and what the file was when it was read. */
const read = (note: string) => ({ manifest: manifest(note), base: note });

const note = () =>
  useEditorStore.getState().draft?.["skill-instructions"]?.gh ?? null;

const type = (text: string) =>
  useEditorStore.getState().edit((draft) => ({
    ...draft,
    "skill-instructions": { gh: text },
  }));

beforeEach(() => {
  // Each place declares its own skills, which is the whole point of the
  // form's pickers.
  vi.mocked(commands.editorInventory).mockImplementation(
    async (scope: Scope) => ({
      status: "ok" as const,
      data: {
        declaredAgents: [],
        declaredSkills: [scope.scope === "global" ? "global" : scope.root],
        availableSkills: [],
        harnesses: [],
        hookEvents: [],
      },
    }),
  );
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

// Every per-place mark is a link to another place, so crossing places is
// the ordinary way to move. A move that dropped what was typed would make
// the feature's main gesture the one that costs you work.
describe("moving the editor between places while typing is unsaved", () => {
  it("keeps the typing for its own place and gives it back on return", async () => {
    await useEditorStore.getState().openScope(A);
    type("typed at a, never saved");
    await useEditorStore.getState().openScope(B);

    // Nothing of A's is on screen at B — that would save one place's
    // manifest into another place's file.
    expect(note()).toBe("/work/b");
    expect(useEditorStore.getState().dirty).toBe(false);

    await useEditorStore.getState().openScope(A);
    expect(note()).toBe("typed at a, never saved");
    expect(useEditorStore.getState().dirty).toBe(true);
    // Back on screen means no longer waiting, or the note about typing
    // left elsewhere would name the place in front of you.
    expect(useEditorStore.getState().held).toEqual({});
  });

  it("keeps typing at more than one place at a time", async () => {
    await useEditorStore.getState().openScope(A);
    type("a");
    await useEditorStore.getState().openScope(B);
    type("b");
    await useEditorStore.getState().setScope({ scope: "global" });

    expect(Object.keys(useEditorStore.getState().held).sort()).toEqual([
      "/work/a",
      "/work/b",
    ]);
    await useEditorStore.getState().openScope(B);
    expect(note()).toBe("b");
    await useEditorStore.getState().openScope(A);
    expect(note()).toBe("a");
  });

  it("carries the base the typing was read against", async () => {
    await useEditorStore.getState().openScope(A);
    type("typed at a");
    await useEditorStore.getState().openScope(B);
    // The file at A became something else while the typing waited. The
    // base travels with the draft, so the write still has the one fact
    // that refuses it — nothing had to notice the rewrite.
    vi.mocked(commands.getManifest).mockImplementation(async () => ({
      status: "ok" as const,
      data: read("rewritten"),
    }));
    await useEditorStore.getState().openScope(A);
    expect(useEditorStore.getState().base).toBe("/work/a");
  });

  it("keeps what is in hand when pointed at the place already open", async () => {
    await useEditorStore.getState().openScope(A);
    type("still typing");
    await useEditorStore.getState().setScope(A);
    expect(note()).toBe("still typing");
    expect(useEditorStore.getState().dirty).toBe(true);
  });
});

// The parked draft is the person's. Everything else about a place — what
// it declares, what its catalogs carry — is the place's, and holding it
// with the draft offers one project's choices while editing another.
describe("what comes back with a parked draft", () => {
  it("gives the form the place's own inventory, not the one it came from", async () => {
    await useEditorStore.getState().openScope(A);
    type("typed at a");
    await useEditorStore.getState().openScope(B);
    expect(useEditorStore.getState().inventory?.declaredSkills).toEqual([
      "/work/b",
    ]);

    await useEditorStore.getState().openScope(A);
    expect(useEditorStore.getState().draft?.["skill-instructions"]?.gh).toBe(
      "typed at a",
    );
    expect(useEditorStore.getState().inventory?.declaredSkills).toEqual([
      "/work/a",
    ]);
  });
});
