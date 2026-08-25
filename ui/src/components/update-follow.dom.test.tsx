// @vitest-environment jsdom
// The Follow source switch is one row's state change plus a write that
// settles behind it. The backend chain a flip starts — move the hold,
// apply the scope, read every scope's standing again — takes seconds, so
// what these tests hold to is what the page does while it is still
// running: the switch has moved, and only the flipped scope is holding.
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const rows = [row("gh", null), row("dev", null), row("orch", "/home/me/app")];

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

const switches = () => [
  ...document.querySelectorAll<HTMLElement>('[role="switch"]'),
];

const following = (index: number): boolean =>
  switches()[index].getAttribute("aria-checked") === "true";

const holding = (index: number): boolean => {
  const control = switches()[index];
  return (
    control.hasAttribute("disabled") ||
    control.getAttribute("aria-disabled") === "true" ||
    control.hasAttribute("data-disabled")
  );
};

/** A command that has been called but has not answered, so a test can read
 *  the page mid-write — where the freeze used to be. */
function pending<T>() {
  let answer!: (value: T) => void;
  const promise = new Promise<T>((resolve) => {
    answer = resolve;
  });
  return { promise, answer };
}

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
    expect(following(0)).toBe(true);

    await act(async () => {
      switches()[0].click();
    });

    // The click path awaits nothing: the switch is off, and the write it
    // started has not answered.
    expect(following(0)).toBe(false);
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "1111111111",
    );
    expect(commands.updatesOverview).not.toHaveBeenCalled();
    // The scope being applied holds; the project scope is untouched by it
    // and stays live.
    expect(holding(1)).toBe(true);
    expect(holding(2)).toBe(false);

    write.answer({ status: "ok", data: auditView });
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(holding(1)).toBe(false);
  });

  it("keeps its new position under a read that lands mid-write", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);

    await act(async () => {
      switches()[0].click();
    });
    expect(following(0)).toBe(false);

    // The window regaining focus rescans, and that read can reach the
    // manifest before the write does — it carries the switch's old
    // position, and landing it raw would bounce the switch back.
    await act(async () => {
      await useUpdatesStore.getState().load();
    });

    expect(following(0)).toBe(false);

    write.answer({ status: "ok", data: auditView });
    await settle();
  });

  it("puts the switch back when the write is refused", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    mount(<Live />);

    await act(async () => {
      switches()[0].click();
    });
    await settle();

    expect(following(0)).toBe(true);
    expect(useUpdatesStore.getState().pendingFollows).toEqual([]);
  });

  it("refuses a second place in the settling scope, and takes another", async () => {
    const write = pending<{ status: "ok"; data: typeof auditView }>();
    vi.mocked(commands.packageSetRev).mockReturnValue(write.promise as never);
    mount(<Live />);
    await act(async () => {
      switches()[0].click();
    });

    // The apply behind the first flip can move what is installed in its
    // scope, so a second hold captured there would pin a commit about to
    // go stale. Another scope's is untouched by it.
    await act(async () => {
      void useUpdatesStore.getState().setAutoUpdate(rows[1], false);
      void useUpdatesStore.getState().setAutoUpdate(rows[2], false);
    });

    expect(following(1)).toBe(true);
    expect(following(2)).toBe(false);
    expect(
      useUpdatesStore.getState().pendingFollows.map((one) => one.name),
    ).toEqual(["gh", "orch"]);

    write.answer({ status: "ok", data: auditView });
    await settle();
  });
});
