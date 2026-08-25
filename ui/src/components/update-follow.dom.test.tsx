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
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_ALL_LABEL } from "@/lib/copy";
import {
  followSourceLabel,
  placesLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_PACKAGE_EVERYWHERE_LABEL,
  USER_LEVEL_PLACE,
} from "@/lib/copy-updates";
import { UpdatesPage } from "@/pages/updates";
import { useProblemsStore } from "@/stores/problems";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", () => ({
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

/** What the two held commands answer with: the flip's own apply, and the
 *  read of the standing that reconciles it. */
const ok = {
  status: "ok" as const,
  data: {
    scope: { scope: "global" as const },
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  },
};
const landed = { status: "ok" as const, data: { rows, warnings: [] as [] } };

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
    loaded: true,
    checking: false,
    overviewInFlight: false,
    pendingFollows: [],
    error: null,
  });
  useUpdatesView.setState({ showVersion: false });
  vi.clearAllMocks();
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows, warnings: [] },
  });
});

describe("the Follow source switch", () => {
  it("moves before the write behind it answers, holding only its scope", async () => {
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
    // The scope being applied holds; the project scope is untouched by it
    // and stays live.
    expect(holding(followSwitch("gh", "app"))).toBe(false);
    expect(holding(followSwitch("orch", "app"))).toBe(false);

    write.answer(ok);
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalled();
  });

  it("keeps its new position under a read that lands mid-write", async () => {
    const write = pending<typeof ok>(ok);
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });

    // The window regaining focus rescans, and that read can reach the
    // manifest before the write does — it carries the switch's old
    // position, and landing it raw would bounce the switch back.
    await act(async () => {
      await useUpdatesStore.getState().load();
    });

    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(false);
    // The landing carries the flip onto the flipped place alone.
    expect(following(followSwitch("gh", "app"))).toBe(true);

    write.answer(ok);
    await settle();
  });

  // The engine wrote nothing, but the rows already wear the flip. Until the
  // read that puts them back lands, the place goes on holding: a row that
  // said it was settled here would hand updateOne a pin that never landed.
  it("goes on holding a refused flip until the read behind it lands", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    const reread = pending<typeof landed>(landed);
    vi.mocked(commands.updatesOverview).mockReturnValue(
      reread.promise as never,
    );
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    expect(holding(followSwitch("gh", USER_LEVEL_PLACE))).toBe(true);

    // The refusal is news now, not when the read finishes.
    expect(showError).toHaveBeenCalledTimes(1);
    expect(showError.mock.calls[0][0].message).toBe("manifest busy");

    // The reverting flip keeps this scope's commit-applying actions out.
    const store = useUpdatesStore.getState();
    await act(async () => {
      void store.updateOne(store.rows[0]);
    });
    expect(showError).toHaveBeenLastCalledWith(
      expect.objectContaining({ message: UPDATE_NEEDS_CHECK_NOTE }),
    );

    reread.answer(landed);
    await settle();
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(true);
    expect(useUpdatesStore.getState().pendingFollows).toEqual([]);
    // And said once. The second announcement arrived when the read
    // finished, re-opening a dialog the person had already dismissed.
    expect(
      showError.mock.calls.filter(
        (call) => call[0].message === "manifest busy",
      ),
    ).toHaveLength(1);
  });

  // Every read behind a refused write failed, so nothing is coming to
  // replace the rows the flip painted. The page is held under its own
  // "couldn't confirm" banner, but the switch must still not sit in a
  // position the engine never took.
  it("puts the switch back when nothing lands to replace the flip", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "error",
      error: "standing unreadable",
    });
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(true);
    expect(useUpdatesStore.getState().pendingFollows).toEqual([]);
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

    // gh has a place in the settling scope; orch's single place does not,
    // and its own Update stays live.
    expect(button(UPDATE_PACKAGE_EVERYWHERE_LABEL).disabled).toBe(true);
    expect(holding(followSwitch("orch", "app"))).toBe(false);

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
