// What a write does beside its command: reads the standing back however
// the command answered, and says the account the answer carries.
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { ADOPTABLE } from "@/lib/adoptable";
import { READ_LANDED } from "@/lib/read-state";
import { startBulk } from "@/lib/update-outcome";
import { useUpdatesStore } from "./updates";
import {
  writeDiscardEdits,
  writeFork,
  writeForkBeside,
  writeRev,
  writeRow,
  writeRows,
  writeUpdate,
} from "./updates-writes";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    packageUpdateMany: vi.fn(),
    packageFork: vi.fn(),
    packageForkBeside: vi.fn(),
    applyDiscardEdits: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn(), message: vi.fn() },
}));

/** A row for this store's own scope, with whatever the case varies. */
const row = (extra: Partial<UpdateRow> = {}): UpdateRow =>
  updateRow("gh", null, extra);

const GLOBAL = { scope: "global" as const };

/** The scope's view a single-package apply answers with; nothing here reads
 *  it, so it stays the empty one. */
const VIEW = {
  scope: { scope: "global" as const },
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
};

beforeEach(() => {
  vi.clearAllMocks();
  useUpdatesStore.setState({
    rows: [],
    busy: false,
    checking: false,
    reading: false,
    pendingFollows: [],
    read: READ_LANDED,
    lastFetched: null,
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
});

describe("a write that answered with an error", () => {
  const after = [row({ name: "after-the-commit" })];

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [row()], read: READ_LANDED });
  });

  // An error answer is not proof that nothing changed. Four of the
  // commands behind these writes persist before a step that can fail:
  // `package_set_rev` and `apply_discard_edits` write the revision through
  // `set_rev_with` and only then apply; `package_update_many` persists any
  // hold its targets carry; `update_set_ignored` writes the preference and
  // then builds the report. So the standing is read again either way, or a
  // change that landed shows as one that did not.
  it.each([
    ["updateOne", () => useUpdatesStore.getState().updateOne(row())],
    [
      "updateRows",
      () =>
        useUpdatesStore.getState().updateRows([row({ updateAvailable: true })]),
    ],
    ["setIgnored", () => useUpdatesStore.getState().setIgnored(row(), true)],
  ])("reads the standing back when %s is refused", async (_name, act) => {
    for (const command of [
      commands.packageUpdate,
      commands.packageUpdateMany,
      commands.updateSetIgnored,
    ]) {
      vi.mocked(command).mockResolvedValue({
        status: "error",
        error: "the apply could not finish",
      } as never);
    }
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: after, warnings: [], lastFetched: null },
    });

    await act();

    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(useUpdatesStore.getState().rows).toEqual(after);
  });
});

// A write that took a package away may have run its uninstaller in the
// person's repository, and that is the write's own account to give. Said on
// the write rather than beside each command, for the reason
// `updates-writes.ts` records: a rule each new mutation has to remember is
// one that gets forgotten.
describe("what a write says about the repository it changed", () => {
  const RAN = "growth-guards: running scripts/install-git-hooks --uninstall";

  /** A single-package answer carrying an account on the standing it nests. */
  const update = (undone: string[]) => ({
    status: "ok" as const,
    data: {
      view: { ...VIEW, undone },
      heldBack: [],
      removed: [],
      moved: [],
    },
  });

  it("says it whichever of the five write commands took the package", async () => {
    for (const [start, mock] of [
      [() => writeUpdate(GLOBAL, "skill", "gh"), commands.packageUpdate],
      [() => writeRev(GLOBAL, "skill", "gh", "c0"), commands.packageSetRev],
      [() => writeFork(GLOBAL, "skill", "gh", "claude"), commands.packageFork],
      [
        () => writeDiscardEdits(GLOBAL, "skill", "gh", null),
        commands.applyDiscardEdits,
      ],
      [
        () => writeForkBeside(GLOBAL, "skill", "gh", "claude", "mine", null),
        commands.packageForkBeside,
      ],
    ] as [() => Promise<unknown>, () => unknown][]) {
      vi.mocked(toast.message).mockClear();
      // biome-ignore lint/suspicious/noExplicitAny: one shape per command
      vi.mocked(mock as any).mockResolvedValue(update([RAN]));

      await start();

      expect(toast.message).toHaveBeenCalledWith(RAN);
    }
  });

  it("stays quiet when the write took no armed package away", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.packageUpdate).mockResolvedValue(update([]));

    await writeUpdate(GLOBAL, "skill", "gh");

    expect(toast.message).not.toHaveBeenCalled();
  });

  // The batched apply is one plan for a whole place, so its account covers
  // every package that left with it and is said once.
  it("says it on the batched apply", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.packageUpdateMany).mockResolvedValue({
      status: "ok",
      data: { view: { ...VIEW, undone: [RAN] }, packages: [] },
    });

    await writeRows([row()], () => {}, startBulk(0));

    expect(toast.message).toHaveBeenCalledWith(RAN);
  });

  // The per-row apply is the other way `package_update` is reached, and it
  // answers through its own outcome rather than through the write's shape.
  it("says it on the per-row apply too", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.packageUpdate).mockResolvedValue(update([RAN]));

    await writeRow(row(), () => {});

    expect(toast.message).toHaveBeenCalledWith(RAN);
  });
});
