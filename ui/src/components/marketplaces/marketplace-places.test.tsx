// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { SWITCHED_OFF_HERE } from "@/lib/copy-model";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
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

const goToLibrary = vi.fn();
const toggle = vi.fn();

beforeEach(() => {
  goToLibrary.mockReset();
  toggle.mockReset();
  useMarketplacesStore.setState({ rows: [], toggle });
  useNavStore.setState({ goToLibrary });
});

// The tab is a list of places to open, not a set of switches: what a place
// does with a marketplace is that place's own setting. Static markup never
// reaches the handler, so this mounts.
describe("a marketplace's Projects section", () => {
  it("opens the place a row names and offers no control over it", async () => {
    useMarketplacesStore.setState({
      rows: [row(), row({ scope: project("/w/beta"), name: "beta-kit" })],
    });
    const host = mount(<MarketplacePlaces identity="github.com/acme/kit" />);

    // No switch, and nothing else that would change a place from here:
    // the only controls are the two rows themselves.
    expect(host.querySelectorAll('[role="switch"]').length).toBe(0);
    const rows = [...host.querySelectorAll("button")] as HTMLElement[];
    expect(rows.length).toBe(2);

    await userEvent.click(rows[1]);
    expect(toggle).not.toHaveBeenCalled();
    expect(goToLibrary).toHaveBeenCalledTimes(1);
    expect(goToLibrary).toHaveBeenCalledWith({ scope: { project: "/w/beta" } });
  });

  it("opens Personal as the personal narrowing", async () => {
    useMarketplacesStore.setState({ rows: [row()] });
    const host = mount(<MarketplacePlaces identity="github.com/acme/kit" />);

    await userEvent.click(host.querySelector("button") as HTMLElement);
    expect(goToLibrary).toHaveBeenCalledWith({ scope: "global" });
  });

  // A place offering none of this marketplace's packages otherwise reads as
  // a place with nothing installed. The state is said; changing it is the
  // place's own setting.
  it("says which places have it switched off", () => {
    useMarketplacesStore.setState({
      rows: [
        row(),
        row({ scope: project("/w/beta"), name: "beta-kit", enabled: false }),
      ],
    });
    const host = mount(<MarketplacePlaces identity="github.com/acme/kit" />);

    const said = [...host.querySelectorAll("button")].map((each) =>
      each.textContent?.includes(SWITCHED_OFF_HERE),
    );
    expect(said).toEqual([false, true]);
  });

  // Two registered projects can end in the same folder. A row labelled
  // "kendex" beside another labelled "kendex" names neither, over a link
  // that opens one of them — the rule that a list never carries a control
  // whose target it does not name, failing on the name itself.
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
