import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    packageUpdateMany: vi.fn(),
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
    source: "kendex",
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
    noPerPackageUpdate: null,
    ...overrides,
  };
}

describe("updates store: bulk update", () => {
  /** Every place answers that it wrote each package it was given, and the
   *  reads that follow the run find nothing left over. */
  const cleanly = (scope: UpdateRow["scope"]) => {
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => ({
        status: "ok",
        data: {
          view: {
            scope,
            drift: [],
            plan: [],
            notes: [],
            warnings: [],
            safety: [],
            adoptable: ADOPTABLE,
            exits: [],
          },
          packages: targets.map((target) => ({
            kind: target.kind,
            name: target.name,
            heldBack: [],
            removed: [],
            moved: [],
          })),
        },
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  // A transport rejection escapes the apply sequence without recording a
  // failure — only the applier sees it, and the success toast must not
  // stand over it.
  it("claims no success when the transport fails mid-run", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageUpdateMany).mockRejectedValue(
      new Error("ipc down"),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateRows([row({})]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
  });

  it("a bulk update brings each place current on its own", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    const view = {
      scope: { scope: "global" } as const,
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      adoptable: ADOPTABLE,
      exits: [],
    };
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => ({
        status: "ok",
        data: {
          view,
          packages: targets.map((target) => ({
            kind: target.kind,
            name: target.name,
            heldBack: [],
            removed: [],
            moved: [],
          })),
        },
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateRows([
      row({ name: "gh", scope: acme, pinned: true }),
      row({ name: "review", scope: acme }),
      row({ name: "gh" }),
      row({
        name: "gh",
        scope: shop,
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);

    // One call per place, never one per row: acme's held gh and its
    // following review travel in the same plan, with the hold carried on
    // gh's target alone.
    expect(vi.mocked(commands.packageUpdateMany).mock.calls).toEqual([
      [
        acme,
        [
          { kind: "skill", name: "gh", hold: "b".repeat(40) },
          { kind: "skill", name: "review", hold: null },
        ],
      ],
      [{ scope: "global" }, [{ kind: "skill", name: "gh", hold: null }]],
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 2 packages — 1 place needs attention on its own row",
    );
  });

  // The cost this batching exists to recover: a place with five rows once
  // paid five whole-scope plans, five journalled applies and five audit
  // views for one click.
  it("costs a place one apply however many rows it has", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    cleanly(acme);

    await useUpdatesStore
      .getState()
      .updateRows(
        ["gh", "review", "deploy", "lint", "release"].map((name) =>
          row({ name, scope: acme }),
        ),
      );

    expect(commands.packageUpdateMany).toHaveBeenCalledTimes(1);
    expect(
      vi.mocked(commands.packageUpdateMany).mock.calls[0]?.[1],
    ).toHaveLength(5);
    expect(toast.success).toHaveBeenCalledWith("Everything is up to date");
  });

  // The batch answers for every package it was given. One missing means
  // the run cannot say what became of that package, and a count that
  // quietly dropped it would claim less than the run actually did.
  it("says so rather than miscounting when a package goes unanswered", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    cleanly(acme);
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => ({
        status: "ok",
        data: {
          view: {
            scope: acme,
            drift: [],
            plan: [],
            notes: [],
            warnings: [],
            safety: [],
            adoptable: ADOPTABLE,
            exits: [],
          },
          packages: targets
            .filter((target) => target.name !== "review")
            .map((target) => ({
              kind: target.kind,
              name: target.name,
              heldBack: [],
              removed: [],
              moved: [],
            })),
        },
      }),
    );

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme }),
        row({ name: "review", scope: acme }),
      ]);

    expect(useProblemsStore.getState().dialog.message).toBe(
      "review was applied with its place, but the answer for it did not come back — check the package's own row",
    );
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "1 package came current in this run — what did not is in the error above",
    );
  });

  it("one package's bulk update leaves scopes only other packages live in alone", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    cleanly(acme);
    useUpdatesStore.setState({
      rows: [
        row({ name: "gh", scope: acme }),
        row({ name: "review", scope: shop }),
      ],
      loaded: true,
    });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh", scope: acme })]);

    expect(vi.mocked(commands.packageUpdateMany).mock.calls).toEqual([
      [acme, [{ kind: "skill", name: "gh", hold: null }]],
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  it("says so instead of celebrating when every place needs a decision", async () => {
    await useUpdatesStore.getState().updateRows([
      row({
        name: "gh",
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);

    expect(commands.packageUpdateMany).not.toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "Nothing to update — 1 place needs attention on its own row",
    );
  });

  it("never moves a hold that belongs to a bundle or parent", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    cleanly(acme);

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme, derived: true, pinned: true }),
        row({ name: "review", scope: acme, derived: true }),
      ]);

    // The held derived row never reaches a target at all, so no hold of an
    // owner's rides in on the place's batch.
    expect(vi.mocked(commands.packageUpdateMany).mock.calls).toEqual([
      [acme, [{ kind: "skill", name: "review", hold: null }]],
    ]);
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 1 package — 1 place needs attention on its own row",
    );
  });
});

