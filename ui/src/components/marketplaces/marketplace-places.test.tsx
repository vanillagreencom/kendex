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

    expect(host.textContent).toContain(SOURCE_ENABLED_LABEL);
    const switches = [
      ...host.querySelectorAll('[role="switch"]'),
    ] as HTMLElement[];
    await userEvent.click(switches[1]);

    expect(toggle).toHaveBeenCalledTimes(1);
    expect(toggle).toHaveBeenCalledWith(project("/w/beta"), "beta-kit", false);
  });
});
