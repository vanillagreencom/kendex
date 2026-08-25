// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Manifest_Serialize, ObservedItem, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  OPEN_IN_EDITOR_LABEL,
  OPEN_IN_FILE_BROWSER_LABEL,
  OPEN_IN_LABEL,
} from "@/lib/copy";
import { editorOpenPath } from "@/lib/editor-path";
import { SEVERITY_LABELS } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { PackagePage } from "./package";

// The page is mounted against the real stores; only the backend is
// stubbed. Each command the page or its children call on mount answers
// with nothing, except the manifest read, which answers per place.
vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    packageMeta: vi.fn(),
    packageFiles: vi.fn(),
    packageVersions: vi.fn(),
    packageReadme: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    revealPath: vi.fn(),
    openInEditor: vi.fn(),
    libraryProvenance: vi.fn(),
    // The page's safety block asks for a fresh audit as it mounts.
    auditAll: vi.fn(),
  },
}));

type Project = Extract<Scope, { scope: "project" }>;
const VG: Project = { scope: "project", root: "/work/vg" };
const HYPR: Project = { scope: "project", root: "/work/hyprtrade" };

const installedAt = (scope: Project): ObservedItem => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.root}/.claude/skills/gh`,
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
  modifiedAt: null,
  vendor: null,
});

const PLAIN: Manifest_Serialize = { schema: 1, install: {} };
const CUSTOMIZED: Manifest_Serialize = {
  schema: 1,
  install: {},
  "skill-instructions": { gh: "mine" },
};

const nothing = { status: "error" as const, error: "not in this test" };

/** Mount the page about `gh` at `here`, with the package installed in
 *  every place of `installed` and each place's manifest as given. */
const openPage = async (
  here: Project,
  installed: Project[],
  manifests: Record<string, Manifest_Serialize>,
) => {
  vi.mocked(commands.getManifest).mockImplementation((scope) =>
    Promise.resolve({
      status: "ok",
      data: { manifest: manifests[scopeKey(scope)] ?? null, base: null },
    }),
  );
  useScanStore.setState({
    result: {
      harnesses: [],
      items: installed.map(installedAt),
      missingProjects: [],
      warnings: [],
    },
  });
  useNavStore.setState({
    page: "package",
    packageRef: { kind: "skill", name: "gh", scope: here },
    packageView: null,
  });
  const host = mount(<PackagePage />);
  // The page points the editor at its own place on mount, and that read
  // has to land before the editor can be pointed anywhere else.
  await settle();
  return host;
};

// What the Customize tab does when its project chip is clicked: the
// editor's open draft becomes another place's.
const editElsewhere = (scope: Project) =>
  act(() => useEditorStore.getState().setScope(scope));

const title = (host: HTMLElement) => host.querySelector("h1")?.textContent;

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.packageMeta).mockResolvedValue(nothing);
  vi.mocked(commands.packageFiles).mockResolvedValue(nothing);
  vi.mocked(commands.packageVersions).mockResolvedValue(nothing);
  vi.mocked(commands.packageReadme).mockResolvedValue(nothing);
  vi.mocked(commands.editorInventory).mockResolvedValue(nothing);
  vi.mocked(commands.libraryProvenance).mockResolvedValue(nothing);
  vi.mocked(commands.revealPath).mockResolvedValue({
    status: "ok",
    data: null,
  });
  vi.mocked(commands.openInEditor).mockResolvedValue({
    status: "ok",
    data: null,
  });
  useEditorStore.setState({
    scope: { scope: "global" },
    draft: null,
    base: null,
    saved: {},
    dirty: false,
  });
  useUpdatesStore.setState({ rows: [], loaded: true });
  useAuditStore.setState({ views: [], auditedAt: null, checkError: null });
});

// The score the audit gave this package's bytes, and what produced it.
// Nothing else in the app renders a scope's `safety` rows, so a page that
// dropped this block would leave every installed reading unread.
describe("the package page's safety block", () => {
  it("shows the score for this place, with the findings behind it", async () => {
    useAuditStore.setState({
      auditedAt: 1,
      views: [
        {
          scope: VG,
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          adoptable: ADOPTABLE,
          exits: [],
          safety: [
            {
              kind: "skill",
              name: "gh",
              harness: "claude",
              scope: VG,
              location: "",
              findings: [
                {
                  rule: "dangerous-commands",
                  severity: "high",
                  location: "SKILL.md:20",
                  message: "runs a shell command that deletes files",
                  remediation: "scope the command to a specific path",
                },
              ],
              skipped: [],
              safety: { score: 58, deductions: [] },
              quality: null,
              ruleset: 3,
            },
          ],
        },
      ],
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain(SEVERITY_LABELS.high);
    expect(host.textContent).toContain("SKILL.md:20");
  });

  it("scores the place the page is about, not another place's copy", async () => {
    useAuditStore.setState({
      auditedAt: 1,
      views: [
        {
          scope: HYPR,
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          adoptable: ADOPTABLE,
          exits: [],
          safety: [
            {
              kind: "skill",
              name: "gh",
              harness: "claude",
              scope: HYPR,
              location: "",
              findings: [],
              skipped: [],
              safety: { score: 12, deductions: [] },
              quality: null,
              ruleset: 3,
            },
          ],
        },
      ],
    });

    const host = await openPage(VG, [VG, HYPR], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).not.toContain("12/100");
  });
});

// The header names a place, and the editor is pointed wherever the
// Customize tab was last used. Those are different places the moment the
// tab's project chip is clicked, and the mark has to keep answering for
// the one the page is about.
describe("the package page's header mark", () => {
  it("still names this place after the editor moves to another", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: CUSTOMIZED,
      [scopeKey(HYPR)]: PLAIN,
    });
    expect(title(host)).toContain("Customized in vg");

    await editElsewhere(HYPR);
    expect(useEditorStore.getState().scope).toEqual(HYPR);
    expect(title(host)).toContain("Customized in vg");
  });

  it("does not borrow the mark of the place the editor moved to", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: PLAIN,
      [scopeKey(HYPR)]: CUSTOMIZED,
    });
    expect(title(host)).not.toContain("Customized");

    await editElsewhere(HYPR);
    expect(useEditorStore.getState().draft).toEqual(CUSTOMIZED);
    expect(title(host)).not.toContain("Customized");
  });
});

// A package installed in two places has two copies on disk. The page
// names one of them, so the actions that open a file open that copy —
// not whichever installation the scan happened to list first.
describe("the package page's file actions", () => {
  const openIn = async (host: HTMLElement, label: string) => {
    const trigger = Array.from(host.querySelectorAll("button")).find(
      (button) => button.textContent === OPEN_IN_LABEL,
    );
    if (!trigger) throw new Error("no Open in… button rendered");
    // Opened from the keyboard: the menu's pointer path wants pointer
    // events jsdom does not deliver, and the item a keyboard reaches is
    // wired to the same handler a pointer would reach.
    trigger.focus();
    await userEvent.keyboard("{ArrowDown}");
    const item = Array.from(
      document.querySelectorAll<HTMLElement>('[role="menuitem"]'),
    ).find((entry) => entry.textContent === label);
    if (!item) throw new Error(`no "${label}" entry in the open menu`);
    await userEvent.click(item);
  };

  it("leave with the page when this place has no copy", async () => {
    // Installed elsewhere only. Another place's copy is not a stand-in:
    // the page describing one place while its buttons work on another is
    // the fault this page exists to avoid, so it goes back instead.
    const back = vi.fn();
    useNavStore.setState({ back });
    const host = await openPage(VG, [HYPR], {});
    expect(back).toHaveBeenCalled();
    expect(
      Array.from(host.querySelectorAll("button")).some(
        (button) => button.textContent === OPEN_IN_LABEL,
      ),
    ).toBe(false);
  });

  it("open the copy in the place the page names", async () => {
    // hyprtrade's copy is listed first, so a page that took the first
    // installation would open the wrong project's files.
    const host = await openPage(VG, [HYPR, VG], {});

    await openIn(host, OPEN_IN_FILE_BROWSER_LABEL);
    expect(commands.revealPath).toHaveBeenCalledWith(
      "/work/vg/.claude/skills/gh",
    );

    await openIn(host, OPEN_IN_EDITOR_LABEL);
    expect(commands.openInEditor).toHaveBeenCalledWith(
      editorOpenPath("/work/vg/.claude/skills/gh"),
    );
  });
});
