// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";
import { SubscribeDialog } from "./subscribe-dialog";

vi.mock("@/stores/settings", () => ({
  useSettingsStore: (selector: (state: unknown) => unknown) =>
    selector({ settings: { projects: [] } }),
}));

const REFUSAL = "already subscribed as 'kit'";

beforeEach(() => {
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
