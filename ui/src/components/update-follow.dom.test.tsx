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
    data: { rows, warnings: [], lastFetched: null },
  });
  // The page asks for an audit on mount; nothing here reads it.
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
});

describe("the Follow source switch", () => {
  it("moves before the write behind it answers, and holds the page while it does", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
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

    write.answer(ok);
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalled();
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

  // A refused write is not a write that changed nothing. `package_set_rev`
  // persists the revision through `set_rev_with` and only then runs the
  // apply, so an apply that fails answers with an error over a manifest
  // that already moved. Restoring the switch from the row the click read
  // would show that as settled and re-open every action against it — so
  // the standing is read again, and the engine's own answer decides where
  // the switch sits.
  it("reads the standing back when the write is refused", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    // What the engine turns out to hold: the revision the failed apply
    // had already persisted.
    const persisted = [
      { ...rows[0], pinned: true, holdOwner: { kind: "package" as const } },
      rows[1],
      rows[2],
    ];
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: persisted, warnings: [], lastFetched: null },
    });
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.updatesOverview).toHaveBeenCalled();
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

  // What a landed flip refreshes, and what it leaves. The apply resolves
  // the package at its source's tip and moves installed bytes, so the scan
  // that lists them and the audit that scored them are both out of date
  // afterwards — and neither is re-asked. That is how the flip has always
  // behaved; this holds it as it is, so a change to it is a decision
  // somebody makes rather than a thing that drifts.
  it("reads the standing back and leaves the scan and the audit dated", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(okMoved as never);
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.packageSetRev).toHaveBeenCalled();
    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(commands.scanMachine).not.toHaveBeenCalled();
    expect(commands.auditAll).not.toHaveBeenCalled();
  });

  it("refuses a second place in the settling scope, and takes another", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();
    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // The apply behind the first flip can move what is installed in its
    // scope, so a second hold captured there would pin a commit about to
    // go stale. Another scope's is untouched by it.
    await act(async () => {
      void useUpdatesStore.getState().setAutoUpdate(rows[0], true);
      void useUpdatesStore.getState().setAutoUpdate(rows[2], false);
    });

    expect(
      useUpdatesStore.getState().pendingFollows.map((one) => one.name),
    ).toEqual(["gh", "orch"]);

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
