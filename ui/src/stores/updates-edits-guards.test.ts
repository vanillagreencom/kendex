import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";
import { keepAsOwn } from "./updates-edits";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    applyDiscardEdits: vi.fn(),
    packageFork: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

function row(overrides: Partial<UpdateRow>): UpdateRow {
  return {
    scope: { scope: "global" },
    kind: "skill",
    name: "gh",
    source: "vstack",
    repo: "owner/catalog",
    repoIdentity: "owner/catalog",
    current: { commit: "a".repeat(40), label: "v1", date: null },
    latest: { commit: "b".repeat(40), label: "v2", date: null },
    updateAvailable: true,
    pinned: false,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forkableHarness: null,
    canDiscard: true,
    canTakeLatest: true,
    holdOwner: null,
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

// What a fork or a discard leaves behind: every reader of the file it
// rewrote refreshed, and the one copy that could undo it refused.
// The Customize tab holds a whole manifest, and both of these rewrite the
// file it came from. Neither may let that copy win.
describe("a fork or discard beside an open Customize tab", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: null,
      dirty: false,
      held: {},
      saved: {},
      manifestsLoaded: false,
      unreadPlaces: {},
    });
    vi.clearAllMocks();
    // Every path here ends by re-reading the place it rewrote.
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "rewritten" },
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
  });
  // The Customize tab holds a whole manifest. Saved after a fork, that copy
  // puts the pre-fork file back and the fork record is gone for good.
  it("refuses while an unsaved customization holds the same file", async () => {
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: { schema: 1, install: {} },
      dirty: true,
    });
    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );
    expect(commands.packageFork).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.title).toContain("Save your");

    // Another place's unsaved work is not this place's problem.
    useEditorStore.setState({ scope: { scope: "project", root: "/work/vg" } });
    vi.mocked(commands.packageFork).mockResolvedValue({
      status: "error",
      error: "nope",
    });
    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );
    expect(commands.packageFork).toHaveBeenCalled();
  });

  // Moving between places parks typing rather than dropping it, so the
  // copy that would undo this write can be behind another place. Whether
  // the write is refused must not depend on where the person happens to be
  // standing.
  it("refuses while typing for this place waits behind another one", async () => {
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: null,
      dirty: false,
      held: {
        global: {
          scope: { scope: "global" },
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );
    expect(commands.packageFork).not.toHaveBeenCalled();
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.title).toContain("Save your");
    // The unsaved copy is not on screen, so the way back to it is named.
    expect(dialog.steps?.[0]).toContain("Personal");
  });

  // The refusal at entry guards a window that stays open for the whole
  // operation, and nothing stops typing during it. Replacing those
  // keystrokes with a re-read, silently, is the worse of the two risks.
  it("leaves typing that arrived mid-operation alone", async () => {
    const view = {
      scope: { scope: "global" } as const,
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      heldBack: [],
      queued: [],
    };
    vi.mocked(commands.packageFork).mockImplementation(async () => {
      // Someone opens the Customize tab and types while the fork runs.
      useEditorStore.setState({
        draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
        dirty: true,
      });
      return { status: "ok", data: view };
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: { schema: 1, install: {} },
      dirty: false,
    });

    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );

    expect(useEditorStore.getState().draft?.["skill-instructions"]).toEqual({
      gh: "mine",
    });
    expect(useEditorStore.getState().dirty).toBe(true);

    // And the save that follows must not put the pre-fork file back over
    // the record just made: keeping the typing is only half the answer.
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "ok",
      data: { view, base: "written", wroteMore: false },
    });
    await useEditorStore.getState().save();
    expect(commands.updateManifest).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.title).toContain(
      "changed while you typed",
    );
    expect(useEditorStore.getState().draft?.["skill-instructions"]).toEqual({
      gh: "mine",
    });
  });
});
