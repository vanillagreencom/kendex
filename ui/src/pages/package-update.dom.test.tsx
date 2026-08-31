// @vitest-environment jsdom
//
// The package page's Update, apart from the page's other surfaces: the
// button, the reason beside it, and the read state behind both. One
// reading answers all three, so they are proved together and here.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  ItemKind,
  Manifest_Serialize,
  ObservedItem,
  PackageMeta_Serialize,
  Scope,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { PREVIEW_CHANGES_LABEL, UPDATE_LABEL } from "@/lib/copy";
import {
  EDITED_CANT_UPDATE_NOTE,
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import { pageUpdateWithheld } from "@/lib/update-groups";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { PackagePage } from "./package";

// The page is mounted against the real stores; only the backend is
// stubbed. Every command answers with nothing but the three this file
// needs: the manifest read, the timeline, and the meta read Update waits
// for.
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
    auditAll: vi.fn(),
  },
}));

type Project = Extract<Scope, { scope: "project" }>;
const VG: Project = { scope: "project", root: "/work/vg" };
const HYPR: Project = { scope: "project", root: "/work/hyprtrade" };
const PLAIN: Manifest_Serialize = { schema: 1, install: {} };
const nothing = { status: "error" as const, error: "not in this test" };

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

/** Mount the page about `gh` at `here`, installed in every place given. */
const openPage = async (
  here: Project,
  installed: Project[],
  kind: ItemKind = "skill",
) => {
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: PLAIN, base: null },
  });
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
    packageView: null,
  });
  const host = mount(<PackagePage />);
  await settle();
  return host;
};

/** What the Updates read says about gh in one place: nothing hand-edited
 *  and nothing forked, and no newer version until a test asks for one. */
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
  forked: false,
  mixed: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
});

/** One commit on a package's timeline. */
const version = (id: string, installed: boolean): VersionRow => ({
  id,
  label: null,
  date: "2026-01-01",
  summary: "a commit",
  installed,
  newerThanInstalled: !installed,
});

/** What the meta read answers: a following package from a repo source.
 *  Update waits for this read, so a page without it offers nothing. */
const meta: PackageMeta_Serialize = {
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
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.auditAll).mockReset();
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  for (const command of [
    commands.packageMeta,
    commands.packageFiles,
    commands.packageVersions,
    commands.packageReadme,
    commands.editorInventory,
    commands.libraryProvenance,
    commands.packageDiff,
  ] as const) {
    vi.mocked(command).mockResolvedValue(nothing);
  }
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, skills: [], base: null },
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
    loaded: true,
    error: null,
    checking: false,
    overviewInFlight: false,
    pendingFollows: [],
  });
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    checkError: null,
    scopeCheckedAt: {},
  });
});

