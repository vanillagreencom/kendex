// @vitest-environment jsdom
// The Follow source switch is one row's state change plus a write that
// settles behind it. The backend chain a flip starts — move the hold,
// apply the scope, read every scope's standing again — takes seconds, so
// what these tests hold to is what the page does while it is still
// running: the switch has moved, only the flipped scope is holding, and no
// row ever wears a position the engine did not take while saying it is
// safe to act on.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  type AuditView_Serialize,
  commands,
  type DriftRow_Serialize,
  type PackageUpdate_Serialize,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_ALL_LABEL } from "@/lib/copy";
import {
  followSourceLabel,
  placesLabel,
  UPDATE_PACKAGE_EVERYWHERE_LABEL,
  USER_LEVEL_PLACE,
} from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { rowUnsettled } from "@/lib/updates-read-state";
import { UpdatesPage } from "@/pages/updates";
import { useProblemsStore } from "@/stores/problems";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const APP = "/home/me/app";

// One package in two places, which is what makes the scope term in the
// landing's row matching do any work: name alone would identify every row.
const rows = [row("gh", null), row("gh", APP), row("orch", APP)];

const view: AuditView_Serialize = {
  scope: { scope: "global" },
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
};

/** One rendering an apply wrote, for a report that says it moved
 *  something. `stale` is what a rendering the plan rewrites is: it is on
 *  disk and no longer matches the declaration, which is one of the two
 *  states `package::outcome::moving` counts. */
const wrote: DriftRow_Serialize = {
  kind: "skill",
  name: "gh",
  harness: "claude",
  state: "stale",
  detail: "",
  scope: { scope: "global" },
};

/** What the flip's own apply answers with: the scope's view afterwards,
 *  and what became of the package. Switching Follow off records a hold and
 *  writes nothing, which is `moved` empty. */
const ok: { status: "ok"; data: PackageUpdate_Serialize } = {
  status: "ok",
  data: { view, heldBack: [], removed: [], moved: [] },
};

/** The same, for a flip that resolved the package at its source's tip. */
const okMoved: { status: "ok"; data: PackageUpdate_Serialize } = {
  status: "ok",
  data: { view, heldBack: [], removed: [], moved: [wrote] },
};

/** What the machine scan answers with. Named so a test can hold one
 *  unanswered and read the page while the rescan is still out. */
const SCANNED = {
  status: "ok" as const,
  data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
};

/** One place's gh, held at what is installed: `pinned` with a hold this
 *  declaration owns, which is the only owner whose switch still moves
 *  (a source's or a parent's locks it). Switching it back on is the
 *  direction that resolves the package at its source's tip. */
const heldRows = [
  row("gh", null, { pinned: true, holdOwner: { kind: "package" } }),
  rows[1],
  rows[2],
];

/** The table drawn from the store, the way the page draws it: a flip that
 *  only reaches `rows` is a flip nobody sees. */
const Live = () => {
  const live = useUpdatesStore((s) => s.rows);
  return <UpdatesTable rows={live} onIgnore={() => {}} />;
};

const control = (label: string): HTMLElement => {
  const found = document.querySelector<HTMLElement>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`no control "${label}"`);
  return found;
};

/** One place's switch, by the package and place it names. */
const followSwitch = (name: string, place: string): HTMLElement =>
  control(followSourceLabel(name, place));

const buttons = (label: string): HTMLButtonElement[] =>
  [...document.querySelectorAll("button")].filter(
    (one) => one.textContent === label,
  );

const button = (label: string): HTMLButtonElement => {
  const found = buttons(label)[0];
  if (!found) throw new Error(`no button "${label}"`);
  return found;
};

/** The page header's Update all, not a package row's — the two carry the
 *  same words, and only the table's sits inside it. */
const updateAll = (): HTMLButtonElement => {
  const found = buttons(UPDATE_ALL_LABEL).find((one) => !one.closest("table"));
  if (!found) throw new Error("no page-level Update all");
  return found;
};

const following = (element: HTMLElement): boolean =>
  element.getAttribute("aria-checked") === "true";

const holding = (element: HTMLElement): boolean =>
  element.hasAttribute("disabled") ||
  element.getAttribute("aria-disabled") === "true" ||
  element.hasAttribute("data-disabled");

