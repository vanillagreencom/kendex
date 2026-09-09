// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  placeMarketplacesEmpty,
  placeMarketplacesReading,
  placeMarketplacesUnchecked,
  placeMarketplacesUnconfirmed,
  SWITCHED_OFF_HERE,
  TURN_OFF_CONFIRM,
  turnOffBody,
  turnOffLabel,
  turnOnLabel,
} from "@/lib/copy-model";
import { READ_LANDED, READ_PENDING, readFailed } from "@/lib/read-state";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";
import { PlaceMarketplacesDialog } from "./place-marketplaces-dialog";

const beta: Scope = { scope: "project", root: "/w/beta" };

const row = (over: Partial<MarketplaceRow> = {}): MarketplaceRow => ({
  scope: beta,
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: "Acme/Kit",
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
  ...over,
});

const toggle = vi.fn();
const load = vi.fn(async () => {});

beforeEach(() => {
  toggle.mockReset();
  load.mockClear();
  useMarketplacesStore.setState({ rows: [], toggle, load, read: READ_LANDED });
});

/** Open the row's menu — a base-ui trigger needs focus and Enter under
 *  jsdom — and click the item whose text starts with `label`. */
const choose = async (label: string) => {
  const trigger = [...document.querySelectorAll("button")].find((one) =>
    one.getAttribute("aria-label")?.startsWith("More actions"),
  );
  if (!trigger) throw new Error("no actions trigger");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  const item = [...document.querySelectorAll('[role="menuitem"]')].find((el) =>
    el.textContent?.includes(label),
  );
  if (!(item instanceof HTMLElement)) throw new Error(`no item "${label}"`);
  await userEvent.click(item);
};

const open = async () => {
  mount(
    <PlaceMarketplacesDialog
      open
      onOpenChange={() => {}}
      scope={beta}
      place="beta"
    />,
  );
  await settle();
};

// The one place a marketplace is switched off or dropped for a project:
// both decide what that project installs, and both are read and made here,
// against the one place the title names.
describe("a place's marketplaces", () => {
  it("lists only the marketplaces this place installs from", async () => {
    useMarketplacesStore.setState({
      rows: [
        row(),
        row({ scope: { scope: "global" }, name: "personal-kit" }),
        row({ scope: { scope: "project", root: "/w/other" }, name: "other" }),
      ],
    });
    await open();

    const named = [...document.querySelectorAll("p")]
      .map((each) => each.textContent ?? "")
      .filter((text) => text.endsWith("kit") || text === "other");
    expect(named).toEqual(["kit"]);
  });

  it("asks before switching one off, and says what that costs", async () => {
    useMarketplacesStore.setState({ rows: [row()] });
    await open();

    await choose(turnOffLabel("kit"));
    expect(toggle).not.toHaveBeenCalled();
    expect(document.body.textContent).toContain(turnOffBody("kit", "beta"));

    const confirm = [...document.querySelectorAll("button")].find(
      (one) => one.textContent === TURN_OFF_CONFIRM,
    );
    if (!confirm) throw new Error("no confirm");
    await userEvent.click(confirm);
    expect(toggle).toHaveBeenCalledTimes(1);
    expect(toggle).toHaveBeenCalledWith(beta, "kit", false);
  });

  // Turning it back on restores what was there, so it does not ask.
  it("switches one back on without asking, and says it is off", async () => {
    useMarketplacesStore.setState({ rows: [row({ enabled: false })] });
    await open();
    expect(document.body.textContent).toContain(SWITCHED_OFF_HERE);

    await choose(turnOnLabel("kit"));
    expect(toggle).toHaveBeenCalledTimes(1);
    expect(toggle).toHaveBeenCalledWith(beta, "kit", true);
  });

  // Projects does not read marketplaces for its cards, so an empty list is
  // only ever the answer to a read this dialog asked for.
  it("reads the marketplaces when it opens, and says so when there are none", async () => {
    await open();
    expect(load).toHaveBeenCalledTimes(1);
    expect(document.body.textContent).toContain(placeMarketplacesEmpty("beta"));
  });

  // Nothing else in the app reads marketplaces first, so a session that opens
  // Projects before a marketplace page reaches this dialog with no rows and
  // no answer. Saying the place installs from nothing there denies it every
  // marketplace it has, on the one surface that switches one off.
  it("says nothing definite before the read has answered", async () => {
    useMarketplacesStore.setState({ read: READ_PENDING });
    await open();
    expect(document.body.textContent).toContain(
      placeMarketplacesReading("beta"),
    );
    expect(document.body.textContent).not.toContain(
      placeMarketplacesEmpty("beta"),
    );
  });

  it("shows a failed read with its reason and a way to retry", async () => {
    useMarketplacesStore.setState({
      read: readFailed("engine is not running"),
    });
    await open();
    expect(document.body.textContent).toContain(
      placeMarketplacesUnchecked("beta"),
    );
    expect(document.body.textContent).not.toContain(
      placeMarketplacesEmpty("beta"),
    );
    expect(document.body.textContent).toContain("engine is not running");

    load.mockClear();
    const retry = [...document.querySelectorAll("button")].find(
      (one) => one.textContent === TRY_AGAIN_LABEL,
    );
    if (!retry) throw new Error("no retry");
    await userEvent.click(retry);
    expect(load).toHaveBeenCalledTimes(1);
  });

  // Rows kept from before a failed read are drawn — they are the only answer
  // there is — but headed as last-known rather than as what stands now.
  it("heads rows kept from before a failed read as unconfirmed", async () => {
    useMarketplacesStore.setState({
      rows: [row()],
      read: readFailed("engine is not running"),
    });
    await open();
    expect(document.body.textContent).toContain(
      placeMarketplacesUnconfirmed("beta"),
    );
    expect(document.body.textContent).toContain("kit");
  });
});
