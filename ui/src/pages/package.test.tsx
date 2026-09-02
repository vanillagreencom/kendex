// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  ItemKind,
  Manifest_Serialize,
  ObservedItem,
  Scope,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  OPEN_IN_EDITOR_LABEL,
  OPEN_IN_FILE_BROWSER_LABEL,
  OPEN_IN_LABEL,
} from "@/lib/copy";
import { SAFETY_TAB, SAFETY_VENDOR } from "@/lib/copy-safety";
import {
  EDITED_CANT_UPDATE_NOTE,
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import { editorOpenPath } from "@/lib/editor-path";
import { SEVERITY_LABELS } from "@/lib/labels";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import type { PackageView } from "@/stores/nav-types";
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
    getScopeSettings: vi.fn(),
    revealPath: vi.fn(),
    openInEditor: vi.fn(),
    libraryProvenance: vi.fn(),
    packageDiff: vi.fn(),
    // The page's safety tab asks for a fresh audit as it mounts.
    auditAll: vi.fn(),
  },
}));

type Project = Extract<Scope, { scope: "project" }>;
const VG: Project = { scope: "project", root: "/work/vg" };
const HYPR: Project = { scope: "project", root: "/work/hyprtrade" };

const installedAt = (
  scope: Project,
  kind: ItemKind = "skill",
): ObservedItem => ({
  kind,
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
  /** What the page opens showing. An Updates-row Preview hands it a
   *  comparison, so the page starts on a diff rather than on its files. */
  packageView: PackageView | null = null,
  /** The package's kind. Only the kinds a manifest overlays get a
   *  Customize tab; every kind gets the rest of the strip. */
  kind: ItemKind = "skill",
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
      items: installed.map((scope) => installedAt(scope, kind)),
      missingProjects: [],
      warnings: [],
    },
  });
  useNavStore.setState({
    page: "package",
    packageRef: { kind, name: "gh", scope: here },
    packageView,
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

const header = (host: HTMLElement) => host.querySelector("header")?.textContent;

/** What the Updates read says about gh in one place: nothing hand-edited
 *  and nothing forked. Without a row a place's hand-edit state is unread,
 *  and the mark counts only places somebody has looked at. */
const updateRow = (scope: Project): UpdateRow => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: null,
  latest: null,
  updateAvailable: false,
  pinned: false,
  holdOwner: null,
  ignored: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: false,
  canTakeLatest: false,
  derived: false,
  requiredBy: [],
  forked: false,
  mixed: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
});

beforeEach(() => {
  vi.clearAllMocks();
  // clearAllMocks leaves implementations standing, and a test that
  // answers the audit would otherwise answer it for every test after
  // it in this file. The default is an audit that ran and found nothing
  // to say about this package: a check that never answers is a state the
  // safety tab reports, so a test must ask for it rather than inherit it.
  vi.mocked(commands.auditAll).mockReset();
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.packageMeta).mockResolvedValue(nothing);
  vi.mocked(commands.packageFiles).mockResolvedValue(nothing);
  vi.mocked(commands.packageVersions).mockResolvedValue(nothing);
  vi.mocked(commands.packageReadme).mockResolvedValue(nothing);
  vi.mocked(commands.editorInventory).mockResolvedValue(nothing);
  // Every place read and holding no settings value off a default, so the
  // manifest is what decides the header's mark.
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, skills: [], base: null },
  });
  vi.mocked(commands.libraryProvenance).mockResolvedValue(nothing);
  vi.mocked(commands.packageDiff).mockResolvedValue(nothing);
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
    settings: null,
    settingsEdits: [],
    savedSettings: {},
    dirty: false,
    manifestDirty: false,
  });
  useUpdatesStore.setState({
    rows: [],
    read: READ_LANDED,
    checking: false,
    pendingFollows: [],
  });
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
});

