// Which answer wins when a report and a commit race.
//
// A check ranks by when it lands: it reads the standing after fetching
// every mirror, so it saw more than any read still out. That claim holds
// only while nothing commits meanwhile — `updates_refresh` builds its
// report once, and a commit landing after that read is not in it. Claiming
// to be newest would put the rows back as they were before the commit,
// with `read` saying `landed` over them, which re-opens every action on
// rows nobody confirmed.
//
// One case per path that can commit, because the announcement is the thing
// that can be forgotten: it was, for a whole round, with four of five
// paths unwired behind a return message that said otherwise.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { ADOPTABLE } from "@/lib/adoptable";
import { READ_LANDED } from "@/lib/read-state";
import { useUpdatesStore } from "./updates";
import {
  writeDiscardEdits,
  writeFork,
  writeForkBeside,
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
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

/** The scope's view a single-package apply answers with; nothing here reads
 *  it, so it stays the empty one. */
/** A row for this store's own scope, with whatever the case varies. */
const row = (extra: Partial<UpdateRow> = {}): UpdateRow =>
  updateRow("gh", null, extra);

const GLOBAL = { scope: "global" as const };

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

// One case per path that can commit. Each starts the mutation, starts a
// check behind it, lands the mutation, then lands the check's report —
// built before that commit and so missing it. The check must not put the
// rows back.
//
// The order matters: a check already out sets `checking`, which is what
// refuses these mutations in the first place. It is the other direction
// that is open, because `check` guards only against a second check.
//
// Wired by construction rather than by remembering: every write goes
// through `updates-writes.ts`, which announces as the write settles.
describe("a check whose report predates a commit", () => {
  /** What the standing reads back as once the commit has landed. */
  const after = [row({ name: "after-the-commit" })];

  /** Park a command, handing back the resolver. */
  const park = <T>() => {
    let land!: (value: T) => void;
    const promise = new Promise<T>((resolve) => {
      land = resolve;
    });
    return { promise, land: (value: T) => land(value) };
  };

  /** Start a check behind whatever is already running, and hand back the
   *  landing for a report that names itself. */
  const checkBehind = () => {
    const fetch = park<Awaited<ReturnType<typeof commands.updatesRefresh>>>();
    vi.mocked(commands.updatesRefresh).mockReturnValue(fetch.promise);
    const checking = useUpdatesStore.getState().check();
    return async () => {
      fetch.land({
        status: "ok",
        data: {
          rows: [row({ name: "from-the-check" })],
          warnings: [],
          lastFetched: null,
        },
      });
      await checking;
    };
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [row({})], read: READ_LANDED });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: after, warnings: [], lastFetched: null },
    });
  });

  /** The rows the commit produced, not the ones the check reported. */
  const commitStands = () => {
    expect(useUpdatesStore.getState().rows).toEqual(after);
    expect(
      useUpdatesStore.getState().rows.map((one) => one.name),
    ).not.toContain("from-the-check");
  };

  it("loses to updateOne", async () => {
    const apply = park<Awaited<ReturnType<typeof commands.packageUpdate>>>();
    vi.mocked(commands.packageUpdate).mockReturnValue(apply.promise);
    const updating = useUpdatesStore.getState().updateOne(row({}));

    const landCheck = checkBehind();
    apply.land({
      status: "ok",
      data: { view: VIEW, heldBack: [], removed: [], moved: [] },
    });
    await updating;

    await landCheck();
    commitStands();
  });

  it("loses to updateRows", async () => {
    const apply =
      park<Awaited<ReturnType<typeof commands.packageUpdateMany>>>();
    vi.mocked(commands.packageUpdateMany).mockReturnValue(apply.promise);
    const updating = useUpdatesStore
      .getState()
      .updateRows([row({ updateAvailable: true })]);

    const landCheck = checkBehind();
    apply.land({ status: "ok", data: { view: VIEW, packages: [] } });
    await updating;

    await landCheck();
    commitStands();
  });

  it("loses to a Follow flip", async () => {
    const apply = park<Awaited<ReturnType<typeof commands.packageSetRev>>>();
    vi.mocked(commands.packageSetRev).mockReturnValue(apply.promise);
    const flipping = useUpdatesStore
      .getState()
      .setAutoUpdate(
        row({ current: { commit: "a".repeat(40), label: "v1", date: null } }),
        false,
      );

    const landCheck = checkBehind();
    apply.land({
      status: "ok",
      data: { view: VIEW, heldBack: [], removed: [], moved: [] },
    });
    await flipping;

    await landCheck();
    commitStands();
  });

  // The writes the package page and the edited-place actions make. They
  // are reached here through the write itself rather than through their
  // surfaces: what must not be forgotten is the announcement, and a
  // surface that grew a second write would still have to come through one
  // of these.
  it.each([
    [
      "a package page's Update",
      () => writeUpdate(GLOBAL, "skill", "gh"),
      () => vi.mocked(commands.packageUpdate),
    ],
    [
      "keeping an edited place as a fork",
      () => writeFork(GLOBAL, "skill", "gh", "claude"),
      () => vi.mocked(commands.packageFork),
    ],
    [
      "discarding an edited place's edits",
      () => writeDiscardEdits(GLOBAL, "skill", "gh", null),
      () => vi.mocked(commands.applyDiscardEdits),
    ],
    [
      "installing an edited place beside its source",
      () => writeForkBeside(GLOBAL, "skill", "gh", "claude", "mine", null),
      () => vi.mocked(commands.packageForkBeside),
    ],
  ])("loses to %s", async (_name, write, mock) => {
    const landCheck = checkBehind();
    mock().mockResolvedValue({ status: "ok", data: null } as never);
    await write();
    // The surface reads the standing back after its own write; this stands
    // in for that read.
    await useUpdatesStore.getState().reload();

    await landCheck();
    commitStands();
  });

  // The mute carries no row-level refusal, so it is the one path that
  // can also begin while a check is already out.
  it("loses to setIgnored, whichever started first", async () => {
    const landCheck = checkBehind();
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "ok",
      data: { rows: after, warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().setIgnored(row({}), true);

    await landCheck();
    commitStands();
  });
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
