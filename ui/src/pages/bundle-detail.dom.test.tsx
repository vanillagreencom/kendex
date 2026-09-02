// @vitest-environment jsdom
// The set page's read is wiring, not a prop: it has to ask for the set
// against the place the install would land in, and gate Install all on what
// that place's record says. A prop-driven test of the member rows cannot
// see either.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BundleDetail } from "@/bindings";
import { commands } from "@/bindings";
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
  useSettingsStore.setState({ settings: null });
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
    expect(host.textContent).toContain("can't read Personal's records");
    expect(host.textContent).toContain("See Problems");
  });
});
