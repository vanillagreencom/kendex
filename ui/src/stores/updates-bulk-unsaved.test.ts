import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    applyDiscardEdits: vi.fn(),
    packageFork: vi.fn(),
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

// Update all is one action over several places. Asked per place as the
// loops run, the first refusal would leave the set half updated — some
// places current, one untouched — from a click that never offered to do
// part of it.
describe("a bulk update where one place has unsaved customization", () => {
  const acme = { scope: "project", root: "/home/x/acme" } as const;
  const shop = { scope: "project", root: "/home/x/shop" } as const;

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useEditorStore.setState({
      scope: acme,
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
  });

  it("updates none of them", async () => {
    useEditorStore.setState({
      held: {
        [shop.root]: {
          scope: shop,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme, pinned: true }),
        row({ name: "lint", scope: shop }),
      ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.applyPlan).not.toHaveBeenCalled();
    expect(useUpdatesStore.getState().busy).toBe(false);
  });
});

// The preflight speaks for the set as it stood when the button was
// pressed. Every await after it is a window someone can type in, and the
// place still to be written is the one their typing is about.
describe("typing that arrives while a bulk update is running", () => {
  const acme = { scope: "project", root: "/home/x/acme" } as const;
  const shop = { scope: "project", root: "/home/x/shop" } as const;

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useEditorStore.setState({
      scope: acme,
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
  });

  it("stops before writing the place it is about", async () => {
    const view = {
      scope: acme,
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      heldBack: [],
      queued: [],
    };
    // The first place is written; someone types about the second while it
    // is in flight.
    vi.mocked(commands.packageSetRev).mockImplementation(async () => {
      useEditorStore.setState({
        held: {
          [shop.root]: {
            scope: shop,
            draft: { schema: 1, install: {} },
            base: "read-earlier",
          },
        },
      });
      return { status: "ok", data: view };
    });
    vi.mocked(commands.applyPlan).mockResolvedValue({
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

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme, pinned: true }),
        row({ name: "lint", scope: shop }),
      ]);

    // The first went, because nothing was unsaved when it was asked.
    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    // The second did not: its place is the one the typing is about.
    expect(commands.applyPlan).not.toHaveBeenCalled();
  });
});