describe("updates store: what a bulk update claims about held-back places", () => {
  const emptyView = {
    scope: { scope: "global" } as const,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
    error: null,
  };
  // Not a local edit: the Updates page filters those out before it applies.
  // A revision conflict, or files sitting where a newly targeted tool
  // installs, reaches the plan and is held back there.
  const conflict = (name: string) => ({
    kind: "skill" as const,
    name,
    harness: "claude" as const,
    scope: { scope: "global" } as const,
    state: "conflict" as const,
    detail: "files kendex did not write are in the way",
    cause: "unmanaged-content" as const,
  });
  const stale = (name: string) => ({
    ...conflict(name),
    state: "stale" as const,
    cause: "upstream-changed" as const,
  });

  const answering = (
    per: Record<string, { heldBack: string[]; moved: string[] }>,
  ) => {
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => ({
        status: "ok",
        data: {
          view: emptyView,
          packages: targets.map((target) => ({
            kind: target.kind,
            name: target.name,
            heldBack: (per[target.name]?.heldBack ?? []).map(conflict),
            removed: [],
            moved: (per[target.name]?.moved ?? []).map(stale),
          })),
        },
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  it("claims nothing when every place it applied was held back", async () => {
    answering({ gh: { heldBack: ["gh"], moved: [] } });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(commands.packageUpdateMany).toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "Nothing was updated — 1 place needs attention on its own row",
    );
  });

  it("counts only the packages that moved, and names the rest as waiting", async () => {
    answering({
      gh: { heldBack: [], moved: ["gh"] },
      review: { heldBack: ["review"], moved: [] },
    });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review" })]);

    expect(toast.info).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 1 package — 1 place needs attention on its own row",
    );
  });

  it("counts a package held in one tool and current in another as both", async () => {
    answering({ gh: { heldBack: ["gh"], moved: ["gh"] } });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(toast.info).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 1 package — 1 place needs attention on its own row",
    );
  });
});

describe("updates store: a bulk run that took a copy away", () => {
  const emptyView = {
    scope: { scope: "global" } as const,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
    error: null,
  };
  const conflict = (name: string) => ({
    kind: "skill" as const,
    name,
    harness: "claude" as const,
    scope: { scope: "global" } as const,
    state: "conflict" as const,
    detail: "the previous installation will be moved to the trash",
    cause: null,
  });
  const stale = (name: string) => ({
    ...conflict(name),
    state: "stale" as const,
    cause: "upstream-changed" as const,
  });

  const answering = (
    per: Record<
      string,
      { heldBack?: string[]; removed?: string[]; moved?: string[] }
    >,
  ) => {
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => ({
        status: "ok",
        data: {
          view: emptyView,
          packages: targets.map((target) => ({
            kind: target.kind,
            name: target.name,
            heldBack: (per[target.name]?.heldBack ?? []).map(conflict),
            removed: (per[target.name]?.removed ?? []).map(conflict),
            moved: (per[target.name]?.moved ?? []).map(stale),
          })),
        },
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  it("never claims success over a package whose only copy was trashed", async () => {
    answering({ gh: { removed: ["gh"] } });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
  });

  // Three things happened; the run says all three rather than picking one.
  it("names what moved, what was held, and what went to the trash", async () => {
    answering({
      gh: { moved: ["gh"] },
      review: { heldBack: ["review"] },
      deploy: { removed: ["deploy"] },
    });

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh" }),
        row({ name: "review" }),
        row({ name: "deploy" }),
      ]);

    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 1 package — 1 place needs attention on its own row",
    );
  });

  // One package can be both: trashed in one tool, refused in another.
  it("counts a package that was both trashed and held in both columns", async () => {
    answering({ gh: { removed: ["gh"], heldBack: ["gh"] } });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
  });
});

