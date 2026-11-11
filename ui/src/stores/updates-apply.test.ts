// What a run over several places says it did: one reading of the three
// lists its applies answered with, and counts taken off the rows that
// asked rather than off the renderings, which carry no repository.
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope, UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
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
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };

/** A place's last folder name, which these fixtures keep distinct. */
const placeName = (scope: Scope): string =>
  scope.scope === "global" ? "global" : (scope.root.split("/").at(-1) ?? "");

const row = (overrides: Partial<UpdateRow>): UpdateRow =>
  updateRow("gh", null, {
    repo: "owner/catalog",
    repoIdentity: "owner/catalog",
    current: { commit: "a".repeat(40), label: "v1", date: null },
    latest: { commit: "b".repeat(40), label: "v2", date: null },
    ...overrides,
  });

describe("what a bulk run says it did", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered.
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: {
        harnesses: [],
        items: [],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [],
    });
    useProblemsStore.setState({
      dialog: {
        open: false,
        title: "",
        steps: [],
        actions: [],
        joined: [],
        run: null,
      },
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
      "The copy in Codex was left as it is and is waiting on a decision from you on the package page",
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

  // A place whose apply committed and whose render behind it failed wrote
  // its packages: they count as updated, and the failure is said beside
  // the count rather than turning the place into one more refusal.
  it("counts a place whose later step failed as written, and says the step", async () => {
    placeAnswers({
      status: "ok",
      data: {
        view: { ...view, unfinished: "render bot instructions: disk full" },
        packages: [answered("gh", { moved: [rendering("gh", "claude")] })],
      },
    });

    await useUpdatesStore.getState().updateRows([row({})]);

    expect(toast.success).toHaveBeenCalledWith("Updated 1 package");
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.message).toBe("render bot instructions: disk full");
    expect(dialog.title).toContain("gh");
  });

  // A run that goes on past a failure can fail again. Two places, one
  // apply each, in every order of the two kinds — a write whose later step
  // failed and a refusal — and a package its own place left out of an
  // answer that also says a later step failed: a later failure taking an
  // earlier one's place on screen would leave that one unsaid.
  it("keeps every failure of one run on screen, in any order", async () => {
    const OTHER: Scope = { scope: "project", root: "/work/other" };
    type Says = { unfinished: string } | { refused: string };
    const rows: {
      name: string;
      places: Record<string, Says>;
      wanted: UpdateRow[];
      subjects: string[];
      messages: string[];
    }[] = [
      {
        name: "later step failed, then later step failed",
        places: {
          vg: { unfinished: "render: vg" },
          other: { unfinished: "render: other" },
        },
        wanted: [row({ scope: VG }), row({ name: "lint", scope: OTHER })],
        subjects: ["gh", "lint"],
        messages: ["render: vg", "render: other"],
      },
      {
        name: "later step failed, then refused",
        places: {
          vg: { unfinished: "render: vg" },
          other: { refused: "other is locked" },
        },
        wanted: [row({ scope: VG }), row({ name: "lint", scope: OTHER })],
        subjects: ["gh"],
        messages: ["render: vg", "other is locked"],
      },
      {
        name: "refused, then later step failed",
        places: {
          vg: { refused: "vg is locked" },
          other: { unfinished: "render: other" },
        },
        wanted: [row({ scope: VG }), row({ name: "lint", scope: OTHER })],
        subjects: ["lint"],
        messages: ["vg is locked", "render: other"],
      },
      {
        name: "later step failed, and a package left out of the answer",
        places: { vg: { unfinished: "render: vg" } },
        wanted: [row({ scope: VG }), row({ name: "lint", scope: VG })],
        subjects: ["gh"],
        messages: ["render: vg", unansweredPackageError("lint")],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows) {
      placeAnswers(null);
      vi.mocked(commands.packageUpdateMany).mockImplementation(
        async (scope) => {
          const says = one.places[placeName(scope)];
          if ("refused" in says)
            return { status: "error", error: says.refused };
          // Answers for the place's first package alone, so a second row
          // there is one the answer left out.
          const first = one.wanted.find(
            (wanted) => placeName(wanted.scope) === placeName(scope),
          );
          const name = first?.name ?? "";
          return {
            status: "ok",
            data: {
              view: { ...view, scope, unfinished: says.unfinished },
              packages: [
                answered(name, { moved: [rendering(name, "claude")] }),
              ],
            },
          } as never;
        },
      );

      await useUpdatesStore.getState().updateRows(one.wanted);

      const { dialog } = useProblemsStore.getState();
      const said = [dialog, ...dialog.joined];
      expect(dialog.open, one.name).toBe(true);
      expect(
        said.map((failure) => failure.message),
        one.name,
      ).toEqual(one.messages);
      for (const subject of one.subjects) {
        expect(
          said.some((failure) => failure.title.includes(subject)),
          `${one.name}: ${subject}`,
        ).toBe(true);
      }
    }
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
