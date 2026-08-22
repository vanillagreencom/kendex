import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";
import { applyMany, applyOne } from "./updates-apply";

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
const auditView = {
  scope: { scope: "global" } as const,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
};

// Moving a hold rewrites the same whole kendex.toml a fork does, on the
// path that was not touched when the fork path was closed.
describe("a pinned update beside an open Customize tab", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    useEditorStore.setState({
      scope: { scope: "global" },
      draft: null,
      dirty: false,
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
  // Moving a hold rewrites the same whole kendex.toml a fork does, on the
  // path that was not touched when the fork path was fixed.
  const heldRow = () =>
    row({
      pinned: true,
      canTakeLatest: true,
      latest: { commit: "b".repeat(40), label: "v2", date: null },
    });

  const typingArrives = () => {
    useEditorStore.setState({
      draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
      dirty: true,
    });
  };

  const refusesTheSaveAfter = async (act: () => Promise<void>) => {
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
      outdated: null,
    });

    await act();

    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
    await useEditorStore.getState().save();
    expect(commands.updateManifest).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.title).toContain(
      "changed while you typed",
    );
  };

  it("refuses the save after a single pinned update", async () => {
    vi.mocked(commands.packageSetRev).mockImplementation(async () => {
      typingArrives();
      return { status: "ok", data: auditView };
    });
    await refusesTheSaveAfter(() => applyOne(heldRow()));
    expect(commands.packageSetRev).toHaveBeenCalled();
  });

  it("refuses the save after a bulk pinned update", async () => {
    vi.mocked(commands.packageSetRev).mockImplementation(async () => {
      typingArrives();
      return { status: "ok", data: auditView };
    });
    await refusesTheSaveAfter(() => applyMany([heldRow()]));
    expect(commands.packageSetRev).toHaveBeenCalled();
  });
});

// An update writes the place's kendex.toml — moving a hold writes the
// revision, applying writes whatever the plan settled — so it waits for
// unsaved customization there like every other writer of that file.
describe("an update beside unsaved customization", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ busy: false });
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
  });

  it("refuses a pinned update while that place's typing waits elsewhere", async () => {
    useEditorStore.setState({
      held: {
        global: {
          scope: { scope: "global" },
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    await applyOne(
      row({
        pinned: true,
        latest: { commit: "b".repeat(40), label: "v2", date: null },
      }),
    );
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.applyPlan).not.toHaveBeenCalled();
    expect(useUpdatesStore.getState().busy).toBe(false);
  });

  it("refuses switching a package off following the same way", async () => {
    useEditorStore.setState({
      held: {
        global: {
          scope: { scope: "global" },
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    await useUpdatesStore.getState().setAutoUpdate(row({}), false);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(useUpdatesStore.getState().busy).toBe(false);
  });
});
