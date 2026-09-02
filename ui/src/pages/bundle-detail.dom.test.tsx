// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import type { BundleDetail, InstallState } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
} from "@/lib/copy-marketplaces";
import {
  bundleKey,
  subscription,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount } from "@/test/dom";
import { BundleDetailPage } from "./bundle-detail";

// The picker reads what the destination can take; nothing here turns on
// the answer, and no backend is behind it.
vi.mock("@/bindings", () => ({
  commands: { installTargets: async () => ({ status: "error", error: "no" }) },
}));

const catalog = subscription({ scope: "global" }, "kit");
const detail = (
  state: InstallState,
  recordsUnreadable = state === "unknown",
): BundleDetail => ({
  name: "starter",
  description: null,
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable,
});

const render = (set: BundleDetail) => {
  useMarketplacesStore.setState({
    bundles: { [bundleKey(catalog, "starter")]: set },
    readErrors: {},
    summaries: {},
    busy: false,
    loadBundle: async () => {},
  });
  useNavStore.setState({ bundleRef: { catalog, bundle: "starter" } });
  // The destination picker reads the registered projects; with no settings
  // loaded it would re-render on a fresh empty list every pass.
  useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
  return mount(<BundleDetailPage />);
};

const installAll = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install all",
  );

// Every per-member box is already off where the records could not be read,
// but "Install all" asks about the set and never consulted a member — it
// went straight to the engine, which refuses on the same record.
describe("a set whose project records could not be read", () => {
  it("does not offer to install the whole set", () => {
    expect(installAll(render(detail("unknown")))?.disabled).toBe(true);
    expect(installAll(render(detail("available")))?.disabled).toBe(false);
  });

  it("says why, and the way to the page that carries the reason", () => {
    const html = render(detail("unknown")).innerHTML;
    expect(html).toContain(unreadableRecordsLine("Personal"));
    expect(html).toContain(SEE_PROBLEMS_LABEL);
  });

  it("says nothing of the sort where the records read", () => {
    expect(render(detail("available")).innerHTML).not.toContain(
      unreadableRecordsLine("Personal"),
    );
  });

  // A rename or removal upstream leaves every row answering "no longer
  // offered" — the answer a dropped member gives with or without a lock. A
  // page scanning the rows for the scope's record reads that as readable
  // and hands back an Install all the engine refuses.
  it("holds where the catalog has dropped every member", () => {
    const host = render(detail("not-offered", true));
    expect(installAll(host)?.disabled).toBe(true);
    expect(host.innerHTML).toContain(unreadableRecordsLine("Personal"));
  });

  // The same hole with no rows at all to scan: a set may be declared with
  // an empty member list.
  it("holds where the set names no members at all", () => {
    const empty = detail("available", true);
    const host = render({ ...empty, members: [], totalMembers: 0 });
    expect(installAll(host)?.disabled).toBe(true);
    expect(host.innerHTML).toContain(unreadableRecordsLine("Personal"));
  });
});
