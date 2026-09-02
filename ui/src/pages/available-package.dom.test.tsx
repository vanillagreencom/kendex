// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import type { InstallState, PackageView } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
} from "@/lib/copy-marketplaces";
import { subscription, useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { AvailablePackagePage } from "./available-package";

const stub = vi.hoisted(() => ({ state: "available" as InstallState }));

const view = (state: InstallState): PackageView => ({
  preview: {
    kind: "skill",
    name: "gh",
    description: null,
    tags: [],
    readme: null,
    files: [],
    bundles: [],
    state,
    collision: null,
  },
  safety: {
    safety: { score: 100, findings: [], skipped: [] },
    findings: [],
    skipped: [],
    notes: [],
  } as unknown as PackageView["safety"],
});

vi.mock("@/bindings", () => ({
  commands: {
    marketplacePackagePreview: async () => ({
      status: "ok",
      data: view(stub.state),
    }),
    // The picker reads what the destination can take; nothing here turns
    // on the answer, and no backend is behind it.
    installTargets: async () => ({ status: "error", error: "no" }),
  },
}));

const catalog = subscription({ scope: "global" }, "kit");

const render = async (state: InstallState) => {
  stub.state = state;
  useMarketplacesStore.setState({
    summaries: {},
    readErrors: {},
    rows: [],
    busy: false,
  });
  useNavStore.setState({
    availableRef: { catalog, kind: "skill", name: "gh" },
  });
  // The destination picker reads the registered projects; with no settings
  // loaded it would re-render on a fresh empty list every pass.
  useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
  const host = mount(<AvailablePackagePage />);
  await settle();
  return host;
};

const installButton = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install",
  );

// Every Packages row opens this page, "Not known" ones included. Install
// here reads the harness picker and nothing else, so it stayed live over a
// record the engine refuses on.
describe("a package page whose project records could not be read", () => {
  it("does not offer an install the engine would refuse", async () => {
    expect(installButton(await render("unknown"))?.disabled).toBe(true);
    expect(installButton(await render("available"))?.disabled).toBe(false);
  });

  it("says why, and the way to the page that carries the reason", async () => {
    const html = (await render("unknown")).innerHTML;
    expect(html).toContain(unreadableRecordsLine("Personal"));
    expect(html).toContain(SEE_PROBLEMS_LABEL);
  });

  it("says nothing of the sort where the records read", async () => {
    const html = (await render("available")).innerHTML;
    expect(html).not.toContain(unreadableRecordsLine("Personal"));
  });
});
