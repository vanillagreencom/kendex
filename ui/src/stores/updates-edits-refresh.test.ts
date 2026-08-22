import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
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
describe("after a fork or a discard", () => {
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
      data: { manifest: null, base: null },
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
  // reads comes from that file. Nothing else re-reads it.
  it("re-reads the manifests a fork rewrote, so the mark appears at once", async () => {
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
    vi.mocked(commands.packageFork).mockResolvedValue({
      status: "ok",
      data: view,
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
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: {
        manifest: {
          schema: 1,
          install: {},
          forks: {
            skill: { gh: { source: "cat", "forked-at": "2026-08-01" } },
          },
        },
        base: "after-the-fork",
      },
    });

    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );

    expect(useEditorStore.getState().saved.global?.forks).toEqual({
      skill: { gh: { source: "cat", "forked-at": "2026-08-01" } },
    });
  });

  // The editor surfaces join through the copy in hand, not the saved map,
  // so a pass that fills only `saved` leaves the badge off on the very page
  // the button lives on — and a later Save writes that copy back.
  it("re-reads the copy in hand for the place a fork rewrote", async () => {
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
    vi.mocked(commands.packageFork).mockResolvedValue({
      status: "ok",
      data: view,
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
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: {
        manifest: {
          schema: 1,
          install: {},
          forks: {
            skill: { gh: { source: "cat", "forked-at": "2026-08-01" } },
          },
        },
        base: "after-the-fork",
      },
    });
    // The editor is pointed at the place the fork rewrote, holding the
    // manifest as it was before it.
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

    expect(useEditorStore.getState().draft?.forks).toEqual({
      skill: { gh: { source: "cat", "forked-at": "2026-08-01" } },
    });
  });
});
