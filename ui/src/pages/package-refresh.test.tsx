// @vitest-environment jsdom
// What an update started from the package page leaves behind. The Projects
// tab's Update commits through the updates store, which refreshes the scan
// and the audit and knows nothing about this page's own four reads: its
// card follows the landed commit, and the Overview and the header must not
// go on describing the copy the update replaced — its README included,
// which is the Overview.
//
// One control, and the fixture it needs. The page's other tests are
// `package.test.tsx`'s.
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView_Serialize,
  ObservedItem,
  PackageMeta_Serialize,
  ScanResult,
  Scope,
  UpdateRow,
  VersionRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_LABEL } from "@/lib/copy";
import { OVERVIEW_TAB } from "@/lib/copy-customize";
import { FILES_TAB } from "@/lib/copy-files";
import { PROJECTS_TAB, updateInLabel } from "@/lib/copy-projects";
import { UPDATES_CHECKING } from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";
import { PackagePage } from "./package";

// The page is mounted against the real stores; only the backend is stubbed.
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
    // What the card's Update runs, and the two reads the store lands behind
    // it.
    packageUpdate: vi.fn(),
    updatesOverview: vi.fn(),
    scanMachine: vi.fn(),
  },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };
const OLD = "a".repeat(40);
const NEW = "b".repeat(40);

const nothing = { status: "error" as const, error: "not in this test" };

/** gh as the scan found it, in the one place this page is about. */
const INSTALLED: ObservedItem = observed({
  kind: "skill",
  name: "gh",
  scope: VG,
  harness: "claude",
  path: "/work/vg/.claude/skills/gh",
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
  modifiedAt: null,
  vendor: null,
});

/** This place's row: the commit installed there, and whether the check found
 *  something newer waiting for it. */
const rowAt = (commit: string, waiting: boolean): UpdateRow => ({
  scope: VG,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: { commit, label: null, date: null },
  latest: waiting ? { commit: NEW, label: null, date: null } : null,
  updateAvailable: waiting,
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

/** The place's own record: a following package with nothing held. */
const RECORD: PackageMeta_Serialize = {
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

/** The scope view an apply answers with: it wrote, and there is nothing else
 *  to say about the place. */
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

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.packageReadme).mockResolvedValue(nothing);
  vi.mocked(commands.editorInventory).mockResolvedValue(nothing);
  vi.mocked(commands.libraryProvenance).mockResolvedValue(nothing);
  vi.mocked(commands.packageDiff).mockResolvedValue(nothing);
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: { schema: 1, install: {} }, base: null },
  });
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, skills: [], base: null },
  });
  useAuditStore.setState({ views: [], auditedAt: null, read: READ_LANDED });
  // Reset with the rest: `checking` is what one case below turns on, and a
  // store touch merges, so it would still be on under the other.
  useUpdatesStore.setState({
    rows: [],
    read: READ_LANDED,
    checking: false,
  });
});

/** The join answering about the scan now on screen: this installation is
 *  the declared package, which is the identity the page's ref carries. In
 *  the app the post-scan coordinator does this; here the test says it,
 *  including after a write publishes a new scan. */
const answerJoin = () =>
  joinAnswered([
    {
      scope: VG,
      kind: INSTALLED.kind,
      name: INSTALLED.name,
      harness: INSTALLED.harness,
      at: INSTALLED.path,
      origin: { origin: "marketplace", source: "cat", repo: "o/r" },
      package: { kind: INSTALLED.kind, name: INSTALLED.name },
    },
  ]);

/** The page open on gh in vg, with the scan holding the one installation. */
const openPage = async () => {
  useScanStore.setState({
    result: {
      harnesses: [],
      items: [INSTALLED],
      missingProjects: [],
      warnings: [],
    },
  });
  answerJoin();
  useNavStore.setState({
    page: "package",
    packageRef: { kind: "skill", name: "gh", scope: VG, identity: "recorded" },
    packageView: null,
  });
  const host = mount(<PackagePage />);
  await settle();
  return host;
};

const header = (host: HTMLElement) => host.querySelector("header")?.textContent;

const openTab = async (host: HTMLElement, name: string) => {
  const found = [...host.querySelectorAll('[data-slot="tabs-trigger"]')].find(
    (trigger) => trigger.textContent === name,
  );
  if (!found) throw new Error(`no ${name} tab`);
  await act(async () => {
    (found as HTMLElement).click();
  });
  await settle();
};

// A check runs on every return to the window, and the row it will replace is
// still the truth about this place until it lands. The page keeps Update on
// screen through one and disables it; swapping it for the checking note takes
// the control away and says the check has not spoken for a place it has.
describe("the package page while a check is running", () => {
  it("keeps the Update its landed row offers", async () => {
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: [version(NEW, "v2", false), version(OLD, "v1", true)],
    });
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "ok",
      data: [{ path: "SKILL.md", size: 10, isReadme: false }],
    });
    useUpdatesStore.setState({
      rows: [rowAt(OLD, true)],
      read: READ_LANDED,
      checking: true,
    });

    const host = await openPage();

    expect(header(host)).toContain(UPDATE_LABEL);
    expect(header(host)).not.toContain(UPDATES_CHECKING);
  });
});

/** The engine before and after the apply lands: core stamps the whole
 *  installation when the source hash moves, so the record, the timeline,
 *  the files and the README move together. The standing read behind the
 *  write is the caller's, since that is what the two cases differ on. */
