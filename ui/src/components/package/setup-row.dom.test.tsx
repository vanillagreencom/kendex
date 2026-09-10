// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { PackageSetup, SetupState } from "@/bindings";
import {
  ACTIVATE_LABEL,
  CHECK_AGAIN_LABEL,
  REPAIR_LABEL,
  SETUP_ACTIVE,
  SETUP_CHECKING,
  SETUP_COULD_NOT_CHECK,
  SETUP_NEEDS_REPAIR,
  SETUP_NOT_ACTIVE,
  SETUP_SHARED_NOTE,
  SETUP_UNAVAILABLE,
} from "@/lib/copy-setup";
import { mount } from "@/test/dom";
import { SetupRow, type SetupShown, shownState } from "./setup-row";

const setup = (
  state: SetupState,
  over: Partial<PackageSetup["status"]> = {},
): PackageSetup => ({
  status: {
    state,
    said: ["the package spoke"],
    canApply: true,
    canCheck: true,
    shared: true,
    ...over,
  },
  disclosure: {
    declared: {
      name: "commit-guards",
      root: "/work/vg/.agents/skills/commit-guards",
      summary: "Arms git hooks.",
      writes: [],
      installer: "scripts/install-git-hooks",
      uninstaller: null,
      checker: null,
      removal: null,
      notes: [],
      companions: [],
    },
    name: "commit-guards",
    summary: "Arms git hooks.",
    writes: [],
    companions: [],
    notes: [],
    undo: null,
  },
});

const buttons = (host: HTMLElement) =>
  Array.from(host.querySelectorAll("button")).map((one) => one.textContent);

const draw = (
  state: SetupShown,
  answer: PackageSetup | null,
  onActivate = vi.fn(),
  onCheckAgain = vi.fn(),
) =>
  mount(
    <SetupRow
      place="vg"
      setup={answer}
      state={state}
      busy={false}
      onActivate={onActivate}
      onRepair={onActivate}
      onCheckAgain={onCheckAgain}
    />,
  );

/** Every state a project's setup row can be in, what it is called, and
 *  which controls it offers. One row per state, because the pair is the
 *  whole claim: a state that offers the wrong control is a button the
 *  engine refuses, and a control offered under no state is one nobody can
 *  reach.
 */
describe("a project's setup row", () => {
  const rows: [string, SetupShown, PackageSetup | null, string, string[]][] = [
    ["a read still out", "checking", null, SETUP_CHECKING, []],
    [
      "the effect in force",
      "active",
      setup("active"),
      SETUP_ACTIVE,
      [CHECK_AGAIN_LABEL],
    ],
    [
      "nothing set up here",
      "notActive",
      setup("notActive", { said: [] }),
      SETUP_NOT_ACTIVE,
      [ACTIVATE_LABEL, CHECK_AGAIN_LABEL],
    ],
    [
      "set up here and broken since",
      "needsRepair",
      setup("needsRepair"),
      SETUP_NEEDS_REPAIR,
      [REPAIR_LABEL, CHECK_AGAIN_LABEL],
    ],
    [
      "a state nobody could read",
      "couldNotCheck",
      setup("couldNotCheck"),
      SETUP_COULD_NOT_CHECK,
      [CHECK_AGAIN_LABEL],
    ],
    [
      "a declared effect with no check",
      "unavailable",
      setup("unavailable", { canCheck: false, said: [] }),
      SETUP_UNAVAILABLE,
      [ACTIVATE_LABEL],
    ],
  ];
  it.each(rows)("%s reads %s", (_what, state, answer, label, controls) => {
    const host = draw(state, answer);
    expect(host.textContent).toContain(label);
    expect(buttons(host)).toEqual(controls);
  });

  it("prints what the check itself said, whatever the verdict was", () => {
    const host = draw("needsRepair", setup("needsRepair"));
    expect(host.textContent).toContain("the package spoke");
  });

  it("says why the check has not been run before offering to run it", () => {
    const host = draw("notActive", setup("notActive", { said: [] }));
    expect(host.textContent).toContain("Check again asks the package");
  });

  it("says a shared repository is shared beside the control that changes it", () => {
    // Beside a Set up, and nowhere else: on a settled row it is a fact
    // nobody is about to act on.
    expect(
      draw("notActive", setup("notActive", { said: [] })).textContent,
    ).toContain(SETUP_SHARED_NOTE);
    expect(draw("active", setup("active")).textContent).not.toContain(
      SETUP_SHARED_NOTE,
    );
    expect(
      draw("notActive", setup("notActive", { said: [], shared: false }))
        .textContent,
    ).not.toContain(SETUP_SHARED_NOTE);
  });

  it("offers no way to run a package that declares nothing to run", () => {
    const host = draw(
      "notActive",
      setup("notActive", { canApply: false, said: [] }),
    );
    expect(buttons(host)).toEqual([CHECK_AGAIN_LABEL]);
  });

  it("runs the setup and the check from their own buttons", async () => {
    const onActivate = vi.fn();
    const onCheckAgain = vi.fn();
    const host = draw(
      "notActive",
      setup("notActive", { said: [] }),
      onActivate,
      onCheckAgain,
    );
    const found = Array.from(host.querySelectorAll("button"));
    await userEvent.click(found[0] as HTMLButtonElement);
    await userEvent.click(found[1] as HTMLButtonElement);
    expect(onActivate).toHaveBeenCalledTimes(1);
    expect(onCheckAgain).toHaveBeenCalledTimes(1);
  });
});

/** What a store entry means on screen. A read that has not answered and a
 *  read that failed are different states, and folding either into an
 *  inactive one states a repository nobody measured. */
describe("the state a row draws from its place's entry", () => {
  const rows: [string, Parameters<typeof shownState>[0], SetupShown][] = [
    ["no entry yet", undefined, "checking"],
    ["a read that is out", { setup: null, reading: true }, "checking"],
    ["a read that failed", { setup: null, reading: false }, "couldNotCheck"],
    ["an answer", { setup: setup("active"), reading: false }, "active"],
    [
      "a re-read over a landed answer",
      { setup: setup("active"), reading: true },
      "checking",
    ],
  ];
  it.each(rows)("%s is %s", (_what, entry, state) => {
    expect(shownState(entry)).toBe(state);
  });
});
