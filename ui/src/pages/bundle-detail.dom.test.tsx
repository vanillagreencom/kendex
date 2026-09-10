// @vitest-environment jsdom
// The set page's read is wiring, not a prop: it asks for the set against
// the place the set is offered in, gates its one action on what that
// place's record says, and hands the guided install both answers this page
// has to "what" — the whole set, and the members ticked. A prop-driven
// test of the member rows cannot see any of it.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings, BundleDetail, Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  INSTALL_ACTION,
  justThisLabel,
  selectedLabel,
  wholeSetLabel,
} from "@/lib/copy-install";
import { unreadableRecordsLine } from "@/lib/copy-marketplaces";
import { useInstallFlow } from "@/stores/install-flow";
import { bundleKey, useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { BundleDetailPage } from "./bundle-detail";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceBundle: vi.fn(),
    installTargets: vi.fn(),
    // The Bookmark control every marketplace surface now carries reads
    // the saved list once on mount.
    bookmarksList: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const HOME: Scope = { scope: "global" };
const catalog = subscription(HOME, "kit");
const ACME: Extract<Scope, { scope: "project" }> = {
  scope: "project",
  root: "/work/acme",
};

const starter: BundleDetail = {
  name: "starter",
  description: "the six things to begin with",
  version: null,
  category: null,
  members: [
    { kind: "skill", name: "gh", state: "available" },
    { kind: "skill", name: "lint", state: "available" },
  ],
  installedMembers: 0,
  totalMembers: 2,
  collision: null,
  recordsUnreadable: false,
};

/** The header's one action. */
function installButton(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find(
    (button) => button.textContent === INSTALL_ACTION,
  );
}

function answer(detail: BundleDetail) {
  vi.mocked(commands.marketplaceBundle).mockResolvedValue({
    status: "ok",
    data: detail,
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  answer(starter);
  vi.mocked(commands.installTargets).mockResolvedValue({
    status: "ok",
    data: [{ harness: "claude", detected: true, sharesTheUniversalTree: true }],
  });
  useMarketplacesStore.setState({ bundles: {}, readErrors: {}, busy: false });
  useSettingsStore.setState({
    settings: { projects: [ACME.root] } as AppSettings,
  });
  useNavStore.setState({
    bundleRef: { bundle: "starter", catalog },
    installInto: null,
  });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
});

describe("the curated set page", () => {
  // The read answers for the place the set is offered in, because that is
  // the only place this page knows: where the install lands is asked after
  // this page has said what the set holds.
  it("reads the set for the place it is offered in", async () => {
    mount(<BundleDetailPage />);
    await settle();

    expect(commands.marketplaceBundle).toHaveBeenCalledWith(
      catalog,
      "starter",
      null,
    );
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(1);
  });

  // One button, whatever is ticked. The whole set and the ticked members
  // are two answers inside the flow rather than two buttons of equal
  // weight in two corners of the page.
  it("offers the whole set and the ticked members as one question", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();

    await userEvent.click(installButton(host) as HTMLButtonElement);
    await settle();
    expect(
      useInstallFlow.getState().ask?.subjects.map((one) => one.label),
    ).toEqual([wholeSetLabel("starter")]);
    useInstallFlow.getState().close();

    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();
    await userEvent.click(installButton(host) as HTMLButtonElement);
    await settle();

    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects.map((one) => one.label)).toEqual([
      wholeSetLabel("starter"),
      selectedLabel(1),
    ]);
    // The set as a set, and the member as itself: a bundle install keeps
    // the set whole, so the two answers are not the same request.
    expect(ask?.subjects[0].groups[0].bundle).toBe("starter");
    expect(ask?.subjects[1].groups[0]).toEqual({
      source: "kit",
      browsing: HOME,
      items: [{ kind: "skill", name: "gh" }],
      bundle: null,
    });
  });

  // A landed install drops every set cache and the read comes back with
  // that member installed. A tick stored from before would leave a
  // disabled box checked and offer an already-installed member to the
  // next Install, so the tick is read against what the member is now.
  it("drops a tick on a member that came back installed", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();

    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();
    await userEvent.click(installButton(host) as HTMLButtonElement);
    await settle();
    expect(
      useInstallFlow.getState().ask?.subjects.map((one) => one.label),
    ).toContain(selectedLabel(1));
    useInstallFlow.getState().close();

    // The install landed, so the set cache dropped and the read came back
    // with that member installed — into the SAME mounted page, which is
    // where a tick stored from before would still be standing.
    act(() => {
      useMarketplacesStore.setState({
        bundles: {
          [bundleKey(catalog, "starter", null)]: {
            ...starter,
            members: [
              { kind: "skill", name: "gh", state: "installed" },
              { kind: "skill", name: "lint", state: "available" },
            ],
          },
        },
      });
    });
    await settle();

    const box2 = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    expect(box2?.checked).toBe(false);
    await userEvent.click(installButton(host) as HTMLButtonElement);
    await settle();
    expect(
      useInstallFlow.getState().ask?.subjects.map((one) => one.label),
    ).toEqual([wholeSetLabel("starter")]);
  });

  // A member's own action is the one-package case of the same flow, never
  // a second install path.
  it("opens the flow on one member from that member's own action", async () => {
    answer({
      ...starter,
      members: [{ kind: "skill", name: "gh", state: "removed-by-you" }],
    });
    const host = mount(<BundleDetailPage />);
    await settle();

    const restore = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Restore",
    );
    if (!restore) throw new Error("no member action rendered");
    await userEvent.click(restore);
    await settle();

    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects).toHaveLength(1);
    expect(ask?.subjects[0].label).toBe(justThisLabel("gh"));
  });

  // A place whose lock could not be read has no member standing to install
  // against, so the page says why in place of the action.
  it("withholds the action and names the place whose records could not be read", async () => {
    answer({ ...starter, recordsUnreadable: true, members: [] });
    const host = mount(<BundleDetailPage />);
    await settle();

    expect(installButton(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("Personal"));
  });

  // A read that fails leaves the page with its reason and no set, rather
  // than an empty one.
  it("says why the set could not be read", async () => {
    vi.mocked(commands.marketplaceBundle).mockResolvedValue({
      status: "error",
      error: "no manifest there",
    });
    const host = mount(<BundleDetailPage />);
    await settle();

    expect(host.textContent).toContain("no manifest there");
    expect(host.textContent).not.toContain("the six things to begin with");
  });
});