/** One place's audit view with gh scored 58, one finding to show under it. */
const scoredView: AuditView = {
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
      targets: [{ harness: "claude", location: "" }],
      scope: VG,
      findings: [
        {
          rule: "dangerous-commands",
          severity: "high",
          location: "SKILL.md",
          line: 20,
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
};

/** The Safety score tab's own label, which carries the figure. */
const scoreTab = (host: HTMLElement) => {
  const found = [...host.querySelectorAll('[data-slot="tabs-trigger"]')].find(
    (trigger) => trigger.textContent?.startsWith(SAFETY_TAB),
  );
  if (!found) throw new Error("no Safety score tab");
  return found as HTMLElement;
};

// The Update on this page and the note where it would have been are one
// string. The kind's own refusal outranks everything, because no check can
// ever lift it; then how the read went, which the row cannot say; and only
// a settled read may call this place one the check never covered.
describe("what the package page says instead of Update", () => {
  /** A refusal core sent on the row. Pass-through is the whole property,
   *  so this is a string core would never send: core's own wording here
   *  would read as a cross-boundary pin and be none, since the equality
   *  asserted is fixture against rendered note. */
  const NO_PER_PACKAGE = "REFUSED-BY-CORE: this kind moves another way";

  /** A timeline with a newer version to move to, which is what puts the
   *  note where the button would have been. */
  const VERSIONS: VersionRow[] = [
    {
      id: "b".repeat(40),
      label: "v2",
      date: "2026-08-28T12:00:00Z",
      summary: "newer",
      installed: false,
      newerThanInstalled: true,
    },
    {
      id: "a".repeat(40),
      label: "v1",
      date: "2026-08-01T12:00:00Z",
      summary: "what is installed",
      installed: true,
      newerThanInstalled: false,
    },
  ];

  /** The page over an update standing: how its read went, the rows it
   *  holds, and whether a check is out behind them. */
  const openWith = async (
    standing: Partial<{
      read: ReadState;
      rows: UpdateRow[];
      checking: boolean;
    }>,
    kind: ItemKind = "skill",
  ) => {
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: VERSIONS,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: {
        source: "cat",
        repo: "o/r",
        repoUrl: null,
        rev: null,
        current: null,
        installedAt: null,
        harnesses: ["claude"],
        enabled: true,
        fork: null,
        catalog: null,
      },
    });
    useUpdatesStore.setState(standing);
    return openPage(VG, [VG], { [scopeKey(VG)]: PLAIN }, null, kind);
  };

  it("says a check is running before the first read answers", async () => {
    const host = await openWith({ read: READ_PENDING });
    expect(host.textContent).toContain(UPDATES_CHECKING);
  });

  // The page's own timeline read landed, so the versions on screen are
  // facts and only the standing behind Update is unconfirmed. That is the
  // whole reason this wording is not the Updates table's, and asserting
  // the shorter of the two by containment would not see the difference.
  it("asks for a check that succeeds when the last read failed", async () => {
    const host = await openWith({ read: readFailed("no network") });
    expect(host.textContent).toContain(UPDATE_NEEDS_CHECK_HERE);
    expect(host.textContent).not.toContain(UPDATE_NEEDS_CHECK_NOTE);
  });

  // The kind's refusal is core's own, derived from the kind alone, so no
  // check that ever succeeds will produce an Update here. Told to check
  // again, a person offline would retry something they cannot win.
  it("names the kind's own refusal over a read that failed", async () => {
    const host = await openWith(
      {
        read: readFailed("no network"),
        rows: [
          {
            ...updateRow(VG),
            kind: "pi-extension",
            noPerPackageUpdate: NO_PER_PACKAGE,
          },
        ],
      },
      "pi-extension",
    );
    expect(host.textContent).toContain(NO_PER_PACKAGE);
    expect(host.textContent).not.toContain(UPDATE_NEEDS_CHECK_HERE);
  });

  it("says the check never covered this place once a read has settled", async () => {
    const host = await openWith({ read: READ_LANDED });
    expect(host.textContent).toContain(NO_UPDATE_STANDING_NOTE);
  });

  // A landed read is not a settled one: a Check or a focus reload is a
  // read about to speak for this place, and calling its silence a fact
  // states a ruling still being made.
  it("says a check is running where one is out and no row covers the place", async () => {
    const host = await openWith({ read: READ_LANDED, checking: true });
    expect(host.textContent).toContain(UPDATES_CHECKING);
    expect(host.textContent).not.toContain(NO_UPDATE_STANDING_NOTE);
  });

  // With a row for this place, the row is the whole reading — the same one
  // Update all and the row's own button take. A check merely running does
  // not withhold it: the row is still the last answer about this place.
  it("reads the row itself where a read covered the place", async () => {
    const host = await openWith({
      read: READ_LANDED,
      checking: true,
      rows: [{ ...updateRow(VG), blockedByLocalEdit: true }],
    });
    expect(host.textContent).toContain(EDITED_CANT_UPDATE_NOTE);
    expect(host.textContent).not.toContain(NO_UPDATE_STANDING_NOTE);
    expect(host.textContent).not.toContain(UPDATES_CHECKING);
  });
});

