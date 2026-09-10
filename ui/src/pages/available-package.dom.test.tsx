// @vitest-environment jsdom
// The page's wiring: which place it reads for, when it withholds the one
// action it has, and what that action hands the guided install. Where the
// package lands is no longer this page's question — the flow asks it — so
// what is proved here is that the page states the package and opens the
// flow on it.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings, Scope } from "@/bindings";
import { commands, type PackageView } from "@/bindings";
import { README_TAG } from "@/lib/copy";
import { PICK_A_FILE_NOTE } from "@/lib/copy-files";
import { INSTALL_ACTION, justThisLabel } from "@/lib/copy-install";
import {
  LOCAL_FOLDER_LABEL,
  unreadableRecordsLine,
} from "@/lib/copy-marketplaces";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { AvailablePackagePage } from "./available-package";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacePackagePreview: vi.fn(),
    marketplacePackageFile: vi.fn(),
    installTargets: vi.fn(),
    // The Bookmark control every marketplace surface now carries reads
    // the saved list once on mount.
    bookmarksList: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
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

const view: PackageView = {
  preview: {
    kind: "skill",
    name: "gh",
    description: "works a pull request",
    summary: "works a pull request",
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
    busy: false,
  });
  useSettingsStore.setState({
    settings: { projects: [ACME.root] } as AppSettings,
  });
  useNavStore.setState({
    availableRef: { kind: "skill", name: "gh", catalog },
    installInto: null,
  });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
});

/** What the preview read answers with. */
function answer(preview: PackageView["preview"]) {
  vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
    status: "ok",
    data: { ...view, preview },
  });
}

/** The header's Install. */
function installButton(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find(
    (button) => button.textContent === INSTALL_ACTION,
  );
}

describe("the available package page", () => {
  it("settles on mount before the settings read has landed", async () => {
    // The state the app first draws this page in: no place registry yet.
    useSettingsStore.setState({ settings: null });
    const host = mount(<AvailablePackagePage />);
    await settle();

    expect(commands.marketplacePackagePreview).toHaveBeenCalledWith(
      catalog,
      "skill",
      "gh",
      null,
    );
    expect(host.textContent).toContain("works a pull request");
  });

  // One button, and behind it the flow's own question. The page reads for
  // the place this package is offered in, and never asks for a
  // destination: nothing here knows one yet.
  it("opens the guided install on this package alone", async () => {
    const host = mount(<AvailablePackagePage />);
    await settle();

    const install = installButton(host);
    if (!install) throw new Error("no Install button rendered");
    expect(install.disabled).toBe(false);
    await userEvent.click(install);
    await settle();

    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects).toHaveLength(1);
    expect(ask?.subjects[0].label).toBe(justThisLabel("gh"));
    expect(ask?.subjects[0].groups).toEqual([
      {
        source: "kit",
        browsing: { scope: "global" },
        items: [{ kind: "skill", name: "gh" }],
        bundle: null,
      },
    ]);
  });

  // A place whose lock could not be read has no state to install against,
  // so the page says why in place of the action rather than opening a flow
  // that would be refused.
  it("withholds the action and names the place whose records could not be read", async () => {
    answer({ ...view.preview, state: "unknown" });
    const host = mount(<AvailablePackagePage />);
    await settle();

    expect(installButton(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("Personal"));
    expect(host.textContent).toContain("See Problems");
  });
});

// The From block names the marketplace the package comes from and where
// that marketplace is. Reading the declaration's own `path` put a bare `.`
// under the name for the working checkout kendex is developed in — the
// state `lib/marketplace-display.ts` exists to remove, and one the page
// header already reads as a resolved folder.
describe("where the available package says it comes from", () => {
  const CHECKOUT: Scope = { scope: "project", root: "/home/me/dev/kendex" };
  const folder = subscription(CHECKOUT, ".");

  it("resolves a folder subscription's location, never its relative spelling", async () => {
    useMarketplacesStore.setState({
      rows: [
        {
          scope: CHECKOUT,
          name: ".",
          repo: null,
          repoKey: null,
          repoIdentity: null,
          provenance: "/home/me/dev/kendex",
          path: ".",
          resolvedPath: "/home/me/dev/kendex",
          rev: null,
          commit: null,
          enabled: true,
          counts: null,
          meta: { name: "kendex" },
          mode: null,
          recordsUnreadable: false,
        },
      ],
    });
    useNavStore.setState({
      availableRef: { kind: "skill", name: "gh", catalog: folder },
    });
    const host = mount(<AvailablePackagePage />);
    await settle();

    const from = [...host.querySelectorAll("aside section")][0];
    expect(from?.textContent).toContain("kendex");
    expect(from?.textContent).toContain(
      `${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`,
    );
    // The relative spelling never reaches the screen on its own.
    expect(
      [...(from?.querySelectorAll("span") ?? [])].map((el) => el.textContent),
    ).not.toContain(".");
  });
});

// The files of a package nobody has installed yet read the way an
// installed package's do: the app's one tree, and the file it opens beside
// it. The aside carries the facts about the package and no longer a list
// of its files.
describe("the available package's files", () => {
  it("draws them as a tree and opens the one picked", async () => {
    answer({
      ...view.preview,
      files: [
        { path: "SKILL.md", size: 10, isReadme: true },
        { path: "references/deep.md", size: 20, isReadme: false },
      ],
    });
    vi.mocked(commands.marketplacePackageFile).mockResolvedValue({
      status: "ok",
      data: {
        path: "references/deep.md",
        content: "A-LINE-FROM-THE-CATALOG",
        truncated: false,
      },
    });
    const host = mount(<AvailablePackagePage />);
    await settle();

    // Nothing is picked yet, so the pane asks rather than guessing which
    // file the reader came for.
    expect(host.textContent).toContain(PICK_A_FILE_NOTE);
    const folder = [...host.querySelectorAll("button")].find(
      (one) => one.title === "references",
    );
    expect(folder).toBeDefined();

    // The readme is marked here the way it is on the installed package's
    // Files tab: without it, the file the preview opens on is a pane whose
    // source no row names.
    const rowFor = (path: string) =>
      [...host.querySelectorAll("button")].find((one) => one.title === path);
    expect(rowFor("SKILL.md")?.textContent).toContain(README_TAG);
    expect(rowFor("references/deep.md")?.textContent).not.toContain(README_TAG);

    const row = rowFor("references/deep.md");
    if (!row) throw new Error("no row for references/deep.md");
    await userEvent.click(row);
    await settle();
    expect(commands.marketplacePackageFile).toHaveBeenCalledWith(
      catalog,
      "skill",
      "gh",
      "references/deep.md",
    );
    expect(host.textContent).toContain("A-LINE-FROM-THE-CATALOG");
  });
});
