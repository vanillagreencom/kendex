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
  it("asks for the set against the place the install would land in", async () => {
    mount(<BundleDetailPage />);
    await settle();

    // Browsed and installed in the same place, so no redirect — the read
    // carries the destination all the same, which is the argument a
    // redirect fills.
    expect(commands.marketplaceBundle).toHaveBeenCalledWith(
      catalog,
      "starter",
      null,
    );
  });

  // The engine answers for the place the install lands in, so the page has
  // that place's record standing and no reason to keep a button the engine
  // would refuse on the same record.
  it("withholds Install all and says why when that place's records went unread", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    // The control: a readable record leaves the button alone, so what
    // follows is the record doing the withholding and not the page.
    expect(installAll(host)?.disabled).toBe(false);
    expect(host.textContent).not.toContain("See Problems");

    answer({ ...starter, recordsUnreadable: true, members: [] });
    useNavStore.setState({ bundleRef: { bundle: "other", catalog } });
    await settle();

    expect(installAll(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("Personal"));
    expect(host.textContent).toContain("See Problems");
  });

  // Everything the destination decides, in one pass: the read is asked
  // again for the project, a tick made against the place before it is not
  // carried into the new one, and the reason names the place the install
  // would land in rather than the one being browsed.
  it("re-reads for a chosen project, drops the tick, and names that place", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();
    expect(host.textContent).toContain("Install 1 selected");

    answer({ ...starter, recordsUnreadable: true, members: [] });
    await chooseDestination(host, "acme");

    expect(commands.marketplaceBundle).toHaveBeenLastCalledWith(
      catalog,
      "starter",
      ACME,
    );
    expect(host.textContent).toContain("Install 0 selected");
    expect(host.textContent).toContain(unreadableRecordsLine("acme"));
    expect(host.textContent).not.toContain(unreadableRecordsLine("Personal"));
  });

  // Two ways the same read gets asked twice for one answer: the picker
  // hands back a freshly built Scope, so the place already being browsed
  // reads as a redirect under object identity; and a place already read
  // has its answer in a slot of its own. Going out to a project and back
  // asks the engine once, for the project.
  it("asks once per place, and not at all for one already read", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(1);

    await chooseDestination(host, "acme");
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);

    await chooseDestination(host, "Personal");
    await chooseDestination(host, "acme");
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);
  });
});
