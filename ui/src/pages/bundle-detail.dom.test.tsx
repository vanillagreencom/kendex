// @vitest-environment jsdom
// The set page's read is wiring, not a prop: it has to ask for the set
// against the place the install would land in, and gate Install all on what
// that place's record says. A prop-driven test of the member rows cannot
// see either.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings, BundleDetail, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { unreadableRecordsLine } from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { BundleDetailPage } from "./bundle-detail";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceBundle: vi.fn(),
    installTargets: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const catalog = subscription({ scope: "global" }, "kit");
const ACME: Extract<Scope, { scope: "project" }> = {
  scope: "project",
  root: "/work/acme",
};

/** Pick a place in the destination select. A pointer click does not open a
 *  base-ui trigger under jsdom, so the keyboard path opens it. */
async function chooseDestination(host: HTMLElement, label: string) {
  const trigger = [...host.querySelectorAll("button")].find((button) =>
    button.textContent?.includes("Install to"),
  );
  if (!trigger) throw new Error("no destination select rendered");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  const option = [...document.querySelectorAll('[role="option"]')].find(
    (el) => el.textContent === label,
  );
  if (!(option instanceof HTMLElement)) throw new Error(`no ${label} option`);
  await userEvent.click(option);
  await settle();
}

const starter: BundleDetail = {
  name: "starter",
  description: "the six things to begin with",
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state: "available" }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable: false,
};

/** Install all, whatever it currently reads. */
function installAll(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install all",
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
  useNavStore.setState({ bundleRef: { bundle: "starter", catalog } });
});

describe("the curated set page", () => {
  // Everything the destination decides on this page, in one pass. The read
  // is asked again for the project and served from that project's own slot
  // when it comes back to one already read; a tick made against the place
  // before it is not carried into the new one; the record standing is that
  // project's, so Install all withholds on it and the reason names it.
  it("reads, gates and says why for the place the install would land in", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    expect(commands.marketplaceBundle).toHaveBeenCalledWith(
      catalog,
      "starter",
      null,
    );
    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();
    // The control: a readable record leaves the buttons alone, so what
    // follows is the record doing the withholding and not the page.
    expect(host.textContent).toContain("Install 1 selected");
    expect(installAll(host)?.disabled).toBe(false);
    expect(host.textContent).not.toContain("See Problems");

    answer({ ...starter, recordsUnreadable: true, members: [] });
    await chooseDestination(host, "acme");

    expect(commands.marketplaceBundle).toHaveBeenLastCalledWith(
      catalog,
      "starter",
      ACME,
    );
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);
    expect(host.textContent).toContain("Install 0 selected");
    expect(installAll(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("acme"));
    expect(host.textContent).not.toContain(unreadableRecordsLine("Personal"));

    // Back to the place being browsed, which is not a redirect, and out to
    // the project again: both answers are already in slots of their own.
    await chooseDestination(host, "Personal");
    await chooseDestination(host, "acme");
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);
  });

  // A destination whose read fails is the one state the picker has to
  // outlive: it is the only way to another place, and a page that hid it
  // would strand the reader on the error with nothing to press.
  it("can be switched away from a destination whose read failed", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();

    vi.mocked(commands.marketplaceBundle).mockResolvedValue({
      status: "error",
      error: "no manifest there",
    });
    await chooseDestination(host, "acme");
    expect(host.textContent).toContain("no manifest there");
    expect(host.textContent).toContain("Install to");

    await chooseDestination(host, "Personal");
    expect(host.textContent).not.toContain("no manifest there");
    expect(host.textContent).toContain("the six things to begin with");
  });
});
