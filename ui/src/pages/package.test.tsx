// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  ItemKind,
  Manifest_Serialize,
  ObservedItem,
  PackageFile,
  Scope,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  DISCARD_EDITS_LABEL,
  ENABLED_LABEL,
  FORK_NOTICE_TITLE,
  FORKED_BADGE_LABEL,
  FORKED_EDITED_BADGE_LABEL,
  KEEP_AS_FORK_LABEL,
  OPEN_IN_EDITOR_LABEL,
  OPEN_IN_FILE_BROWSER_LABEL,
  OPEN_IN_LABEL,
  PACKAGE_FILES_READ_FAILED,
  PACKAGES_CHECK_FAILED_TITLE,
  PLACE_COUNTING_LABEL,
  README_TAG,
  TRY_AGAIN_LABEL,
  UPDATE_LABEL,
} from "@/lib/copy";
import { CUSTOMIZE_TAB, OVERVIEW_TAB, SAVE_NOTE } from "@/lib/copy-customize";
import {
  CHANGES_TITLE,
  FILE_READ_FAILED_TITLE,
  FILES_READING_NOTE,
  FILES_TAB,
  NO_FILES_NOTE,
  NO_README_NOTE,
} from "@/lib/copy-files";
import { DELETE_LABEL, PROJECTS_TAB } from "@/lib/copy-projects";
import { SAFETY_TAB, SAFETY_VENDOR } from "@/lib/copy-safety";
import {
  EDITED_CANT_UPDATE_NOTE,
  NO_UPDATE_STANDING_NOTE,
  PACKAGE_READ_FAILED,
  packageReadFailedNote,
  sourceUnfetchedNote,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
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
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";
import { placeRead } from "@/test/settings-read";
import { PackagePage } from "./package";

// The page is mounted against the real stores; only the backend is
// stubbed. Each command the page or its children call on mount answers
// with nothing, except the manifest read, which answers per place.
vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    packageMeta: vi.fn(),
    packageFiles: vi.fn(),
    packageFile: vi.fn(),
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

const installedAt = (scope: Project, kind: ItemKind = "skill"): ObservedItem =>
  observed({
    kind,
    name: "gh",
    scope,
    harness: "claude",
    path: `${scope.root}/.claude/skills/gh`,
    fileState: { state: "file" },
    enabled: true,
    origin: null,
    summary: "about gh",
    action: null,
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
      data: {
        manifest: manifests[scopeKey(scope)] ?? null,
        base: null,
        file: "kendex.toml",
      },
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
  // The join has answered and these installations are the declared
  // package, which is the identity the nav ref below carries. A page about
  // a marketplace skill with a manifest, versions and a fork is not an
  // installation nothing recorded, and a fixture saying so would be
  // describing a different thing.
  useProvenanceStore.setState({
    rows: installed.map((scope) => {
      const item = installedAt(scope, kind);
      return {
        scope,
        kind,
        name: "gh",
        harness: item.harness,
        // The join answers per file, so a fixture naming a different one
        // would be about a different installation.
        at: item.at,
        origin: {
          origin: "marketplace" as const,
          source: "cat",
          repo: "o/r",
        },
        summary: null,
        package: { kind, name: "gh" },
      };
    }),
    loaded: true,
    answeredFor: 0,
  });
  useNavStore.setState({
    page: "package",
    packageRef: { kind, name: "gh", scope: here, identity: "recorded" },
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
  forkEdited: false,
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
  vi.mocked(commands.packageFile).mockResolvedValue(nothing);
  vi.mocked(commands.packageVersions).mockResolvedValue(nothing);
  vi.mocked(commands.packageReadme).mockResolvedValue(nothing);
  vi.mocked(commands.editorInventory).mockResolvedValue(nothing);
  // Every place read and holding no settings value off a default, so the
  // manifest is what decides the header's mark.
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, ...placeRead, skills: [], base: null },
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
      source: null,
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
    /** What the timeline read answers: the versions above unless a test
     *  is about the read itself. */
    timeline: Awaited<ReturnType<typeof commands.packageVersions>> = {
      status: "ok",
      data: VERSIONS,
    },
    /** What the record read answers: a following package unless a test
     *  is about that read. */
    record: Awaited<ReturnType<typeof commands.packageMeta>> = {
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
    },
  ) => {
    vi.mocked(commands.packageVersions).mockResolvedValue(timeline);
    vi.mocked(commands.packageMeta).mockResolvedValue(record);
    useUpdatesStore.setState(standing);
    return openPage(VG, [VG], { [scopeKey(VG)]: PLAIN }, null, kind);
  };

  /** The record read for a package the person forked. */
  const forkedRecord = (): Awaited<
    ReturnType<typeof commands.packageMeta>
  > => ({
    status: "ok",
    data: {
      source: "local",
      repo: null,
      repoUrl: null,
      rev: null,
      current: null,
      installedAt: null,
      harnesses: ["claude"],
      enabled: true,
      fork: { source: "cat", "forked-at": "2026-01-01T00:00:00Z" },
      catalog: null,
    },
  });

  // A fork is already the person's copy, so an edit to one is part of what
  // the package is. The header says both words where the row reports the
  // edit, and there is nothing on the page asking what to do about it.
  const forks = [
    {
      name: "names an edited fork as a state on the header",
      edited: true,
      label: FORKED_EDITED_BADGE_LABEL,
    },
    {
      name: "says only Forked where the fork carries no edits",
      edited: false,
      label: FORKED_BADGE_LABEL,
    },
  ];
  expect(forks).toHaveLength(2);
  it.each(forks)("$name", async (row) => {
    const host = await openWith(
      {
        read: READ_LANDED,
        rows: [{ ...updateRow(VG), forked: true, forkEdited: row.edited }],
      },
      "skill",
      { status: "ok", data: VERSIONS },
      forkedRecord(),
    );
    expect(
      {
        label: header(host)?.includes(row.label),
        edited: header(host)?.includes(FORKED_EDITED_BADGE_LABEL),
        notice: host.textContent?.includes(FORK_NOTICE_TITLE),
      },
      row.name,
    ).toEqual({ label: true, edited: row.edited, notice: false });
  });

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

  /** The header's Try again, which only a read that failed offers. */
  const headerRetry = (host: HTMLElement) =>
    Array.from(host.querySelectorAll("header button")).filter(
      (button) => button.textContent === TRY_AGAIN_LABEL,
    );

  /** The timeline's answer on a source no fetch has downloaded. */
  const UNFETCHED = {
    status: "error",
    error: { kind: "source-pending", source: "cat" },
  } as const;

  // A source no fetch has downloaded is core's answer, not a failed read:
  // reading again answers the same, and the check it would send the reader
  // to has already left this place without a row for the same reason. The
  // note names the source and carries no Try again, and it outranks the
  // check's "never covered this place", which is the symptom of it.
  it("names the source no fetch has downloaded, with no Try again", async () => {
    const host = await openWith({ read: READ_LANDED }, "skill", UNFETCHED);

    expect(header(host)).toContain(sourceUnfetchedNote("cat"));
    expect(headerRetry(host)).toHaveLength(0);
    expect(header(host)).not.toContain(NO_UPDATE_STANDING_NOTE);
    expect(header(host)).not.toContain(PACKAGE_READ_FAILED);
  });

  // The record read touches the manifest and the lock, never the source, so
  // its failing beside an unfetched timeline is a second fact and one a
  // re-read can lift. It keeps its words and its Try again; the unfetched
  // note waits behind it.
  it("lets a record read that failed on its own speak ahead of it", async () => {
    const REFUSED = "REFUSED-BY-CORE: the lock could not be read";
    const host = await openWith({ read: READ_LANDED }, "skill", UNFETCHED, {
      status: "error",
      error: REFUSED,
    });

    expect(header(host)).toContain(packageReadFailedNote(REFUSED));
    expect(headerRetry(host)).toHaveLength(1);
    expect(header(host)).not.toContain(sourceUnfetchedNote("cat"));
  });

  // The control: every other refusal of the timeline is a read that failed,
  // in core's words, and a re-read can lift it. The row is there so the
  // check has no fact of its own to state ahead of the read.
  it("offers Try again over a timeline read that failed", async () => {
    const REFUSED = "REFUSED-BY-CORE: the lock could not be read";
    const host = await openWith(
      { read: READ_LANDED, rows: [updateRow(VG)] },
      "skill",
      {
        status: "error",
        error: { kind: "failed", message: REFUSED },
      },
    );

    expect(header(host)).toContain(packageReadFailedNote(REFUSED));
    expect(headerRetry(host)).toHaveLength(1);
  });
});

// The Overview's file list is the page's third read, and a read that did not
// land is not a package that ships no files: only a landed read may leave the
// column empty. The read gates nothing, so it says so where the list would
// be and offers the read again, while the header's Update stays put.
describe("the package page's Files tab", () => {
  /** The tab the tree and preview live on. The Overview is what a page
   *  opens on, so every reading of the files starts by opening this. */
  const openFiles = async (host: HTMLElement) => {
    const tab = Array.from(host.querySelectorAll('[role="tab"]')).find(
      (one) => one.textContent === FILES_TAB,
    );
    await userEvent.click(tab as HTMLElement);
    await settle();
  };

  /** A timeline and a record that together earn an Update, so the header
   *  is what shows whether the file read withholds one. */
  const openWithUpdate = async () => {
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: [
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
      ],
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
    useUpdatesStore.setState({ rows: [updateRow(VG)], read: READ_LANDED });
    return openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
  };

  /** The Files section's own Try again, apart from the header's. */
  const filesRetry = (host: HTMLElement) =>
    Array.from(host.querySelectorAll("button")).filter(
      (button) =>
        button.textContent === TRY_AGAIN_LABEL &&
        button.closest("header") === null,
    );

  /** A tree row by the path it names; its text also carries what the row
   *  says about the file. */
  const rowFor = (host: HTMLElement, path: string) =>
    [...host.querySelectorAll("button")].find((one) => one.title === path);

  /** A refusal core sent. Pass-through is the property, so the wording is
   *  one core never uses. */
  const REFUSED = "REFUSED-BY-CORE: the install directory is gone";

  it("says the read was refused, offers it again, and keeps Update", async () => {
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "error",
      error: REFUSED,
    });
    const host = await openWithUpdate();
    await openFiles(host);

    expect(host.textContent).toContain(
      `${PACKAGE_FILES_READ_FAILED} — ${REFUSED}`,
    );
    expect(filesRetry(host)).toHaveLength(1);
    expect(header(host)).toContain(UPDATE_LABEL);
    expect(header(host)).not.toContain(REFUSED);

    // The read again lands, and the tree takes the note's place. The tab
    // opens on the readme, so the row holding it carries the marker that
    // says which file the pane is showing.
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "ok",
      data: [
        { path: "SKILL.md", size: 10, isReadme: true },
        { path: "references/deep.md", size: 20, isReadme: false },
      ],
    });
    await userEvent.click(filesRetry(host)[0] as HTMLElement);
    await settle();
    expect(rowFor(host, "SKILL.md")?.textContent).toContain(README_TAG);
    expect(rowFor(host, "references/deep.md")?.textContent).not.toContain(
      README_TAG,
    );
    expect(host.textContent).not.toContain(PACKAGE_FILES_READ_FAILED);
    expect(filesRetry(host)).toHaveLength(0);
  });

  // A rejection is the transport failing rather than the engine refusing,
  // and it reaches the page as the same failed read with the message it
  // was thrown with.
  it("says the read was rejected, with the reason it was thrown with", async () => {
    vi.mocked(commands.packageFiles).mockRejectedValue(
      new Error("REJECTED-BY-TRANSPORT: bridge closed"),
    );
    const host = await openWithUpdate();
    await openFiles(host);

    expect(host.textContent).toContain(
      `${PACKAGE_FILES_READ_FAILED} — REJECTED-BY-TRANSPORT: bridge closed`,
    );
    expect(filesRetry(host)).toHaveLength(1);
    expect(header(host)).toContain(UPDATE_LABEL);
  });

  // A first read still on its way is not a package that ships no files:
  // the tab says it is reading, and only the landing may make that claim.
  it("says it is reading while the first read is out, then that there are no files", async () => {
    let land: (files: PackageFile[]) => void = () => {};
    vi.mocked(commands.packageFiles).mockReturnValue(
      new Promise((resolve) => {
        land = (data) => resolve({ status: "ok", data });
      }),
    );
    const host = await openWithUpdate();
    await openFiles(host);

    expect(host.textContent).not.toContain(NO_FILES_NOTE);
    expect(host.textContent).toContain(FILES_READING_NOTE);
    expect(filesRetry(host)).toHaveLength(0);

    await act(async () => {
      land([]);
    });
    await settle();
    expect(host.textContent).toContain(NO_FILES_NOTE);
    expect(host.textContent).not.toContain(FILES_READING_NOTE);
  });

  // The control: a landed read with nothing in it is the one answer that
  // says so plainly, with no failure claimed and nothing to try again.
  it("says a package ships no files, without claiming a failed read", async () => {
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "ok",
      data: [],
    });
    const host = await openWithUpdate();
    await openFiles(host);

    expect(host.textContent).toContain(NO_FILES_NOTE);
    expect(host.textContent).not.toContain(PACKAGE_FILES_READ_FAILED);
    expect(filesRetry(host)).toHaveLength(0);
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

  // A safety score anywhere in the app is the way to the reading behind
  // it, so the link that opened this page says which tab it meant and the
  // page opens there with nothing else pressed.
  it("opens on this tab when the link that opened the page asked for it", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scoredView],
    });
    useAuditStore.setState({ auditedAt: 1, views: [scoredView] });

    const host = await openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      {
        mode: "safety",
      },
    );

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain("SKILL.md:20");
  });

  // The control: a page opened with no tab asked for opens on Overview,
  // so the case above is about the request rather than about the default.
  it("opens on Overview when nothing asked for a tab", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scoredView],
    });
    useAuditStore.setState({ auditedAt: 1, views: [scoredView] });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).not.toContain("58/100");
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
              source: null,
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

    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: useAuditStore.getState().views,
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
    // The bundled copy is listed first, the order that would hide the score.
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
    // The join answers for the copy kendex installed. Vendor content
    // carries no row by design, so the bundled copy is absent from it and
    // the package is still the one the codex row records.
    useProvenanceStore.setState({
      rows: [
        {
          scope: VG,
          kind: "skill",
          name: "gh",
          harness: "codex",
          at: installedAt(VG).at,
          origin: { origin: "marketplace", source: "cat", repo: "o/r" },
          summary: null,
          package: { kind: "skill", name: "gh" },
        },
      ],
      loaded: true,
      answeredFor: 0,
    });
    useNavStore.setState({
      page: "package",
      packageRef: {
        kind: "skill",
        name: "gh",
        scope: VG,
        identity: "recorded",
      },
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
// the same package could get two different answers.
describe("the package page's mark", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [updateRow(VG), updateRow(HYPR)],
      read: READ_LANDED,
    });
  });

  const marks = [
    {
      name: "counts every place, not the one the page was opened at",
      vg: CUSTOMIZED,
      hypr: CUSTOMIZED,
      label: "Customized in vg and hyprtrade · 2 of 2 projects",
    },
    {
      name: "says so about a place the page was not opened at",
      vg: PLAIN,
      hypr: CUSTOMIZED,
      label: "Customized in hyprtrade · 1 of 2 projects",
    },
    {
      name: "says nothing where no place holds anything",
      vg: PLAIN,
      hypr: PLAIN,
      label: null,
    },
  ];
  expect(marks).toHaveLength(3);
  it.each(marks)("$name", async (row) => {
    const host = await openPage(VG, [VG, HYPR], {
      [scopeKey(VG)]: row.vg,
      [scopeKey(HYPR)]: row.hypr,
    });
    await settle();
    expect(header(host)?.includes(row.label ?? "Customized"), row.name).toBe(
      row.label !== null,
    );
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

  // Delete takes every copy at once, and the dialog closes on its own the
  // moment the removals answer. Leaving the page is this effect's alone to
  // decide: a copy of the judgment kept by the dialog would be read off a
  // scan taken before the removals.
  it("leave with the page once the scan knows the package nowhere", async () => {
    const back = vi.fn();
    useNavStore.setState({ back });

    await openPage(VG, [], {});

    expect(back).toHaveBeenCalled();
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
      "/work/vg/.claude/skills/gh",
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

  const kinds = [
    {
      name: "puts Files, Projects and the score between Overview and Customize",
      kind: "skill",
      labels: ["Overview", "Files", "Projects", `${SAFETY_TAB}—`, "Customize"],
    },
    {
      name: "keeps them all for a kind with nothing to customize",
      kind: "mcp-server",
      labels: ["Overview", "Files", "Projects", `${SAFETY_TAB}—`],
    },
  ] satisfies { name: string; kind: ItemKind; labels: string[] }[];
  expect(kinds).toHaveLength(2);
  it.each(kinds)("$name", async (row) => {
    const host = await openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      null,
      row.kind,
    );
    expect(tabs(host), row.name).toEqual(row.labels);
  });
});

// The chip in the Details block names a harness, and a harness has a page:
// the Library, showing what is installed for it.
describe("the harness chips on the package page", () => {
  it("open the harness the chip names", async () => {
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    const chip = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Claude Code",
    );
    if (!chip) throw new Error("the harness chip is not a control");
    await userEvent.click(chip);
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter).toEqual({ harness: "claude" });
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

// Two things can wear one scope, kind and name: a package the records
// account for and a file nothing recorded. Every read and every write on
// this page addresses a declaration by those three, so a page opened on the
// second must issue none of them — it would be reading and changing the
// first while describing the second.
describe("a package page opened on an installation nothing recorded", () => {
  const stray = (): ObservedItem =>
    observed({
      ...installedAt(VG),
      harness: "cursor",
      path: `${VG.root}/.cursor/skills/gh`,
    });

  let opened: ReturnType<typeof vi.fn>;

  const openObserved = async () => {
    opened = vi.fn().mockResolvedValue(undefined);
    useEditorStore.setState({ openScope: opened as never });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installedAt(VG), stray()],
        missingProjects: [],
        warnings: [],
      },
    });
    // The claude copy is the recorded package; the cursor one is nobody's.
    joinAnswered([
      {
        scope: VG,
        kind: "skill",
        name: "gh",
        harness: "claude",
        at: null,
        origin: { origin: "marketplace", source: "cat", repo: "o/r" },
        summary: null,
        package: { kind: "skill", name: "gh" },
      },
      {
        scope: VG,
        kind: "skill",
        name: "gh",
        harness: "cursor",
        at: null,
        origin: { origin: "unmanaged" },
        summary: null,
        package: null,
      },
    ]);
    useNavStore.setState({
      page: "package",
      packageRef: {
        kind: "skill",
        name: "gh",
        scope: VG,
        identity: "observed",
        // A row nothing recorded is named by the file it reads.
        at: stray().at,
      },
      packageView: null,
    });
    const host = mount(<PackagePage />);
    await settle();
    return host;
  };

  it("reads no declaration and offers no write that would land on one", async () => {
    const back = vi.fn();
    useNavStore.setState({ back });
    // Edits left in the editor from the package opened before this one.
    // They belong to that manifest, and this page never opens one of its
    // own, so a save bar here would write them from a page about a file
    // the records know nothing about.
    useEditorStore.setState({ dirty: true });
    // And the recorded gh, edited by hand in this very place: read by
    // scope, kind and name — the address this observed file shares — its
    // notice would offer to keep those edits as a fork or discard them,
    // both writes to a declaration this page is not about.
    useUpdatesStore.setState({
      rows: [{ ...updateRow(VG), blockedByLocalEdit: true }],
      read: READ_LANDED,
    });
    const host = await openObserved();

    // The page stays: this installation is on the machine and is what the
    // link named.
    expect(back).not.toHaveBeenCalled();
    // None of the three declaration reads was issued for it.
    for (const read of [
      commands.packageMeta,
      commands.packageVersions,
      commands.packageFiles,
    ]) {
      expect(vi.mocked(read)).not.toHaveBeenCalled();
    }
    // And no control that writes one is drawn.
    const labels = Array.from(host.querySelectorAll("button")).map(
      (one) => one.textContent,
    );
    expect(labels).not.toContain(DELETE_LABEL);
    expect(host.querySelector("#package-enabled")).toBeNull();
    expect(host.textContent).not.toContain(SAVE_NOTE);
    // The body's own two: the hand-edit notice, whose Keep as fork and
    // Discard write that declaration, and the file preview, which reads
    // its bytes by the same address.
    expect(host.textContent).not.toContain(FORK_NOTICE_TITLE);
    expect(labels).not.toContain(KEEP_AS_FORK_LABEL);
    expect(labels).not.toContain(DISCARD_EDITS_LABEL);
    expect(vi.mocked(commands.packageReadme)).not.toHaveBeenCalled();
  });

  // Every surface that reads or writes a declaration, not only the
  // overview's buttons: Projects reads each place's record and offers that
  // declaration's update and removal, and Customize edits its manifest.
  it("offers no tab that would read or write the other package", async () => {
    const host = await openObserved();
    const tabs = Array.from(host.querySelectorAll('[role="tab"]')).map(
      (one) => one.textContent,
    );
    expect(tabs).not.toContain(PROJECTS_TAB);
    expect(tabs).not.toContain(CUSTOMIZE_TAB);
    expect(tabs).toContain(OVERVIEW_TAB);
    // And the editor was never pointed at this place's manifest, which is
    // the other package's wherever one shares the name.
    expect(opened).not.toHaveBeenCalled();
  });

  // The row it IS about stays inspectable: what the tool holds, where, and
  // how to open it. Taking it off the machine is the Not-managed path's.
  // Not only the tabs and the buttons: every value the header and the
  // strip draw is read out of the records by scope, kind and name, which
  // the recorded package shares. None of them may be that package's.
  it("shows no state read out of the other package's records", async () => {
    // The recorded gh is customized in this very place. Read by scope,
    // kind and name — the address this observed file shares — that mark
    // would sit on the header of a page about a file the records know
    // nothing about.
    useEditorStore.setState({
      saved: { [scopeKey(VG)]: CUSTOMIZED as never },
    });
    useUpdatesStore.setState({ rows: [updateRow(VG)], read: READ_LANDED });
    const host = await openObserved();
    const text = host.textContent ?? "";
    // None of the recorded package's state belongs to this page.
    expect(text).not.toContain("Customized");
    expect(text).not.toContain(UPDATE_LABEL);
    expect(
      Array.from(host.querySelectorAll('[role="tab"]')).map(
        (one) => one.textContent,
      ),
    ).toEqual([
      OVERVIEW_TAB,
      // The safety tab keeps its place; what it must not carry is the
      // other package's reading.
      expect.stringContaining(SAFETY_TAB),
    ]);
  });

  it("still shows the installation itself", async () => {
    const host = await openObserved();
    expect(host.textContent).toContain("gh");
    expect(
      Array.from(host.querySelectorAll("button")).map((one) => one.textContent),
    ).toContain(OPEN_IN_LABEL);
  });

  // The links that reach this page — Updates, Customize, a marketplace —
  // stay on screen while the read that says which installations are one
  // package is out, and after it fails. A blank page under a working link
  // is a dead end; the page says what it is waiting on, and offers the
  // read again where there is one to offer.
  it("says what it is waiting on rather than going blank", async () => {
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installedAt(VG)],
        missingProjects: [],
        warnings: [],
      },
    });
    useNavStore.setState({
      page: "package",
      packageRef: {
        kind: "skill",
        name: "gh",
        scope: VG,
        identity: "recorded",
      },
      packageView: null,
    });

    useProvenanceStore.setState({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: READ_PENDING,
    });
    const waiting = mount(<PackagePage />);
    await settle();
    expect(waiting.textContent).toContain(PLACE_COUNTING_LABEL);

    useProvenanceStore.setState({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: readFailed("the join did not read"),
    });
    const failed = mount(<PackagePage />);
    await settle();
    expect(failed.textContent).toContain(PACKAGES_CHECK_FAILED_TITLE);
    expect(
      Array.from(failed.querySelectorAll("button")).map((one) =>
        one.textContent?.trim(),
      ),
    ).toContain(TRY_AGAIN_LABEL);
  });

  // The same page opened on the recorded package keeps everything.
  it("keeps the recorded package's own reads and controls", async () => {
    await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    expect(vi.mocked(commands.packageMeta)).toHaveBeenCalled();
  });
});