// The page's Update is one reading: the button and the reason beside it
// come from the same string, so a page that withholds Update always says
// why. Nothing else in the app renders that pair, and the old path read
// the kind directly — a rule that now lives only in core.
describe("the package page's Update", () => {
  /** A timeline with a newer version to move to and an installed one to
   *  move from — what the page reads newness off, never the update row. */
  const newerThanInstalled = [
    version("b".repeat(40), false),
    version("a".repeat(40), true),
  ];

  /** Open the page with a timeline, a meta read that lands, and whatever
   *  the updates store says about this place. */
  const openWithUpdates = async (
    rows: UpdateRow[],
    {
      loaded = true,
      kind = "skill" as ItemKind,
      versions = newerThanInstalled,
      ...standing
    }: {
      loaded?: boolean;
      kind?: ItemKind;
      versions?: VersionRow[];
      error?: string | null;
      checking?: boolean;
      overviewInFlight?: boolean;
    } = {},
  ) => {
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: versions,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: meta,
    });
    // Set in full, never merged: zustand keeps whatever a previous test
    // left, so a leaked `error` would make a pending read read as failed.
    useUpdatesStore.setState({
      rows,
      loaded,
      error: null,
      checking: false,
      overviewInFlight: false,
      pendingFollows: [],
      ...standing,
    });
    return openPage(VG, [VG], kind);
  };

  const updateButton = (host: HTMLElement) =>
    [...host.querySelectorAll("button")].find(
      (button) => button.textContent === UPDATE_LABEL,
    );

  it("offers Update when the row withholds nothing", async () => {
    const host = await openWithUpdates([
      { ...updateRow(VG), updateAvailable: true },
    ]);
    expect(updateButton(host)).toBeDefined();
  });

  // The refusal is core's own sentence, carried on the row. A synthetic
  // string here, so the assertion cannot pass on a constant this side of
  // the boundary happens to hold.
  it("withholds Update for a kind core refuses, and says what core said", async () => {
    const refusal = "REFUSED-BY-CORE: this kind moves another way";
    const host = await openWithUpdates(
      [
        {
          ...updateRow(VG),
          kind: "pi-extension",
          updateAvailable: true,
          noPerPackageUpdate: refusal,
        },
      ],
      { kind: "pi-extension" },
    );
    expect(updateButton(host)).toBeUndefined();
    expect(host.textContent).toContain(refusal);
  });

  // A hand-edited copy is never updated over, and the page has to say so
  // where the button would be rather than showing nothing at all.
  it("withholds Update for an edited copy, and says so", async () => {
    const host = await openWithUpdates([
      { ...updateRow(VG), updateAvailable: true, blockedByLocalEdit: true },
    ]);
    expect(updateButton(host)).toBeUndefined();
    expect(host.textContent).toContain(EDITED_CANT_UPDATE_NOTE);
  });

  // The read covers declared packages with a repository source. A place it
  // never spoke for gets no button — and, so the page is never silent
  // under news it cannot act on, a note saying which of the two it is.
  it("withholds Update where the update read never spoke for this place", async () => {
    const host = await openWithUpdates([updateRow(HYPR)]);
    expect(updateButton(host)).toBeUndefined();
    expect(host.textContent).toContain(NO_UPDATE_STANDING_NOTE);
  });

  it("says the check is still running before the read lands", async () => {
    const host = await openWithUpdates([], { loaded: false });
    expect(updateButton(host)).toBeUndefined();
    expect(host.textContent).toContain(UPDATES_CHECKING);
  });

  // A first read that failed leaves the store looking exactly like one in
  // flight but for the error. Calling that a check in progress names a
  // cause that is not running.
  it("does not call a failed first read a check in progress", async () => {
    const host = await openWithUpdates([], {
      loaded: false,
      error: "no network",
    });
    expect(updateButton(host)).toBeUndefined();
    expect(note(host)).toBe(UPDATE_NEEDS_CHECK_HERE);
    expect(host.textContent).not.toContain(UPDATES_CHECKING);
  });

  // A failed re-read keeps its rows and drops `loaded`. The row is here
  // and withholds nothing of its own, so without the read state the page
  // would offer an Update over rows nobody could confirm.
  it("withholds Update over a row a failed re-read left standing", async () => {
    const host = await openWithUpdates(
      [{ ...updateRow(VG), updateAvailable: true }],
      { loaded: false, error: "no network" },
    );
    expect(updateButton(host)).toBeUndefined();
    expect(note(host)).toBe(UPDATE_NEEDS_CHECK_HERE);
  });

  // The invariant the page's own comments claim, asserted as the absence
  // of silence rather than as a sentence: wherever there is a newer
  // version and the page will not offer it, some reason is on screen. Not
  // pinned to a particular string, so rewording the copy cannot red this
  // for the wrong reason — the reason itself is the shared reading's.
  it("never withholds Update in silence, whatever the read is doing", async () => {
    const stale = { ...updateRow(VG), updateAvailable: true };
    for (const standing of [
      { loaded: false },
      { loaded: false, error: "no network" },
    ]) {
      const host = await openWithUpdates([stale], standing);
      expect(updateButton(host)).toBeUndefined();
      const said = host.textContent ?? "";
      const reason = pageUpdateWithheld(stale, {
        error: null,
        checking: false,
        overviewInFlight: false,
        pendingFollows: [],
        ...standing,
      });
      expect(reason).not.toBeNull();
      expect(said).toContain(reason as string);
    }
  });

  // Every window focus starts an overview read, and it is the app's
  // heaviest. Refusing on it would unmount Update on every alt-tab back,
  // guarding a hazard this surface has not got: its Update sends scope,
  // kind and name, and its versions come from its own read.
  it.each([{ checking: true }, { overviewInFlight: true }])(
    "still offers Update while a background read is in flight (%o)",
    async (inFlight) => {
      const host = await openWithUpdates(
        [{ ...updateRow(VG), updateAvailable: true }],
        inFlight,
      );
      expect(updateButton(host)).toBeDefined();
      expect(host.textContent).not.toContain(UPDATE_NEEDS_CHECK_HERE);
    },
  );

  // Where those flags do bear on this page: with no row for the place, a
  // read still running has not ruled it out, it has not reached it. Saying
  // the check has not spoken for the package claims a finished verdict.
  it.each([{ checking: true }, { overviewInFlight: true }])(
    "does not rule this place out while a read is running (%o)",
    async (inFlight) => {
      const host = await openWithUpdates([updateRow(HYPR)], inFlight);
      expect(updateButton(host)).toBeUndefined();
      expect(host.textContent).toContain(UPDATES_CHECKING);
      expect(host.textContent).not.toContain(NO_UPDATE_STANDING_NOTE);
    },
  );

  // A read-only diff of two commits the page already holds. No state of
  // the update read bears on it, so none of them may take it away.
  /** The note rendered where the button would be, read whole. The table's
   *  wording is this sentence plus a stale-versions tail, so a substring
   *  check would pass on either and the split this round made would go
   *  unguarded at the layer that renders it. */
  const note = (host: HTMLElement) =>
    host.querySelector("p.text-sm.text-muted-foreground")?.textContent;

  const preview = (host: HTMLElement) =>
    [...host.querySelectorAll("button")].find(
      (button) => button.textContent === PREVIEW_CHANGES_LABEL,
    );

  it("keeps Preview changes through every withheld state", async () => {
    for (const standing of [
      {},
      { loaded: false },
      { loaded: false, error: "no network" },
    ]) {
      const host = await openWithUpdates(
        [{ ...updateRow(VG), updateAvailable: true }],
        standing,
      );
      expect(preview(host)).toBeDefined();
    }
  });

  // A package already at its newest has one version, not two: latestRow is
  // rows[0] whatever it is, so on a current timeline it is the installed
  // row. Offering Preview there diffs a commit against itself, which
  // resolves to an empty comparison the reader has to close.
  it("offers no Preview when the only version is the installed one", async () => {
    const host = await openWithUpdates([updateRow(VG)], {
      versions: [version("a".repeat(40), true)],
    });
    expect(preview(host)).toBeUndefined();
  });
});