// The score the audit gave this package's bytes, and what produced it.
// Nothing else in the app renders a scope's `safety` rows, so a page that
// dropped this tab would leave every installed reading unread.
describe("the package page's safety tab", () => {
  it("shows the score for this place, with the findings behind it", async () => {
    // The mount asks for a fresh audit and gets one, so the tab's figure is
    // a reading the check just took rather than one kept from before a
    // failure — which is a different label and a different claim.
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scoredView],
    });
    useAuditStore.setState({
      auditedAt: 1,
      views: [scoredView],
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(scoreTab(host).textContent).toBe(`${SAFETY_TAB}58`);
    // The score is a tab of its own, so Overview opens at the file the page
    // is about rather than at a block in the way of it.
    expect(host.textContent).not.toContain("58/100");

    await act(async () => {
      scoreTab(host).click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain(SEVERITY_LABELS.high);
    expect(host.textContent).toContain("SKILL.md:20");
  });

  // A Preview from an Updates row opens this page straight into a diff. The
  // score answers for the whole package, not for whichever two versions are
  // side by side, so a comparison on the Overview tab cannot be what keeps
  // the figure off the strip.
  it("carries the score while a comparison is open", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scoredView],
    });
    useAuditStore.setState({
      auditedAt: 1,
      views: [scoredView],
    });

    const host = await openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      {
        mode: "diff",
        from: "1111111111",
        to: "2222222222",
      },
    );

    expect(scoreTab(host).textContent).toBe(`${SAFETY_TAB}58`);

    await act(async () => {
      scoreTab(host).click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
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
              targets: [{ harness: "claude", location: "" }],
              scope: HYPR,
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

    // Nothing scored the place this page is about, so the tab shows the
    // dash rather than the other place's 12.
    expect(scoreTab(host).textContent).toBe(`${SAFETY_TAB}—`);
  });

  // One place holds one copy per harness, and the reading merges them all.
  // A vendor read off whichever copy the scan listed first would answer for
  // a set it does not speak for, and would hide the score the reader's own
  // copy earned behind "kendex doesn't check this".
  it("shows the score where one copy is the harness's and one is not", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scoredView],
    });
    useAuditStore.setState({ auditedAt: 1, views: [scoredView] });
    // The bundled copy is listed first, exactly the order that hid the score.
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [
          { ...installedAt(VG), harness: "claude", vendor: "Anthropic" },
          { ...installedAt(VG), harness: "codex" },
        ],
        missingProjects: [],
        warnings: [],
      },
    });
    useNavStore.setState({
      page: "package",
      packageRef: { kind: "skill", name: "gh", scope: VG },
      packageView: null,
    });
    const host = mount(<PackagePage />);
    await settle();

    expect(scoreTab(host).textContent).toBe(`${SAFETY_TAB}58`);

    await act(async () => {
      scoreTab(host).click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).not.toContain(SAFETY_VENDOR);
  });
});

// The page names a place; the mark is about the package. It has to say
// the same thing the package's Library row says, wherever the page was
// opened from and wherever the editor is pointed — those are the two ways
// the same package used to get two different answers.
describe("the package page's mark", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [updateRow(VG), updateRow(HYPR)],
      read: READ_LANDED,
    });
  });

  it("counts every place, not the one the page was opened at", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: CUSTOMIZED,
      [scopeKey(HYPR)]: CUSTOMIZED,
    });
    await settle();
    expect(header(host)).toContain(
      "Customized in vg and hyprtrade · 2 of 2 projects",
    );
  });

  it("says so about a place the page was not opened at", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: PLAIN,
      [scopeKey(HYPR)]: CUSTOMIZED,
    });
    await settle();
    expect(header(host)).toContain("Customized in hyprtrade · 1 of 2 projects");
  });

  it("stands still while the editor moves to another place", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: CUSTOMIZED,
      [scopeKey(HYPR)]: PLAIN,
    });
    await settle();
    const said = "Customized in vg · 1 of 2 projects";
    expect(header(host)).toContain(said);

    await editElsewhere(HYPR);
    expect(useEditorStore.getState().scope).toEqual(HYPR);
    expect(header(host)).toContain(said);
  });

  it("says nothing where no place holds anything", async () => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: PLAIN,
      [scopeKey(HYPR)]: PLAIN,
    });
    await settle();
    expect(header(host)?.includes("Customized")).toBe(false);
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

// Four tabs in one order, and only one of them can be missing: Customize
// is the tab a kind can lack, so it goes last and the others keep their
// place whatever the package is.
describe("the package page's tabs", () => {
  const tabs = (host: HTMLElement) =>
    Array.from(host.querySelectorAll('[role="tab"]')).map(
      (tab) => tab.textContent,
    );

  it("puts Projects and the score between Overview and Customize", async () => {
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    // Nothing has scored this package in these tests, so the tab carries
    // the dash it shows before a reading arrives.
    expect(tabs(host)).toEqual([
      "Overview",
      "Projects",
      `${SAFETY_TAB}—`,
      "Customize",
    ]);
  });

  it("keeps them both for a kind with nothing to customize", async () => {
    const host = await openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      null,
      "mcp-server",
    );

    expect(tabs(host)).toEqual(["Overview", "Projects", `${SAFETY_TAB}—`]);
  });
});

// The top-right button takes every copy in every place, so it says so —
// and the dialog behind it names the places before it runs.
describe("the package page's delete action", () => {
  it("is named Delete and names every place it would reach", async () => {
    const host = await openPage(VG, [VG, HYPR], { [scopeKey(VG)]: PLAIN });
    expect(header(host)).not.toContain("Remove…");

    const trigger = Array.from(host.querySelectorAll("button")).find(
      (button) => button.textContent === "Delete",
    );
    if (!trigger) throw new Error("no Delete button in the header");
    await userEvent.click(trigger);
    await settle();

    const said = document.body.textContent ?? "";
    expect(said).toContain("Delete gh?");
    expect(said).toContain("/work/vg");
    expect(said).toContain("/work/hyprtrade");
  });
});