describe("updates store: a run where one place failed", () => {
  const acme = { scope: "project", root: "/home/x/acme" } as const;
  const emptyView = {
    scope: { scope: "global" } as const,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
    error: null,
  };
  const conflict = (name: string) => ({
    kind: "skill" as const,
    name,
    harness: "claude" as const,
    scope: { scope: "global" } as const,
    state: "conflict" as const,
    detail: "the previous installation will be moved to the trash",
    cause: null,
  });
  const stale = (name: string) => ({
    ...conflict(name),
    state: "stale" as const,
    cause: "upstream-changed" as const,
  });

  // A place is one apply, so what is said per package here is said about
  // the place that package is the only row of.
  const answering = (
    per: Record<string, { removed?: string[]; moved?: string[] } | "fails">,
  ) => {
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => {
        if (targets.some((target) => per[target.name] === "fails")) {
          return { status: "error", error: "ipc down" };
        }
        return {
          status: "ok",
          data: {
            view: emptyView,
            packages: targets.map((target) => {
              const said = per[target.name];
              return {
                kind: target.kind,
                name: target.name,
                heldBack: [],
                removed: (said === "fails" ? [] : (said?.removed ?? [])).map(
                  conflict,
                ),
                moved: (said === "fails" ? [] : (said?.moved ?? [])).map(stale),
              };
            }),
          },
        };
      },
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  // The error is one place's; the trashed copy is another's, and it is not
  // the error's to swallow.
  it("still says a copy went to the trash when a later place failed", async () => {
    answering({ gh: { removed: ["gh"] }, review: "fails" });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review", scope: acme })]);

    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("says what came current beside the error, never as a success", async () => {
    answering({ gh: { moved: ["gh"] }, review: "fails" });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review", scope: acme })]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "1 package came current in this run — what did not is in the error above",
    );
  });

  // A place is one plan and one apply: a place that fails takes every row
  // it carried with it, and the run claims nothing for any of them.
  it("claims nothing for a package sharing a place with a failed one", async () => {
    answering({ gh: { moved: ["gh"] }, review: "fails" });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review" })]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).not.toHaveBeenCalled();
  });

  it("adds nothing of its own when the only place failed", async () => {
    answering({ gh: "fails" });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).not.toHaveBeenCalled();
    expect(toast.error).not.toHaveBeenCalled();
  });
});

describe("updates store: what a bulk run cannot lose", () => {
  const emptyView = {
    scope: { scope: "global" } as const,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
    error: null,
  };
  const conflict = (name: string) => ({
    kind: "skill" as const,
    name,
    harness: "claude" as const,
    scope: { scope: "global" } as const,
    state: "conflict" as const,
    detail: "the previous installation will be moved to the trash",
    cause: null,
  });
  const stale = (name: string) => ({
    ...conflict(name),
    state: "stale" as const,
    cause: "upstream-changed" as const,
  });

  const answering = (
    per: Record<string, { removed?: string[]; moved?: string[] } | "rejects">,
    remaining: UpdateRow[] = [],
  ) => {
    vi.mocked(commands.packageUpdateMany).mockImplementation(
      async (_scope, targets) => {
        // A transport rejection, not an answer: the promise throws and the
        // loop never returns.
        if (targets.some((target) => per[target.name] === "rejects")) {
          throw new Error("ipc down");
        }
        return {
          status: "ok",
          data: {
            view: emptyView,
            packages: targets.map((target) => {
              const said = per[target.name];
              return {
                kind: target.kind,
                name: target.name,
                heldBack: [],
                removed: (said === "rejects" ? [] : (said?.removed ?? [])).map(
                  conflict,
                ),
                moved: (said === "rejects" ? [] : (said?.moved ?? [])).map(
                  stale,
                ),
              };
            }),
          },
        };
      },
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: remaining, warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  // The first apply committed. A later place throwing does not un-commit
  // it, so the run cannot go quiet about a copy it took away.
  it("keeps an earlier removal when a later place rejects outright", async () => {
    answering({ gh: { removed: ["gh"] }, review: "rejects" });

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh" }),
        row({ name: "review", scope: { scope: "project", root: "/home/x/a" } }),
      ]);

    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
    expect(useProblemsStore.getState().dialog.message).toContain("ipc down");
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("never says everything is up to date over a copy it removed", async () => {
    answering({ gh: { removed: ["gh"] }, review: { moved: ["review"] } });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review" })]);

    expect(toast.error).toHaveBeenCalledWith(
      "1 package could not be installed — its copy went to the trash and nothing replaced it",
    );
    expect(toast.success).not.toHaveBeenCalledWith("Everything is up to date");
    expect(toast.success).toHaveBeenCalledWith("Updated review");
  });

  // The control: a run that left nothing behind still gets the all-clear.
  it("still says everything is up to date after a clean run", async () => {
    answering({ gh: { moved: ["gh"] } });

    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);

    expect(toast.error).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith("Everything is up to date");
  });
});
