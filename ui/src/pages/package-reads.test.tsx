// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  ScanResult,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_LABEL } from "@/lib/copy";
import { OVERVIEW_TAB } from "@/lib/copy-customize";
import { PROJECTS_TAB, updateInLabel } from "@/lib/copy-projects";
import { PACKAGE_READ_FAILED } from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { settle } from "@/test/dom";
import {
  header,
  movedRow,
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
    // What an update started from the Projects tab runs, and the two reads
    // the store lands behind it.
    packageUpdate: vi.fn(),
    updatesOverview: vi.fn(),
    scanMachine: vi.fn(),
    // The page's safety tab asks for a fresh audit as it mounts.
    auditAll: vi.fn(),
  },
}));

beforeEach(() => {
  resetPage();
  // The three commands this file adds to the mock are reset with it, for
  // the reason resetPage states for the audit: clearAllMocks leaves
  // implementations standing, and the update tests below hand these a
  // closure that answers as if an update had landed — which it would go on
  // answering for every test after them.
  vi.mocked(commands.packageUpdate).mockReset();
  vi.mocked(commands.updatesOverview).mockReset();
  vi.mocked(commands.scanMachine).mockReset();
});

/** A timeline with a newer version to move to. */
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

// Reads of one package overlap on every ordinary path: a focus reload moves
// the commit under a mount, a move to another package leaves the first one's
// reads out. The header's Update turns on how those reads went, so an older
// landing does not merely draw stale files — it hides the button with a
// reason that has already been answered. All three landings are gated, so
// all three are asked.
describe("a package read that lands after a newer one began", () => {
  /** A promise the test answers when it chooses, for a command's first call;
   *  every call after it takes the mock's standing answer. */
  const heldOpen = <T,>(): [Promise<T>, (value: T) => void] => {
    let answer: (value: T) => void = () => {};
    const held = new Promise<T>((resolve) => {
      answer = resolve;
    });
    return [held, (value) => answer(value)];
  };

  /** What a landed update leaves behind: a new commit under the same place,
   *  which is what begins the page's second load. */
  const moveCommit = async () => {
    await act(async () => {
      useUpdatesStore.setState({ rows: [movedRow()] });
    });
    await settle();
  };

  const landStale = async (answer: () => void) => {
    await act(async () => {
      answer();
    });
    await settle();
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [updateRow(VG)] });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
  });

  it("does not let a stale timeline hide the button it just offered", async () => {
    const [held, answer] =
      heldOpen<Awaited<ReturnType<typeof commands.packageVersions>>>();
    vi.mocked(commands.packageVersions).mockImplementationOnce(() => held);

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    await moveCommit();
    expect(header(host)).toContain(UPDATE_LABEL);

    await landStale(() =>
      answer({ status: "error", error: "the mirror is gone" }),
    );

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(header(host)).toContain(UPDATE_LABEL);
  });

  it("does not let a stale record hide the button it just offered", async () => {
    const [held, answer] =
      heldOpen<Awaited<ReturnType<typeof commands.packageMeta>>>();
    vi.mocked(commands.packageMeta).mockImplementationOnce(() => held);

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    await moveCommit();
    expect(header(host)).toContain(UPDATE_LABEL);

    await landStale(() =>
      answer({ status: "error", error: "the manifest is unreadable" }),
    );

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(header(host)).toContain(UPDATE_LABEL);
  });

  it("does not let a stale file list replace the one on screen", async () => {
    const [held, answer] =
      heldOpen<Awaited<ReturnType<typeof commands.packageFiles>>>();
    vi.mocked(commands.packageFiles)
      .mockImplementationOnce(() => held)
      .mockResolvedValue({
        status: "ok",
        data: [{ path: "AFTER.md", size: 10, isReadme: false }],
      });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    await moveCommit();
    expect(host.textContent).toContain("AFTER.md");

    await landStale(() =>
      answer({
        status: "ok",
        data: [{ path: "BEFORE.md", size: 10, isReadme: false }],
      }),
    );

    expect(host.textContent).toContain("AFTER.md");
    expect(host.textContent).not.toContain("BEFORE.md");
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