// What the Overview is: the facts about the package, then the package's own
// words. The files are a tab of their own, so nothing on the Overview is a
// column beside a pane.
describe("the package page's Overview", () => {
  it("reads the package's own readme under its details and version", async () => {
    vi.mocked(commands.packageReadme).mockResolvedValue({
      status: "ok",
      data: {
        path: "SKILL.md",
        content: "THE-PACKAGE-README-LINE",
        truncated: false,
      },
    });
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    const text = host.textContent ?? "";
    expect(text).toContain("THE-PACKAGE-README-LINE");
    // Under, not beside: the enabled switch is what the details end on,
    // and the readme follows it down the page.
    expect(text.indexOf(ENABLED_LABEL)).toBeLessThan(
      text.indexOf("THE-PACKAGE-README-LINE"),
    );
  });

  // The Overview is the README, so a package that carries none says so.
  // Falling back to whichever file happens to be first would put an
  // arbitrary source file under the details, where a reader would take it
  // for the package describing itself.
  it("says a package carries no readme, and shows no file in its place", async () => {
    vi.mocked(commands.packageReadme).mockResolvedValue({
      status: "ok",
      data: null,
    });
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "ok",
      data: [{ path: "SKILL.md", size: 10, isReadme: false }],
    });
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain(NO_README_NOTE);
    // The one read the Overview makes is the readme's. It never falls
    // through to the package's files, which are the other tab's.
    expect(commands.packageFile).not.toHaveBeenCalled();
  });

  // The control: the Overview reads one file and one only. A package whose
  // readme read failed says so where the readme would be, and does not
  // fall through to a tree of files that belongs on the other tab.
  it("says a readme that could not be read could not be shown, and offers it again", async () => {
    vi.mocked(commands.packageReadme).mockResolvedValue({
      status: "error",
      error: "REFUSED-BY-CORE: the install directory is gone",
    });
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain(FILE_READ_FAILED_TITLE);
    expect(host.textContent).toContain(
      "REFUSED-BY-CORE: the install directory is gone",
    );

    // A failed read is offered again where it failed, the way every other
    // failed read on this page is: without it a transient refusal leaves
    // the Overview holding an error until the page is left.
    const retry = Array.from(host.querySelectorAll("button")).filter(
      (button) =>
        button.textContent === TRY_AGAIN_LABEL &&
        button.closest("header") === null,
    );
    expect(retry).toHaveLength(1);

    vi.mocked(commands.packageReadme).mockResolvedValue({
      status: "ok",
      data: {
        path: "SKILL.md",
        content: "THE-README-THE-RETRY-FOUND",
        truncated: false,
      },
    });
    await userEvent.click(retry[0] as HTMLElement);
    await settle();
    expect(host.textContent).toContain("THE-README-THE-RETRY-FOUND");
    expect(host.textContent).not.toContain(FILE_READ_FAILED_TITLE);
  });
});

