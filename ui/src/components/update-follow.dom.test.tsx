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
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_ALL_LABEL } from "@/lib/copy";
import {
  followSourceLabel,
  placesLabel,
  UPDATE_PACKAGE_EVERYWHERE_LABEL,
  USER_LEVEL_PLACE,
} from "@/lib/copy-updates";
import { UpdatesPage } from "@/pages/updates";
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

const auditView = {
  scope: { scope: "global" as const },
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
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

/** A command that has been called but has not answered, so a test can read
 *  the page mid-write — where the freeze used to be. */
function pending<T>() {
  let answer!: (value: T) => void;
  const promise = new Promise<T>((resolve) => {
    answer = resolve;
  });
  return { promise, answer };
}

/** gh sits in two places, so its places open behind the expander. */
const openPlaces = async () => {
  await userEvent.click(button(placesLabel(2)));
};

beforeEach(() => {
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
    const write = pending<{ status: "ok"; data: typeof auditView }>();
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

    write.answer({ status: "ok", data: auditView });
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalled();
  });

  it("keeps its new position under a read that lands mid-write", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
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

    write.answer({ status: "ok", data: auditView });
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
    const reread = pending<{
      status: "ok";
      data: { rows: typeof rows; warnings: [] };
    }>();
    vi.mocked(commands.updatesOverview).mockReturnValue(
      reread.promise as never,
    );
    mount(<Live />);
    await openPlaces();

    await act(async () => {
      followSwitch("gh", USER_LEVEL_PLACE).click();
    });
    await settle();

    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    expect(holding(followSwitch("gh", USER_LEVEL_PLACE))).toBe(true);

    // The refusal is news now, not when the read finishes.
    const store = useUpdatesStore.getState();
    await act(async () => {
      void store.updateOne(store.rows[0]);
    });
    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    expect(commands.applyPlan).not.toHaveBeenCalled();

    reread.answer({ status: "ok", data: { rows, warnings: [] } });
    await settle();
    expect(following(followSwitch("gh", USER_LEVEL_PLACE))).toBe(true);
    expect(useUpdatesStore.getState().pendingFollows).toEqual([]);
  });

  it("refuses a second place in the settling scope, and takes another", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
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

    write.answer({ status: "ok", data: auditView });
    await settle();
  });

  it("holds the package-wide Update for a package whose places include the settling scope", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
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

    write.answer({ status: "ok", data: auditView });
    await settle();
    expect(button(UPDATE_PACKAGE_EVERYWHERE_LABEL).disabled).toBe(false);
  });

  it("holds Update all while a flip settles", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
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

    write.answer({ status: "ok", data: auditView });
    await settle();
    expect(updateAll().disabled).toBe(false);
  });
});
