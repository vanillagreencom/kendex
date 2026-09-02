// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  ItemKind,
  ScanResult,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_LABEL } from "@/lib/copy";
import { OVERVIEW_TAB } from "@/lib/copy-customize";
import { PROJECTS_TAB, updateInLabel } from "@/lib/copy-projects";
import {
  EDITED_CANT_UPDATE_NOTE,
  NO_UPDATE_STANDING_NOTE,
  PACKAGE_READ_FAILED,
  packageReadFailedNote,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { settle } from "@/test/dom";
import {
  header,
  openPage,
  PLAIN,
  RECORD,
  resetPage,
  updateRow,
  VG,
} from "@/test/package-page";

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
    // What an update started from the Projects tab runs, and the two reads
    // the store lands behind it.
    packageUpdate: vi.fn(),
    updatesOverview: vi.fn(),
    scanMachine: vi.fn(),
  },
}));

beforeEach(resetPage);

/** A timeline with a newer version to move to, which is what puts a note
 *  where the button would have been. */
const TIMELINE: VersionRow[] = [
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
      data: TIMELINE,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
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

// The page's own three reads are not the update check, and a failure in
// either of the two Update rests on leaves the header with no button and
// no Preview. Silence there is a page that refuses without saying why, and
// the update read's own notes would name the wrong cause for it.
describe("what the package page says when its own reads fail", () => {
  // A timeline with something newer on it, so the update read has its own
  // say to be outranked: the record is what did not read, and the note
  // that names a check nobody needs points at the wrong thing.
  it("names the record read over the update check's own note", async () => {
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "error",
      error: "the manifest is unreadable",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain(
      packageReadFailedNote("the manifest is unreadable"),
    );
    expect(host.textContent).not.toContain(NO_UPDATE_STANDING_NOTE);
    expect(header(host)).not.toContain(UPDATE_LABEL);
  });

  // A timeline that did not read has no newer version on it, so every note
  // keyed on one is silent — which is how this page came to show an empty
  // action bar and nothing else.
  it("names the timeline read, which no note keyed on newness reaches", async () => {
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "error",
      error: "the mirror is gone",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain(
      packageReadFailedNote("the mirror is gone"),
    );
    expect(header(host)).not.toContain(UPDATE_LABEL);
  });

  // Both reads landed, so nothing the page itself read withholds anything
  // and the update read has the say it always had. Without this the two
  // above would pass over a page that said the same thing whatever
  // happened.
  it("says nothing of its own when both reads land", async () => {
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(host.textContent).toContain(NO_UPDATE_STANDING_NOTE);
  });
});

// An update started from the Projects tab commits through the updates
// store, which knows nothing about this page's own reads. The card's
// install date was made to follow the commit in #1799; the Overview and the
// header went on describing the copy the update replaced.
describe("the package page after an update started from its Projects tab", () => {
  const OLD = "a".repeat(40);
  const NEW = "b".repeat(40);

  const version = (
    id: string,
    label: string,
    installed: boolean,
  ): VersionRow => ({
    id,
    label,
    date: "2026-08-28T12:00:00Z",
    summary: "release notes",
    installed,
    newerThanInstalled: !installed,
  });

  /** This place's row: the commit installed there, and whether the check
   *  found something newer waiting for it. */
  const rowAt = (commit: string, waiting: boolean): UpdateRow => ({
    ...updateRow(VG),
    current: { commit, label: null, date: null },
    latest: waiting ? { commit: NEW, label: null, date: null } : null,
    updateAvailable: waiting,
  });

  /** The scope view an apply answers with: it wrote, and there is nothing
   *  else to say about the place. */
  const APPLIED: AuditView_Serialize = {
    scope: VG,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  };

  const tabNamed = async (host: HTMLElement, name: string) => {
    const found = [...host.querySelectorAll('[data-slot="tabs-trigger"]')].find(
      (trigger) => trigger.textContent === name,
    );
    if (!found) throw new Error(`no ${name} tab`);
    await act(async () => {
      (found as HTMLElement).click();
    });
    await settle();
  };

  const spoken = (host: HTMLElement, label: string) => {
    const found = [...host.querySelectorAll("button")].find(
      (one) => one.getAttribute("aria-label") === label,
    );
    if (!found) throw new Error(`no button called "${label}"`);
    return found;
  };

  it("re-reads its files, its version and its update offer", async () => {
    // What the engine answers before and after the apply lands. The place's
    // record, its timeline and its files all move together, because core
    // stamps the whole installation when the source hash moves.
    let landed = false;
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockImplementation(() =>
      Promise.resolve({
        status: "ok",
        data: landed
          ? [version(NEW, "v2", true)]
          : [version(NEW, "v2", false), version(OLD, "v1", true)],
      }),
    );
    vi.mocked(commands.packageFiles).mockImplementation(() =>
      Promise.resolve({
        status: "ok",
        data: [
          {
            path: landed ? "AFTER.md" : "BEFORE.md",
            size: 10,
            isReadme: false,
          },
        ],
      }),
    );
    vi.mocked(commands.packageUpdate).mockImplementation(() => {
      landed = true;
      return Promise.resolve({
        status: "ok",
        data: { view: APPLIED, heldBack: [], removed: [], moved: [] },
      });
    });
    // The standing read the store lands behind its own apply.
    vi.mocked(commands.updatesOverview).mockImplementation(() =>
      Promise.resolve({
        status: "ok",
        data: {
          rows: [rowAt(landed ? NEW : OLD, !landed)],
          warnings: [],
          unreadable: [],
          lastFetched: null,
        },
      }),
    );
    // The rescan behind the apply finds the same machine: the package is
    // installed where it was, so the page stays on screen.
    vi.mocked(commands.scanMachine).mockImplementation(() =>
      Promise.resolve({
        status: "ok",
        data: useScanStore.getState().result as ScanResult,
      }),
    );
    useUpdatesStore.setState({ rows: [rowAt(OLD, true)], read: READ_LANDED });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    expect(host.textContent).toContain("BEFORE.md");
    expect(host.textContent).toContain("v1");
    expect(header(host)).toContain(UPDATE_LABEL);

    await tabNamed(host, PROJECTS_TAB);
    await act(async () => {
      spoken(host, updateInLabel("vg")).click();
    });
    await settle();
    await tabNamed(host, OVERVIEW_TAB);

    expect(host.textContent).toContain("AFTER.md");
    expect(host.textContent).not.toContain("BEFORE.md");
    expect(host.textContent).toContain("v2");
    expect(host.textContent).not.toContain("v1");
    expect(header(host)).not.toContain(UPDATE_LABEL);
  });

  // The re-read is keyed on the commit installed here for that reason: an
  // updates-store touch that moves nothing must not put three requests
  // behind it.
  it("does not read again when the commit has not moved", async () => {
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    useUpdatesStore.setState({ rows: [rowAt(OLD, true)], read: READ_LANDED });
    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    const reads = vi.mocked(commands.packageMeta).mock.calls.length;

    await act(async () => {
      useUpdatesStore.setState({ checking: true });
    });
    await settle();

    expect(vi.mocked(commands.packageMeta).mock.calls).toHaveLength(reads);
    expect(host.querySelector("header")).not.toBeNull();
  });
});