const outstanding: (() => void)[] = [];

/** A command that has been called but has not answered, so a test can read
 *  the page mid-write — where the freeze used to be. `fallback` answers it
 *  whatever the test did: the applier's chain and its in-flight count are
 *  made once with the store module and no reset here can reach them, so a
 *  command left hanging by a failed assertion fails the tests after it too,
 *  for a reason that is not theirs. */
function pending<T>(fallback: T) {
  let answered = false;
  let answer!: (value: T) => void;
  const promise = new Promise<T>((resolve) => {
    answer = (value) => {
      answered = true;
      resolve(value);
    };
  });
  outstanding.push(() => {
    if (!answered) answer(fallback);
  });
  return { promise, answer };
}

/** gh sits in two places, so its places open behind the expander. */
const openPlaces = async () => {
  await userEvent.click(button(placesLabel(2)));
};

afterEach(async () => {
  for (const release of outstanding.splice(0)) release();
  await act(async () => {});
});

/** Every failure the page announces, so a test can count them: the dialog
 *  itself keeps only the last. */
const showError = vi.fn();

beforeEach(() => {
  useProblemsStore.setState({ showError });
  useUpdatesStore.setState({
    rows,
    busy: false,
    read: READ_LANDED,
    checking: false,
    pendingFollows: [],
  });
  useUpdatesView.setState({ showVersion: false });
  vi.clearAllMocks();
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows, warnings: [], unreadable: [], lastFetched: null },
  });
  // The flip is what asks for these: it re-reads the scan and the audit
  // behind its own standing. `Live` mounts the table, not the page, so
  // nothing else here calls either.
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.scanMachine).mockResolvedValue(SCANNED);
});

