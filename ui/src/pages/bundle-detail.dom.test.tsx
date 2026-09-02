// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { describe, expect, it, vi } from "vitest";
import type { BundleDetail } from "@/bindings";
import {
  bundleKey,
  subscription,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount } from "@/test/dom";
import { BundleDetailPage } from "./bundle-detail";

// The picker reads what the destination can take; nothing here turns on the
// answer, and no backend is behind it.
vi.mock("@/bindings", () => ({
  commands: { installTargets: async () => ({ status: "error", error: "no" }) },
}));

const catalog = subscription({ scope: "global" }, "kit");
const key = bundleKey(catalog, "starter");

const set = (recordsUnreadable: boolean): BundleDetail => ({
  name: "starter",
  description: null,
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state: "available" }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable,
});

/** The page mounted over a cached set, with the refresh it issues on mount
 * left in flight — the window the stale detail renders in. `land` settles
 * that read with whatever the scope now answers. */
const render = (cached: BundleDetail) => {
  let settle: () => void = () => {};
  useMarketplacesStore.setState({
    bundles: { [key]: cached },
    readErrors: {},
    summaries: {},
    busy: false,
    loadBundle: () => new Promise<void>((resolve) => (settle = resolve)),
  });
  useNavStore.setState({ bundleRef: { catalog, bundle: "starter" } });
  // The destination picker reads the registered projects; with no settings
  // loaded it would re-render on a fresh empty list every pass.
  useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
  const host = mount(<BundleDetailPage />);
  const land = async (fresh: BundleDetail) => {
    await act(async () => {
      useMarketplacesStore.setState({ bundles: { [key]: fresh } });
      settle();
    });
  };
  return { host, land };
};

const installAll = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install all",
  );

const installSelected = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].find((button) =>
    button.textContent?.endsWith("selected"),
  );

// The cached detail is what renders while the mount read is out, so a set
// cached when the scope's lock read fine stays on screen after that record
// breaks. Acting on it reaches the engine, which refuses on the same record.
describe("a cached set while the scope's fresh answer is still out", () => {
  it("holds Install all until the read that would confirm it lands", async () => {
    const { host, land } = render(set(false));
    expect(installAll(host)?.disabled).toBe(true);

    await land(set(false));
    expect(installAll(host)?.disabled).toBe(false);
  });

  // A member ticked against the stale detail is a choice made against a
  // standing that no longer holds, and Install selected reads that set.
  it("drops a selection made in that window when the record turns out unreadable", async () => {
    const { host, land } = render(set(false));
    await land(set(false));
    await userEvent.click(host.querySelectorAll("label")[0] as HTMLElement);
    expect(installSelected(host)?.textContent).toBe("Install 1 selected");

    await act(async () => {
      useMarketplacesStore.setState({ bundles: { [key]: set(true) } });
    });
    expect(installAll(host)?.disabled).toBe(true);
    expect(installSelected(host)?.textContent).toBe("Install 0 selected");
    expect(installSelected(host)?.disabled).toBe(true);
  });
});
