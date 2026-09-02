// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import {
  MARKETPLACE_PLACES_HELP,
  SOURCE_ENABLED_HELP,
  SOURCE_ENABLED_LABEL,
} from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount } from "@/test/dom";
import { MarketplacePlaces } from "./marketplace-places";

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
  ...over,
});

const toggle = vi.fn();

beforeEach(() => {
  toggle.mockReset();
  useMarketplacesStore.setState({ rows: [], toggle });
});

const draw = (identity = "github.com/acme/kit") =>
  mount(<MarketplacePlaces identity={identity} />);

/** The places on screen, by the name each row leads with. Read off a test
 * hook rather than off the paragraph's utility classes: a class reordered
 * on that paragraph would empty this list and redden the ordering test for
 * a reason that has nothing to do with ordering. */
const placesListed = (host: HTMLElement): string[] =>
  [...host.querySelectorAll('[data-testid="place-name"]')].map(
    (el) => el.textContent ?? "",
  );

describe("a marketplace's Projects section", () => {
  it("lists every place holding it, personal first", () => {
    useMarketplacesStore.setState({
      rows: [row({ scope: { scope: "project", root: "/w/beta" } }), row()],
    });
    const host = draw();
    expect(placesListed(host)).toEqual(["Personal", "beta"]);
    expect(host.textContent).toContain("/w/beta");
  });

  it("leaves out places holding a different marketplace", () => {
    useMarketplacesStore.setState({
      rows: [
        row(),
        row({
          scope: { scope: "project", root: "/w/beta" },
          name: "tools",
          repo: "Acme/Tools",
          repoKey: "acme/tools",
          repoIdentity: "github.com/acme/tools",
        }),
      ],
    });
    expect(draw().textContent).not.toContain("/w/beta");
  });

  // The section's switch and its Unsubscribe act on the row they are drawn
  // beside, so listing the wrong place hands a live control over another
  // marketplace's subscription — and "Remove them" uninstalls that
  // marketplace's packages. Two non-GitHub repositories sharing the alias
  // auto_alias derived for both is the way that happens.
  it("leaves out a place whose marketplace only shares this one's alias", () => {
    useMarketplacesStore.setState({
      rows: [
        row({
          repo: "https://gitlab.com/acme/kit",
          repoKey: null,
          repoIdentity: "https://gitlab.com/acme/kit",
        }),
        row({
          scope: { scope: "project", root: "/w/beta" },
          repo: "https://git.internal/tools/kit",
          repoKey: null,
          repoIdentity: "https://git.internal/tools/kit",
        }),
      ],
    });
    const host = draw("https://gitlab.com/acme/kit");
    expect(placesListed(host)).toEqual(["Personal"]);
    expect(host.textContent).not.toContain("/w/beta");
  });

  // The switch used to sit alone on the Subscribed list with nothing but
  // "Turn off" behind it: no place named, and no answer to what turning it
  // off does to what is already installed.
  it("names what the switch does and what switching it off costs", () => {
    useMarketplacesStore.setState({ rows: [row()] });
    const text = draw().textContent ?? "";
    expect(text).toContain(SOURCE_ENABLED_LABEL);
    expect(text).toContain(SOURCE_ENABLED_HELP);
    expect(text).toContain(MARKETPLACE_PLACES_HELP);
  });

  it("draws nothing at all for a marketplace no place declares", () => {
    expect(draw().innerHTML).toBe("");
  });
});

// The switch deactivates every install this marketplace put in that place,
// so which place it names and which way it sends the flag are the whole
// behaviour. Static markup never reaches the handler; this mounts it.
describe("switching a place's offer", () => {
  // base-ui draws the switch as a span carrying the role, with a hidden
  // checkbox beside it; the role is the control a person operates.
  const switches = (host: HTMLElement) =>
    [...host.querySelectorAll('[role="switch"]')] as HTMLElement[];

  const project = (root: string): Scope => ({ scope: "project", root });

  it("switches off the place it is drawn beside, not the first one", async () => {
    useMarketplacesStore.setState({
      rows: [row(), row({ scope: project("/w/beta"), name: "beta-kit" })],
    });
    const host = draw();

    await userEvent.click(switches(host)[1]);

    expect(toggle).toHaveBeenCalledTimes(1);
    expect(toggle).toHaveBeenCalledWith(project("/w/beta"), "beta-kit", false);
  });

  it("switches a place that is off back on", async () => {
    useMarketplacesStore.setState({ rows: [row({ enabled: false })] });
    const host = draw();

    await userEvent.click(switches(host)[0]);

    expect(toggle).toHaveBeenCalledWith({ scope: "global" }, "kit", true);
  });
});