describe("the Follow source switch", () => {
  it("moves before the write behind it answers, and holds the page while it does", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    // Held unanswered so the hold can be read while the rescan is still
    // out: `busy` covers the write, the reload and the rescan alike.
    const scan = pending<typeof SCANNED>(SCANNED);
    vi.mocked(commands.scanMachine).mockReturnValue(scan.promise as never);
    mount(<Live />);
    await openPlaces();
    const flipped = followSwitch("gh", USER_LEVEL_PLACE);
    expect(following(flipped)).toBe(true);

    await act(async () => {
      flipped.click();
    });

    // The click path awaits nothing: the switch is off, and the write it
    // started has not answered.
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(false);
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "1111111111",
    );
    expect(commands.updatesOverview).not.toHaveBeenCalled();
    // The same package in another place is a different declaration: the
    // flip is not its.
    expect(following(followSwitch("gh", "app"))).toBe(true);
    // The flip commits like any other write, so it raises the store's
    // `busy` and every control waits on it — that flag is the one a check
    // refuses on, and a write it did not cover is a check running beside
    // it. What stays scoped is which rows the flip leaves unconfirmed.
    expect(holding(followSwitch("gh", "app"))).toBe(true);
    expect(holding(followSwitch("orch", "app"))).toBe(true);

    // The write answering does not release the page: the hold covers the
    // reload and the rescan behind it, and the scan has not answered.
    write.answer(ok);
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(holding(followSwitch("orch", "app"))).toBe(true);

    scan.answer(SCANNED);
    await settle();
    expect(holding(followSwitch("orch", "app"))).toBe(false);
  });

  it("keeps its new position under a read that lands mid-write", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // The window regaining focus rescans, and that read carries the
    // switch's old position — landing it raw would bounce the switch back
    // under the hand that moved it.
    await act(async () => {
      await useUpdatesStore.getState().reload();
    });

    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(false);
    // The landing carries the flip onto the flipped place alone.
    expect(following(followSwitch("gh", "app"))).toBe(true);

    write.answer(ok);
    await settle();
  });

  // A refused write is not a write that changed nothing — `lib/rescan.ts`'s
  // header says what does and does not survive a failed apply. So the click
  // has no account of where the switch belongs: restoring it from the row
  // the click read would show that as settled and re-open every action
  // against it. The standing is read again, and the engine's own answer
  // decides where the switch sits.
  it("reads the standing back when the write is refused", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    // What the engine turns out to hold once it is asked — held, against a
    // click that asked to follow. Which way it went is the read's to say,
    // not the click's; the fixture makes the two disagree so the assertion
    // below can tell them apart.
    const heldByEngine = [
      { ...rows[0], pinned: true, holdOwner: { kind: "package" as const } },
      rows[1],
      rows[2],
    ];
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: heldByEngine,
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.updatesOverview).toHaveBeenCalled();
    // And so are the scan and the audit: the error is no account of what is
    // on disk, on `rescan.ts`'s rule.
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
    // The flip is retired before that read, so the rows come back as the
    // engine has them rather than wearing a position it never took.
    expect(useUpdatesStore.getState().pendingFollows).toEqual([]);
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(false);
    // And said once. A second announcement re-opened a dialog the person
    // had already dismissed.
    expect(
      showError.mock.calls.filter(
        (call) => call[0].message === "manifest busy",
      ),
    ).toHaveLength(1);
  });

  // What a landed flip refreshes, and when. The apply resolves the package
  // at its source's tip and moves installed bytes, so the scan that lists
  // them and the audit that scored them both answer for content that is
  // gone until they are asked again — the same three reads `updateOne` runs
  // behind the identical apply. Read behind the write, never beside it: a
  // scan that starts before the apply answers reports the bytes it is about
  // to replace, which is the staleness itself with an extra call.
  it("reads the standing, the scan and the audit back after a landed flip", async () => {
    const write = pending<typeof okMoved>(okMoved);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    expect(commands.packageSetRev).toHaveBeenCalled();
    expect(commands.scanMachine).not.toHaveBeenCalled();
    expect(commands.auditAll).not.toHaveBeenCalled();

    write.answer(okMoved);
    await settle();

    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
  });

  // The direction the flip is for: Follow back ON resolves the package at
  // its source's tip, which is what moves installed bytes. Every other test
  // here starts from a following row and switches OFF, so a rescan run only
  // on the off direction would pass them all.
  it("reads the scan and the audit back after Follow is switched on", async () => {
    useUpdatesStore.setState({ rows: heldRows });
    const write = pending<typeof okMoved>(okMoved);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(false);

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // A null revision is the write that lets the package follow again.
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      null,
    );
    expect(commands.scanMachine).not.toHaveBeenCalled();

    write.answer(okMoved);
    await settle();

    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
  });

  // A flip that answers with nothing moved is asked for anyway. No field of
  // that answer is a complete account of what the apply wrote — `moved`
  // covers two of the drift states, `removed` the other destructive one,
  // and a dropped rendering answers with all three empty — so gating the
  // rescan on any of them is the stale page this reads against.
  it("reads the scan and the audit back after a flip that moved nothing", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(ok as never);
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
  });

  it("refuses a second flip, in the settling scope or any other", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();
    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // One write at a time, page-wide, whichever scope the second would
    // reach: `busy` is a flag, and a second flip released it the moment it
    // finished — with the first still committing, and a check free to build
    // a report the commit is not in.
    await act(async () => {
      void useUpdatesStore.getState().setAutoUpdate(rows[0], true);
      void useUpdatesStore.getState().setAutoUpdate(rows[2], false);
    });

    expect(
      useUpdatesStore.getState().pendingFollows.map((one) => one.name),
    ).toEqual(["gh"]);

    write.answer(ok);
    await settle();
  });

  it("holds the package-wide Update for a package whose places include the settling scope", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();
    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // gh has a place in the settling scope; orch's single place does not.
    // The write holds both while it runs, so the distinction is read where
    // it is still made: which rows the flip leaves unconfirmed.
    expect(button(UPDATE_PACKAGE_EVERYWHERE_LABEL).disabled).toBe(true);
    const settling = useUpdatesStore.getState();
    expect(rowUnsettled(settling, rows[0])).toBe(true);
    expect(rowUnsettled(settling, rows[2])).toBe(false);

    write.answer(ok);
    await settle();
    expect(button(UPDATE_PACKAGE_EVERYWHERE_LABEL).disabled).toBe(false);
  });

  it("holds Update all while a flip settles", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<UpdatesPage />);
    await settle();
    await openPlaces();
    expect(updateAll().disabled).toBe(false);

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // Update all acts on every visible row, and one of them is in the
    // scope being applied.
    expect(updateAll().disabled).toBe(true);

    write.answer(ok);
    await settle();
    expect(updateAll().disabled).toBe(false);
  });
});
