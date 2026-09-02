// @vitest-environment jsdom
// The page's wiring: which place it reads for, which place its refusal
// names, and what it sends an install. Its tree reads the store through the
// destination picker, and a store read that answers with a fresh value each
// time re-renders the tree until React throws — so the first case mounts
// with the settings read unlanded, the state the app first draws it in.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings, Scope } from "@/bindings";
import { commands, type PackageView } from "@/bindings";
import { unreadableRecordsLine } from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { AvailablePackagePage } from "./available-package";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacePackagePreview: vi.fn(),
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

const view: PackageView = {
  preview: {
    kind: "skill",
    name: "gh",
    description: "works a pull request",
    tags: [],
    readme: "# gh",
    files: [{ path: "SKILL.md", size: 10, isReadme: true }],
    bundles: [],
    dependencies: { required: [], optional: [] },
    state: "available",
    collision: null,
  },
  safety: {
    kind: "skill",
    name: "gh",
    findings: [],
    safety: { score: 100, deductions: [] },
    quality: null,
    skipped: [],
    notes: [],
    contentHash: "abc",
    ruleset: 1,
    fromCache: false,
  },
};

/** The store action the Install button lands on. */
const installed = vi.fn(async () => true);

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
    status: "ok",
    data: view,
  });
  vi.mocked(commands.installTargets).mockResolvedValue({
    status: "ok",
    data: [{ harness: "claude", detected: true, sharesTheUniversalTree: true }],
  });
  useMarketplacesStore.setState({
    rows: [],
    packages: {},
    summaries: {},
    readErrors: {},
    busy: false,
    install: installed,
  });
  useSettingsStore.setState({
    settings: { projects: [ACME.root] } as AppSettings,
  });
  useNavStore.setState({
    availableRef: { kind: "skill", name: "gh", catalog },
  });
});

/** The header's Install, whatever it currently reads. */
function installButton(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install",
  );
}

describe("the available package page", () => {
  it("settles on mount before the settings read has landed", async () => {
    // The state the app first draws this page in: no place registry yet, so
    // the picker has only the personal scope to offer. Every other case
    // here needs a project to pick, which is why the fixture lands one.
    useSettingsStore.setState({ settings: null });
    const host = mount(<AvailablePackagePage />);
    await settle();

    expect(commands.marketplacePackagePreview).toHaveBeenCalledWith(
      catalog,
      "skill",
      "gh",
      null,
    );
    // The destination picker is on screen, so the snapshot whose caching
    // this proves was really read.
    expect(host.textContent).toContain("Install to");
    expect(host.textContent).toContain("works a pull request");
  });

  // The engine answers Unknown for the place the install would land in, so
  // the page has that place's answer and no reason to keep a button the
  // engine would refuse on the same record.
  it("withholds Install and says why when the landing place's records went unread", async () => {
    const host = mount(<AvailablePackagePage />);
    await settle();
    // The control: a readable record leaves the button alone, so what
    // follows is the state doing the withholding and not the page.
    expect(installButton(host)?.disabled).toBe(false);

    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "ok",
      data: { ...view, preview: { ...view.preview, state: "unknown" } },
    });
    useNavStore.setState({
      availableRef: { kind: "skill", name: "gh2", catalog },
    });
    await settle();

    expect(installButton(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("Personal"));
    expect(host.textContent).toContain("See Problems");
  });

  // The read carries the destination, and so does the reason: the record
  // that could not be read is the chosen project's, so naming the scope
  // being browsed would send the reader to the wrong place's Problems.
  it("re-reads for a chosen project and names that place in the reason", async () => {
    const host = mount(<AvailablePackagePage />);
    await settle();

    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "ok",
      data: { ...view, preview: { ...view.preview, state: "unknown" } },
    });
    await chooseDestination(host, "acme");

    expect(commands.marketplacePackagePreview).toHaveBeenLastCalledWith(
      catalog,
      "skill",
      "gh",
      ACME,
    );
    expect(host.textContent).toContain(unreadableRecordsLine("acme"));
    expect(host.textContent).not.toContain(unreadableRecordsLine("Personal"));
  });

  // Picking the place already being browsed is not a redirect, and the
  // picker hands back a freshly built Scope, so identity would call it one:
  // the read would ask the engine to redirect into the place it is already
  // browsing, and the install would carry a destination it does not have.
  it("sends no destination once the picker comes back to the browsed place", async () => {
    const host = mount(<AvailablePackagePage />);
    await settle();
    await chooseDestination(host, "acme");
    await chooseDestination(host, "Personal");

    expect(commands.marketplacePackagePreview).toHaveBeenLastCalledWith(
      catalog,
      "skill",
      "gh",
      null,
    );

    const install = installButton(host);
    if (!install) throw new Error("no Install button rendered");
    await userEvent.click(install);
    await settle();

    expect(installed).toHaveBeenCalledWith(
      expect.objectContaining({ destination: null }),
    );
  });
});