const engineWrites = () => {
  const write = { landed: false };
  vi.mocked(commands.packageMeta).mockResolvedValue({
    status: "ok",
    data: RECORD,
  });
  vi.mocked(commands.packageVersions).mockImplementation(() =>
    Promise.resolve({
      status: "ok",
      data: write.landed
        ? [version(NEW, "v2", true)]
        : [version(NEW, "v2", false), version(OLD, "v1", true)],
    }),
  );
  vi.mocked(commands.packageFiles).mockImplementation(() =>
    Promise.resolve({
      status: "ok",
      data: [
        {
          path: write.landed ? "AFTER.md" : "BEFORE.md",
          size: 10,
          isReadme: false,
        },
      ],
    }),
  );
  vi.mocked(commands.packageReadme).mockImplementation(() =>
    Promise.resolve({
      status: "ok",
      data: {
        path: "SKILL.md",
        content: write.landed ? "READS-AFTER" : "READS-BEFORE",
        truncated: false,
      },
    }),
  );
  vi.mocked(commands.packageUpdate).mockImplementation(() => {
    write.landed = true;
    return Promise.resolve({
      status: "ok",
      data: { view: APPLIED, heldBack: [], removed: [], moved: [] },
    });
  });
  // The rescan behind the apply finds the same machine: the package is
  // installed where it was, so the page stays on screen.
  vi.mocked(commands.scanMachine).mockImplementation(() =>
    Promise.resolve({
      status: "ok",
      data: useScanStore.getState().result as ScanResult,
    }),
  );
  useUpdatesStore.setState({ rows: [rowAt(OLD, true)], read: READ_LANDED });
  return write;
};

/** The card's Update, pressed, with the Overview back on screen after. */
const pressUpdate = async (host: HTMLElement) => {
  await openTab(host, PROJECTS_TAB);
  const update = [...host.querySelectorAll("button")].find(
    (one) => one.getAttribute("aria-label") === updateInLabel("vg"),
  );
  if (!update) throw new Error("no Update on the vg card");
  await act(async () => {
    update.click();
  });
  await settle();
  // The write rescans, so the join answers for that new scan the way the
  // app's own coordinator does.
  await act(async () => {
    answerJoin();
  });
  await openTab(host, OVERVIEW_TAB);
};

/** What the page says across the two tabs these reads feed: the version and
 *  the README on the Overview, the files on Files. One string, so a row
 *  names what changed without having to name which tab said it. Leaves the
 *  page back on the Overview, where it opened. */
const readsOn = async (host: HTMLElement) => {
  const overview = host.textContent ?? "";
  await openTab(host, FILES_TAB);
  const files = host.textContent ?? "";
  await openTab(host, OVERVIEW_TAB);
  return `${overview}\n${files}`;
};

describe("the package page after an update started from its Projects tab", () => {
  const outcomes = [
    {
      name: "re-reads its files, its README, its version and its update offer",
      outcome: "ok",
      before: ["BEFORE.md", "READS-BEFORE", "v1"],
      after: ["AFTER.md", "READS-AFTER", "v2"],
      absent: ["BEFORE.md", "READS-BEFORE", "v1"],
      update: true,
    },
    {
      name: "re-reads them when the write answers an error",
      outcome: "write-error",
      before: ["BEFORE.md", "READS-BEFORE"],
      after: ["AFTER.md", "READS-AFTER", "v2"],
      absent: ["BEFORE.md", "READS-BEFORE"],
      update: false,
    },
    {
      name: "re-reads them when the read behind the write fails",
      outcome: "read-error",
      before: ["BEFORE.md", "READS-BEFORE", "v1"],
      after: ["AFTER.md", "READS-AFTER", "v2"],
      absent: ["BEFORE.md", "READS-BEFORE", "v1"],
      update: false,
    },
  ];
  expect(outcomes).toHaveLength(3);
  it.each(outcomes)("$name", async (row) => {
    const write = engineWrites();
    if (row.outcome === "write-error") {
      vi.mocked(commands.packageUpdate).mockImplementation(() => {
        write.landed = true;
        return Promise.resolve({ status: "error", error: "the apply stopped" });
      });
      vi.mocked(commands.updatesOverview).mockResolvedValue({
        status: "ok",
        data: {
          rows: [rowAt(OLD, true)],
          warnings: [],
          unreadable: [],
          lastFetched: null,
        },
      });
    } else if (row.outcome === "read-error") {
      vi.mocked(commands.updatesOverview).mockRejectedValue(
        new Error("overview wedged"),
      );
    } else {
      vi.mocked(commands.updatesOverview).mockImplementation(() =>
        Promise.resolve({
          status: "ok",
          data: {
            rows: [rowAt(write.landed ? NEW : OLD, !write.landed)],
            warnings: [],
            unreadable: [],
            lastFetched: null,
          },
        }),
      );
    }
    const host = await openPage();
    const before = await readsOn(host);
    const updateBefore = header(host)?.includes(UPDATE_LABEL);
    await pressUpdate(host);
    const after = await readsOn(host);
    expect(
      {
        before: row.before.filter((value) => before.includes(value)),
        after: row.after.filter((value) => after.includes(value)),
        absent: row.absent.filter((value) => after.includes(value)),
        updateBefore: row.update ? updateBefore : null,
        updateAfter: row.update ? header(host)?.includes(UPDATE_LABEL) : null,
      },
      row.name,
    ).toEqual({
      before: row.before,
      after: row.after,
      absent: [],
      updateBefore: row.update ? true : null,
      updateAfter: row.update ? false : null,
    });
  });
});
