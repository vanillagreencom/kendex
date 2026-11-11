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
import { rescansSettled, writingRepo } from "@/lib/rescan";
import { useAuditStore } from "@/stores/audit";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { usePackageReads } from "@/stores/package-reads";
import { useScanStore } from "@/stores/scan";
import { holdingBusy, useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";
import { placeRead } from "@/test/settings-read";
import { PackagePage } from "./package";

// The page is mounted against the real stores; only the backend is stubbed.
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
    auditAll: vi.fn(),
    // What the card's Update runs, and the two reads the store lands behind
    // it.
    packageUpdate: vi.fn(),
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    scanMachine: vi.fn(),
    marketplaceSummary: vi.fn(),
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
  summary: "about gh",
  action: null,
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
  filesMissing: false,
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
  support: { state: "read", unsupported: [], advisory: [], fallback: [] },
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
    data: {
      manifest: { schema: 1, install: {} },
      base: null,
      file: "kendex.toml",
    },
  });
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, ...placeRead, skills: [], base: null },
  });
  useAuditStore.setState({ views: [], auditedAt: null, read: READ_LANDED });
  // The page's reads outlive it, so a case would otherwise open on the
  // answers the case before it read.
  usePackageReads.setState({ answers: {} });
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
      summary: null,
      tags: null,
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
      readProjects: [],
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
  vi.mocked(commands.packageFile).mockImplementation((_s, _k, _n, path) =>
    Promise.resolve({
      status: "ok",
      data: {
        path,
        content: write.landed ? "PANE-AFTER" : "PANE-BEFORE",
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

// The Files tab holds the one read on this page that is not the page's own:
// the file a person picked. Its address is the package, which an update does
// not move, and the header's Update stays on screen while the tab is open —
// so without the tab starting over, the tree lists the new inventory beside
// the bytes of the copy that was replaced. The update is pressed from the
// header here and the tab never left, which is the only way to reach that
// state: moving to another tab and back unmounts the tab's content and
// starts its reads over whatever the page does.
describe("the package page's file pane after an update", () => {
  it("does not keep the replaced copy's bytes under a file that was picked", async () => {
    const write = engineWrites();
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
    const host = await openPage();
    await openTab(host, FILES_TAB);
    const row = [...host.querySelectorAll("button")].find(
      (one) => one.title === "BEFORE.md",
    );
    if (!row) throw new Error("no row for BEFORE.md");
    await act(async () => {
      row.click();
    });
    await settle();
    expect(host.textContent).toContain("PANE-BEFORE");

    const update = [
      ...(host.querySelector("header")?.querySelectorAll("button") ?? []),
    ].find((one) => one.textContent === UPDATE_LABEL);
    if (!update) throw new Error("no Update in the header");
    await act(async () => {
      update.click();
    });
    await settle();
    // The write rescans, so the join answers for that new scan the way the
    // app's own coordinator does. Until it does the page draws the note it
    // shows while that read is behind, which is what takes the tab and its
    // reads off screen across every write.
    await act(async () => {
      answerJoin();
    });

    expect(host.textContent).not.toContain("PANE-BEFORE");
    expect(host.textContent).toContain("READS-AFTER");
  });
});

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

// Leaving a package and coming back to its Files tab draws what the first
// visit read, and asks for none of it again while nothing has changed. Once
// something may have — the window came back, a write ran, whatever it
// answered, a fetch moved mirrors, the installed commit moved — the Files
// tab reads the package and its place again as it opens, whether the page
// was left or stood, and draws what is there now.
describe("coming back to the package page", () => {
  /** The page as the app holds it: mounted while the reader is on it, gone
   *  while they are anywhere else. */
  function Shell() {
    const page = useNavStore((s) => s.page);
    return page === "package" ? <PackagePage /> : null;
  }

  const PackageReads = [
    "packageMeta",
    "packageFiles",
    "packageReadme",
    "packageVersions",
  ] as const;
  const PlaceReads = [
    "getManifest",
    "getScopeSettings",
    "editorInventory",
  ] as const;
  const asked = (names: readonly (keyof typeof commands)[]) =>
    names.reduce(
      (sum, name) =>
        sum +
        (vi.mocked(commands[name]) as { mock: { calls: unknown[] } }).mock.calls
          .length,
      0,
    );

  const visit = async (host: HTMLElement) => {
    await act(async () => {
      useNavStore.setState({ page: "package" });
    });
    await act(async () => {
      answerJoin();
    });
    await openTab(host, FILES_TAB);
    return host.textContent ?? "";
  };

  /** Where the reader goes between the two visits: off the page, which
   *  unmounts it, or to its Overview, which keeps the page and its inputs
   *  standing and unmounts the Files tab alone. */
  const leave = async (host: HTMLElement, to: "page" | "tab") => {
    if (to === "tab") await openTab(host, OVERVIEW_TAB);
    else
      await act(async () => {
        useNavStore.setState({ page: "library" });
      });
  };

  /** The scan a rescan asks for, held unanswered until the case lets it go,
   *  so a read behind a later write queues behind it. */
  let releaseScan = () => {};
  const holdScan = () => {
    vi.mocked(commands.scanMachine).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          releaseScan = () => resolve(nothing);
        }),
    );
  };

  const rows: {
    name: string;
    /** Run before the first visit. */
    before?: () => Promise<void>;
    act: (write: { landed: boolean }) => Promise<void>;
    leaves?: "page" | "tab";
    /** What the pane opens on: the package's README, or with none its
     *  first file, which the pane reads itself. */
    opens?: "readme" | "first file";
    reads: "none" | "package" | "package and place";
  }[] = [
    { name: "nothing changed", act: async () => {}, reads: "none" },
    {
      name: "nothing changed, on a package with no README",
      act: async () => {},
      opens: "first file",
      reads: "none",
    },
    {
      name: "the window came back over an edit",
      act: async (write) => {
        write.landed = true;
        await useScanStore.getState().refresh();
      },
      reads: "package and place",
    },
    {
      name: "the window came back over an edit, on a package with no README",
      act: async (write) => {
        write.landed = true;
        await useScanStore.getState().refresh();
      },
      opens: "first file",
      reads: "package and place",
    },
    {
      // The page stands through it, and the installed commit and the
      // landed writes it reads on do not move: the tab asks as it opens.
      name: "the window came back over an edit while the page stayed open",
      act: async (write) => {
        write.landed = true;
        await useScanStore.getState().refresh();
      },
      leaves: "tab",
      reads: "package and place",
    },
    {
      name: "a write ran",
      act: async (write) => {
        await writingRepo(async () => {
          write.landed = true;
        });
        await rescansSettled();
      },
      reads: "package and place",
    },
    {
      // The read behind this write waits out the rescan already running,
      // which began before the first visit, so no scan request falls
      // between the visits: only the write's own end says what was kept is
      // gone.
      name: "a write ran and failed while a rescan was running",
      before: async () => {
        holdScan();
        await writingRepo(async () => {});
      },
      act: async (write) => {
        await writingRepo(async () => {
          write.landed = true;
          throw new Error("the write stopped");
        }).catch(() => undefined);
      },
      reads: "package and place",
    },
    {
      name: "an updates-store write ran without a rescan",
      act: async (write) => {
        await holdingBusy(async () => {
          write.landed = true;
        });
      },
      reads: "package and place",
    },
    {
      name: "a mirror fetch ran and failed",
      act: async (write) => {
        vi.mocked(commands.updatesRefresh).mockImplementation(() => {
          write.landed = true;
          return Promise.resolve({ status: "error", error: "offline" });
        });
        await useUpdatesStore.getState().check();
      },
      reads: "package and place",
    },
    {
      // Opening a repository nobody subscribes to fetches it, and that can
      // be the fetch this package's subscription was waiting for.
      name: "a repository page was opened",
      act: async (write) => {
        vi.mocked(commands.marketplaceSummary).mockImplementationOnce(() => {
          write.landed = true;
          return Promise.resolve({ status: "error", error: "offline" });
        });
        await useMarketplacesStore
          .getState()
          .loadSummary({ by: "repo", repo: "o/r" });
      },
      reads: "package and place",
    },
    {
      name: "the installed commit moved",
      act: async (write) => {
        write.landed = true;
        useUpdatesStore.setState({ rows: [rowAt(NEW, false)] });
      },
      reads: "package",
    },
  ];

  // A loop rather than `it.each`, whose titles cut a row's name short.
  for (const row of rows)
    it(row.name, async () => {
      const write = engineWrites();
      const firstFile = row.opens === "first file";
      if (firstFile)
        vi.mocked(commands.packageReadme).mockResolvedValue({
          status: "ok",
          data: null,
        });
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
      useScanStore.setState({
        result: {
          harnesses: [],
          items: [INSTALLED],
          missingProjects: [],
          readProjects: [],
          warnings: [],
        },
      });
      useNavStore.setState({
        page: "library",
        packageRef: {
          kind: "skill",
          name: "gh",
          scope: VG,
          identity: "recorded",
        },
        packageView: null,
      });
      const host = mount(<Shell />);
      await act(async () => {
        await row.before?.();
      });
      const first = await visit(host);
      // The pane opens on the README the page already read, or reads the
      // first file where there is none.
      expect(first).toContain(firstFile ? "PANE-BEFORE" : "READS-BEFORE");
      expect(vi.mocked(commands.packageReadme)).toHaveBeenCalledTimes(1);

      await leave(host, row.leaves ?? "page");
      await act(async () => {
        await row.act(write);
      });
      vi.clearAllMocks();
      const back = await visit(host);
      const moved = row.reads !== "none";
      const now = moved ? "AFTER" : "BEFORE";
      const counts = {
        package: asked(PackageReads),
        file: asked(["packageFile"]),
        place: asked(PlaceReads) > 0,
      };
      await act(async () => {
        releaseScan();
        await rescansSettled();
      });

      expect(
        {
          files: back.includes(`${now}.md`),
          pane: back.includes(firstFile ? `PANE-${now}` : `READS-${now}`),
          ...counts,
        },
        row.name,
      ).toEqual({
        files: true,
        pane: true,
        // Each of the four once; the pane's README is the page's own, and a
        // file it read is asked again only once the package was.
        package: moved ? 4 : 0,
        file: firstFile && moved ? 1 : 0,
        place: row.reads === "package and place",
      });
    });

  // A read that failed is that attempt's answer, drawn as it failed, and
  // the next visit asks again rather than keeping the failure. Failing for
  // the whole first visit: the Files tab asks again as it opens, too.
  it.each([
    { name: "the file list", fails: "packageFiles", shows: "BEFORE.md" },
    { name: "the pane's file", fails: "packageFile", shows: "PANE-BEFORE" },
  ] as const)(
    "asks again for $name when its read failed on the last visit",
    async (row) => {
      engineWrites();
      // With no README the pane opens on the first file and reads it.
      vi.mocked(commands.packageReadme).mockResolvedValue({
        status: "ok",
        data: null,
      });
      vi.mocked(commands[row.fails]).mockResolvedValue({
        status: "error",
        error: "REFUSED-BY-CORE",
      });
      useNavStore.setState({
        page: "library",
        packageRef: {
          kind: "skill",
          name: "gh",
          scope: VG,
          identity: "recorded",
        },
        packageView: null,
      });
      useScanStore.setState({
        result: {
          harnesses: [],
          items: [INSTALLED],
          missingProjects: [],
          readProjects: [],
          warnings: [],
        },
      });
      const host = mount(<Shell />);
      expect(await visit(host)).toContain("REFUSED-BY-CORE");
      await act(async () => {
        useNavStore.setState({ page: "library" });
      });
      engineWrites();
      vi.mocked(commands.packageReadme).mockResolvedValue({
        status: "ok",
        data: null,
      });
      vi.clearAllMocks();

      const back = await visit(host);

      expect(back).toContain(row.shows);
      expect(back).not.toContain("REFUSED-BY-CORE");
      expect(vi.mocked(commands[row.fails])).toHaveBeenCalledTimes(1);
    },
  );
});
