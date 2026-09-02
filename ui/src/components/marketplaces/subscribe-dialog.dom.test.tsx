// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  unreadableRecordsLine,
  unreadableRecordsWriteLine,
} from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";
import { SubscribeDialog } from "./subscribe-dialog";

vi.mock("@/bindings", () => ({
  commands: { scopeRecordsUnreadable: vi.fn() },
}));
vi.mock("@/stores/settings", () => ({
  useSettingsStore: (selector: (state: unknown) => unknown) =>
    selector({ settings: { projects: [ACME.root] } }),
}));

const ACME: Extract<Scope, { scope: "project" }> = {
  scope: "project",
  root: "/work/acme",
};

/** What the chosen place's record read answers. */
function records(unreadable: boolean) {
  vi.mocked(commands.scopeRecordsUnreadable).mockResolvedValue({
    status: "ok",
    data: unreadable,
  });
}

const REFUSAL = "already subscribed as 'kit'";

beforeEach(() => {
  vi.clearAllMocks();
  records(false);
  useMarketplacesStore.setState({
    error: null,
    busy: false,
    // What the real action does on a refusal: leave the words in the
    // shared slot for anything still reading it, and hand them back. The
    // stub has to do both, or the control below would redden because the
    // slot was never written rather than because a read cleared it.
    subscribe: async () => {
      useMarketplacesStore.setState({ error: REFUSAL });
      return { error: REFUSAL };
    },
    clearError: () => useMarketplacesStore.setState({ error: null }),
  });
});

// The refusal is the dialog's own. `load` writes error: null on every
// landing overview read, and reads overlap an open dialog, so rendering the
// shared slot meant one finishing under the dialog wiped the refusal off
// the screen — open, input intact, and no account of why nothing happened.
describe("a refused subscribe", () => {
  it("keeps its reason on screen when a concurrent read clears the store", async () => {
    mount(<SubscribeDialog open onOpenChange={() => {}} />);
    const input = document.querySelector<HTMLInputElement>(
      "#subscribe-reference",
    );
    if (!input) throw new Error("no reference input rendered");
    await userEvent.type(input, "Acme/Kit");
    const submit = [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Subscribe",
    );
    if (!submit) throw new Error("no submit button rendered");

    await userEvent.click(submit);
    await settle();
    expect(document.body.textContent).toContain(REFUSAL);

    // An overview read lands while the refusal is on screen.
    useMarketplacesStore.setState({ error: null });
    await settle();

    expect(document.body.textContent).toContain(REFUSAL);
  });
});

/** Subscribing plans against the chosen place's lock, so a record this
 * build can't read refuses the write. The dialog is where the place was
 * chosen, so it is where the reason belongs — rather than the engine's raw
 * LockCorrupt arriving after the press. */
describe("the place a subscription is chosen for", () => {
  /** The dialog with a reference already typed, ready to submit. */
  async function filled() {
    const host = mount(<SubscribeDialog open onOpenChange={() => {}} />);
    const input = host.ownerDocument.querySelector<HTMLInputElement>(
      "#subscribe-reference",
    );
    if (!input) throw new Error("no reference input rendered");
    await userEvent.type(input, "Acme/Kit");
    await settle();
    return [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Subscribe",
    );
  }

  // The control: a readable record leaves the button live, so the test
  // below is the record doing the withholding and not the input.
  it("offers the subscription where its records read", async () => {
    expect((await filled())?.disabled).toBe(false);
    expect(document.body.textContent).not.toContain("See Problems");
  });

  it("takes no subscription and says why where they do not", async () => {
    records(true);

    expect((await filled())?.disabled).toBe(true);
    expect(document.body.textContent).toContain(
      unreadableRecordsWriteLine("Personal"),
    );
    // Both halves: the line this surface draws, and the one it must not.
    expect(document.body.textContent).not.toContain(
      unreadableRecordsLine("Personal"),
    );
    expect(document.body.textContent).toContain("See Problems");
  });

  // The answer belongs to the place, so the question follows the picker.
  it("asks again for the place the picker moves to", async () => {
    const submit = await filled();
    expect(commands.scopeRecordsUnreadable).toHaveBeenLastCalledWith({
      scope: "global",
    });
    expect(submit?.disabled).toBe(false);

    records(true);
    const trigger = document.querySelector<HTMLElement>(
      '[data-slot="select-trigger"]',
    );
    if (!trigger) throw new Error("no place select rendered");
    act(() => trigger.focus());
    await userEvent.keyboard("{Enter}");
    const option = [...document.querySelectorAll('[role="option"]')].find(
      (el) => el.textContent === "acme",
    );
    if (!(option instanceof HTMLElement)) throw new Error("no acme option");
    await userEvent.click(option);
    await settle();

    expect(commands.scopeRecordsUnreadable).toHaveBeenLastCalledWith(ACME);
    expect(document.body.textContent).toContain(
      unreadableRecordsWriteLine("acme"),
    );
  });

  // Withheld while the read is still out: pressing into the gap would be
  // pressing before the place had answered.
  it("offers nothing while the read is still out", async () => {
    vi.mocked(commands.scopeRecordsUnreadable).mockReturnValue(
      new Promise(() => {}),
    );
    const host = mount(<SubscribeDialog open onOpenChange={() => {}} />);
    const input = host.ownerDocument.querySelector<HTMLInputElement>(
      "#subscribe-reference",
    );
    if (!input) throw new Error("no reference input rendered");
    await userEvent.type(input, "Acme/Kit");

    const submit = [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Subscribe",
    );
    expect(submit?.disabled).toBe(true);
  });

  // A local read that fails leaves Subscribe live on purpose: the engine
  // refuses the write itself with its own words, and failing closed here
  // would put the button out of reach for good whenever the read errors.
  it("still offers the subscription when the read itself fails", async () => {
    vi.mocked(commands.scopeRecordsUnreadable).mockResolvedValue({
      status: "error",
      error: "no such place",
    });

    expect((await filled())?.disabled).toBe(false);
    expect(document.body.textContent).not.toContain("See Problems");
  });
});
