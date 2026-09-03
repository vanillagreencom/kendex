// A check ranks by when it lands: it reads the standing after fetching
// every mirror. That holds only while nothing else commits meanwhile —
// `updates_refresh` builds its report once, and a commit landing after that
// read is not in it. So the two never run together, and one write is out at
// a time, which is what lets `busy` be a flag rather than a count.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type UpdateRow } from "@/bindings";
import { packageVersionActions } from "@/components/package/package-version-actions";
import { updateRow } from "@/components/updates-test-rows";
import { READ_LANDED } from "@/lib/read-state";
import { useUpdatesStore } from "./updates";
import { installAsNew, keepAsOwn, takeNewVersion } from "./updates-edits";

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
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn(), message: vi.fn() },
}));

const store = () => useUpdatesStore.getState();
const row = (extra: Partial<UpdateRow> = {}): UpdateRow =>
  updateRow("gh", null, extra);
const EDITED = row({ blockedByLocalEdit: true, forkableHarness: "claude" });
/** Whatever a write answers with. No case reads its content; the lists are
 *  there because a landed apply is said out loud. */
const ANSWERED = {
  status: "ok",
  data: { view: {}, heldBack: [], removed: [], moved: [] },
} as never;

/** Park a command, handing back the resolver. */
const park = () => {
  let land!: (value: never) => void;
  const promise = new Promise<never>((resolve) => {
    land = resolve;
  });
  return { promise, land };
};

/** The package page's Update — the one write that commands the engine from
 *  a component, under a spinner of its own the store cannot see. */
const fromPackagePage = () =>
  packageVersionActions(
    { scope: { scope: "global" }, kind: "skill", name: "gh" },
    "gh",
    false,
    () => {},
    () => {},
  ).updateToLatest({
    id: "b".repeat(40),
    label: "v2",
    date: "2026-01-01T00:00:00Z",
    summary: "the newest",
    installed: false,
    newerThanInstalled: true,
  });

/** Every path that commits, and the command each one reaches. A write not
 *  in this list is a hole in the window below — which is what the Follow
 *  flip, the package page and keep-as-fork each were. */
const WRITES = [
  [commands.updateSetIgnored, () => store().setIgnored(row(), true)],
  [commands.packageSetRev, () => store().setAutoUpdate(row(), false)],
  [commands.packageFork, () => keepAsOwn(EDITED)],
  [commands.applyDiscardEdits, () => takeNewVersion(row())],
  [
    commands.packageForkBeside,
    () => installAsNew(EDITED, "claude", "mine", () => {}),
  ],
  [commands.packageUpdate, () => store().updateOne(row())],
  [commands.packageUpdateMany, () => store().updateRows([row()])],
  [commands.packageUpdate, fromPackagePage],
] as const;

describe("the check and the writes exclude each other", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
      reading: false,
      pendingFollows: [],
      read: READ_LANDED,
      lastFetched: null,
    });
    vi.clearAllMocks();
    vi.mocked(commands.scanMachine).mockResolvedValue(ANSWERED);
    vi.mocked(commands.auditAll).mockResolvedValue(ANSWERED);
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row()], warnings: [], unreadable: [], lastFetched: null },
    });
  });

  /** Start a check, and answer whether it got as far as fetching. */
  const checkRan = async () => {
    vi.mocked(commands.updatesRefresh).mockClear();
    await store().check();
    return vi.mocked(commands.updatesRefresh).mock.calls.length > 0;
  };

  // One case, both directions, every path in `WRITES`. `busy` and
  // `checking` each close one direction and neither closes both.
  it("refuses a check while any write is out, and a write while a check is out", async () => {
    for (const [at, [command, start]] of WRITES.entries()) {
      const out = park();
      vi.mocked(command).mockReturnValue(out.promise);
      const writing = start();

      expect(await checkRan()).toBe(false);
      // And no second write. `busy` is a flag, and a second one releasing
      // it the moment it finished — with the first still committing — is
      // the window a count of who is still in used to cover. The next path
      // round, so every one of them is the refuser once.
      const [next, second] = WRITES[(at + 1) % WRITES.length];
      vi.mocked(next).mockClear();
      await second();
      expect(next).not.toHaveBeenCalled();

      out.land(ANSWERED);
      await writing;
    }

    // The other direction: a check out, and every write refuses rather than
    // committing behind a report already built.
    const fetch = park();
    vi.mocked(commands.updatesRefresh).mockReturnValue(fetch.promise);
    const checking = store().check();
    for (const [command, start] of WRITES) {
      vi.mocked(command).mockClear();
      await start();
      expect(command).not.toHaveBeenCalled();
    }
    fetch.land(ANSWERED);
    await checking;
  });
});
