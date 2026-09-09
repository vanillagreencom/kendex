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
import {
  LOCAL_FOLDER_LABEL,
  unreadableRecordsLine,
} from "@/lib/copy-marketplaces";
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

/** What the preview read answers with. */
function answer(preview: PackageView["preview"]) {
  vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
    status: "ok",
    data: { ...view, preview },
  });
}

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

  // Everything the destination decides on this page, in one pass. The read
  // is asked again for the project; the record standing is that project's,
  // so Install withholds on it and the reason names it; and coming back to
  // the place being browsed is not a redirect, so neither the read nor the
  // install carries one.
  it("reads, gates and says why for the place the install would land in", async () => {
    const host = mount(<AvailablePackagePage />);
    await settle();
    // The control: a readable record leaves the button alone, so what
    // follows is the state doing the withholding and not the page.
    expect(installButton(host)?.disabled).toBe(false);

    answer({ ...view.preview, state: "unknown" });
    await chooseDestination(host, "acme");

    expect(commands.marketplacePackagePreview).toHaveBeenLastCalledWith(
      catalog,
      "skill",
      "gh",
      ACME,
    );
    expect(installButton(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("acme"));
    expect(host.textContent).not.toContain(unreadableRecordsLine("Personal"));
    expect(host.textContent).toContain("See Problems");

    answer(view.preview);
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