// A comparison is a panel over the page, not a page of its own: an Updates
// row's Preview opens it on top of whatever tab the package page is
// showing, and closing it leaves that tab where it was.
describe("the package page's changes panel", () => {
  /** The panel is portalled out of the page's own tree. */
  const panel = () => document.body.textContent ?? "";

  const opened = async () => {
    vi.mocked(commands.packageDiff).mockResolvedValue({
      status: "ok",
      data: {
        files: [
          {
            path: "SKILL.md",
            status: "modified",
            additions: 1,
            deletions: 0,
            lossy: false,
            hunks: [
              {
                header: "@@ -1 +1 @@",
                lines: [
                  {
                    kind: "add",
                    text: "A-LINE-THE-UPDATE-ADDS",
                    oldNo: null,
                    newNo: 1,
                  },
                ],
              },
            ],
          },
        ],
        totalAdditions: 1,
        totalDeletions: 0,
        truncated: false,
      },
    });
    return openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      {
        mode: "diff",
        from: "aaaaaaaaaaaa",
        to: "bbbbbbbbbbbb",
      },
    );
  };

  it("opens on the comparison Updates sent it, with the tabs still there", async () => {
    const host = await opened();

    expect(commands.packageDiff).toHaveBeenCalledWith(
      VG,
      "skill",
      "gh",
      { at: "commit", commit: "aaaaaaaaaaaa" },
      { at: "commit", commit: "bbbbbbbbbbbb" },
      // The place this page names renders through Claude Code, and the
      // installed side is read from that rendering.
      "claude",
    );
    expect(panel()).toContain("A-LINE-THE-UPDATE-ADDS");
    expect(panel()).toContain(CHANGES_TITLE);
    // The page behind it is the package page, not a diff standing in for
    // one: its tabs are still on screen.
    expect(host.querySelectorAll('[role="tab"]').length).toBeGreaterThan(0);
  });

  // The control: with no comparison asked for, no panel is drawn and no
  // comparison is read.
  it("draws no panel and reads no diff when nothing is being compared", async () => {
    vi.mocked(commands.packageDiff).mockResolvedValue(nothing);
    await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(commands.packageDiff).not.toHaveBeenCalled();
    expect(panel()).not.toContain(CHANGES_TITLE);
  });
});
