// @vitest-environment jsdom
// The page mounts and settles with the settings read unlanded, which is the
// state the app first draws it in. Its tree reads the store through the
// destination picker, and a store read that answers with a fresh value each
// time re-renders the tree until React throws.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type PackageView } from "@/bindings";
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
  });
  // Not yet read — the state the page is first drawn in.
  useSettingsStore.setState({ settings: null });
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
    expect(host.textContent).toContain("can't read Personal's records");
    expect(host.textContent).toContain("See Problems");
  });
});
