// What a run over several places says it did: one reading of the three
// lists its applies answered with, and counts taken off the rows that
// asked rather than off the renderings, which carry no repository.
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope, UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  ALREADY_CURRENT_TOAST,
  unansweredPackageError,
} from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    packageUpdateMany: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };

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

describe("what a bulk run says it did", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered.
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
      pendingFollows: [],
      read: READ_LANDED,
      lastFetched: null,
    });
    vi.clearAllMocks();
  });

  const view = {
    scope: { scope: "global" as const },
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  };

  /** One rendering of a package in one tool, as an apply reports it. */
  const rendering = (name: string, harness: "claude" | "codex") => ({
    kind: "skill" as const,
    name,
    harness,
    scope: { scope: "global" as const },
    state: "stale" as const,
    detail: "",
  });

  /** What a place's apply answered about one package: the three lists,
   *  empty but for the ones named. */
  const answered = (
    name: string,
    lists: Partial<
      Record<"heldBack" | "removed" | "moved", ReturnType<typeof rendering>[]>
    >,
  ) => ({
    kind: "skill" as const,
    name,
    heldBack: [],
    removed: [],
    moved: [],
    ...lists,
  });

  /** The batched apply answering `answer`, with the reads the run makes
   *  after it and a clear problems dialog to report into. */
  const placeAnswers = (answer: unknown) => {
    vi.mocked(commands.packageUpdateMany).mockResolvedValue(answer as never);
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [],
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
  };

  /** The one place both rows sit in, answering for these packages. */
  const placeSays = (...packages: ReturnType<typeof answered>[]) =>
    placeAnswers({ status: "ok", data: { view, packages } });

  const bothRows = () =>
    useUpdatesStore.getState().updateRows([row({}), row({ name: "lint" })]);

  // A place the plan refused to write over is the half somebody has to
  // act on, so it is the half the toast carries: a count over it would
  // leave the held copy unmentioned and be a lie besides.
  it("says what it held back rather than counting it as updated", async () => {
    placeSays(
      answered("gh", { moved: [rendering("gh", "claude")] }),
      answered("lint", { heldBack: [rendering("lint", "codex")] }),
    );

    await bothRows();

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "The copy in Codex was left as it is — settle it on the package page",
    );
  });

  // Every place in a run can fail. Those errors are on screen, and a
  // green line beside them would be the only untrue thing there.
  it("claims nothing when every place errored", async () => {
    placeAnswers({ status: "error", error: "the scope is locked" });

    await bothRows();

    expect(toast.success).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      "the scope is locked",
    );
  });

  // The other run that writes nothing, and not the same one: every apply
  // committed and the plan had nothing to move, because what was asked
  // for had already come current. Nothing else is on screen to stand for
  // that, so this run speaks.
  it("says so when every apply committed and wrote nothing", async () => {
    placeSays(answered("gh", {}), answered("lint", {}));

    await bothRows();

    expect(toast.success).toHaveBeenCalledWith(ALREADY_CURRENT_TOAST);
    expect(useProblemsStore.getState().dialog.open).toBe(false);
  });

  // The count is packages, not renderings: one package written in two
  // tools is one update.
  it("counts a package written in two tools once", async () => {
    placeSays(
      answered("gh", {
        moved: [rendering("gh", "claude"), rendering("gh", "codex")],
      }),
    );

    await useUpdatesStore.getState().updateRows([row({})]);

    expect(toast.success).toHaveBeenCalledWith("Updated 1 package");
  });

  // Removal is the outcome that took files away, and the tools dedupe:
  // sized by the tools alone, a run that lost two packages in one tool
  // would say "The copy in Claude Code" and count nothing.
  it("names the tool its trashed copies were in, sized by package", async () => {
    placeSays(answered("gh", { removed: [rendering("gh", "claude")] }));

    // Two catalogs' `gh`, so the count is right only off the rows: the
    // renderings both read skill:gh and the tool list dedupes to one.
    await useUpdatesStore
      .getState()
      .updateRows([row({}), row({ scope: VG, repoIdentity: "other/catalog" })]);

    expect(toast.error).toHaveBeenCalledWith(
      "The copies of 2 packages in Claude Code went to the trash and nothing replaced them",
    );
    expect(toast.success).not.toHaveBeenCalled();
  });

  // A place answers for every package it was asked about. One left out
  // means the run cannot say what became of it, and silence reads short.
  it("reports a package the place left out of its answer", async () => {
    placeSays(answered("gh", { moved: [rendering("gh", "claude")] }));

    await bothRows();

    expect(useProblemsStore.getState().dialog.message).toBe(
      unansweredPackageError("lint"),
    );
  });

  // Two projects installing a gh skill from unrelated catalogs are two
  // packages, not one in two places. The renderings cannot answer that —
  // they carry a kind and a name and no repository — so the count comes
  // off the rows that asked, through update-groups' own identity rule.
  it("counts one name from two catalogs as two packages", async () => {
    placeSays(answered("gh", { moved: [rendering("gh", "claude")] }));

    await useUpdatesStore
      .getState()
      .updateRows([row({}), row({ scope: VG, repoIdentity: "other/catalog" })]);

    expect(toast.success).toHaveBeenCalledWith("Updated 2 packages");
  });
});
