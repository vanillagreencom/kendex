// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { SOURCE_ENABLED_LABEL } from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount } from "@/test/dom";
import { MarketplacePlaces } from "./marketplace-places";

const project = (root: string): Scope => ({ scope: "project", root });

const row = (over: Partial<MarketplaceRow> = {}): MarketplaceRow => ({
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: "Acme/Kit",
  path: null,
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

beforeEach(() => {
  toggle.mockReset();
  useMarketplacesStore.setState({ rows: [], toggle });
});

// Where the per-place switch went, and what it does there. The switch used
// to sit on the Subscribed list, changing a place the list never named;
// here the place is the row, the label says what the switch does, and the
// click has to reach that row's own subscription. Static markup never
// reaches the handler, so this mounts.
describe("a marketplace's Projects section", () => {
  it("names what the switch does and switches the place it sits beside", async () => {
    useMarketplacesStore.setState({
      rows: [row(), row({ scope: project("/w/beta"), name: "beta-kit" })],
    });
    const host = mount(<MarketplacePlaces identity="github.com/acme/kit" />);

    // Each switch names its own place, so a reader moving control to
    // control is not offered three identical names over three different
    // subscriptions. The path, not the basename: two projects can end in
    // the same folder name.
    const named = [...host.querySelectorAll("label")].map(
      (label) => label.textContent ?? "",
    );
    expect(named[0]).toBe(`${SOURCE_ENABLED_LABEL} in Personal`);
    expect(named[1]).toBe(`${SOURCE_ENABLED_LABEL} in /w/beta`);

    const switches = [
      ...host.querySelectorAll('[role="switch"]'),
    ] as HTMLElement[];
    await userEvent.click(switches[1]);

    expect(toggle).toHaveBeenCalledTimes(1);
    expect(toggle).toHaveBeenCalledWith(project("/w/beta"), "beta-kit", false);
  });

  // Two registered projects can end in the same folder. A row labelled
  // "kendex" beside another labelled "kendex" names neither, over a switch
  // that deactivates every install this marketplace put in one of them —
  // the branch's own rule that a list never carries a control whose target
  // it does not name, failing on the name itself.
  it("tells apart two projects whose folders share a name", () => {
    useMarketplacesStore.setState({
      rows: [
        row({ scope: project("/w/dev/kendex"), name: "dev-kit" }),
        row({ scope: project("/w/work/kendex"), name: "work-kit" }),
      ],
    });
    const host = mount(<MarketplacePlaces identity="github.com/acme/kit" />);
    const named = [...host.querySelectorAll('[data-testid="place-name"]')].map(
      (el) => el.textContent ?? "",
    );

    expect(new Set(named).size).toBe(2);
    expect(named).toEqual(["/w/dev/kendex", "/w/work/kendex"]);
  });
});
