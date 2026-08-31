// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  type Mock,
  vi,
} from "vitest";
import type {
  HarnessId,
  ItemKind,
  ObservedItem,
  Origin,
  PackageMeta_Serialize,
  ProvenanceRow,
  Scope,
  UpdateRow,
  VersionRef,
} from "@/bindings";
import { commands } from "@/bindings";
import {
  PROJECTS_LOADING,
  REMOVE_ALL_LABEL,
  REMOVE_LABEL,
  UPDATE_ALL_LABEL,
} from "@/lib/copy-projects";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { PackageProjects } from "./package-projects";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: { packageMeta: vi.fn(), libraryProvenance: vi.fn() },
}));

const OURS: Origin = { origin: "marketplace", source: "cat", repo: "o/r" };

/** The join as the tab reads it: a row per place kendex owns. Vendor
 *  content carries no row at all, so a place left out here is one the
 *  tool ships. */
const ownedBy = (...owned: [Scope, Origin][]): ProvenanceRow[] =>
  owned.map(([scope, origin]) => ({
    scope,
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin,
  }));

/** One installation as the scan found it: a place holds one per harness,
 *  and removability is decided over all of them. */
const install = (
  scope: Scope,
  harness: HarnessId = "claude",
): ObservedItem => ({
  kind: "skill",
  name: "gh",
  harness,
  scope,
  path: `/x/${harness}`,
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
});

/** What the scan found in these places. */
const scanFound = (...items: ObservedItem[]) =>
  useScanStore.setState({
    result: {
      harnesses: [],
      items,
      missingProjects: [],
      warnings: [],
    },
  });

/** What the tab's own provenance read answers with. */
const joinSays = (rows: ProvenanceRow[]) =>
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: rows,
  });

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const NOW = Date.parse("2026-08-28T12:00:00Z");
const THREE_DAYS_AGO = "2026-08-25T12:00:00Z";

const meta = (installedAt: string | null): PackageMeta_Serialize => ({
  source: "cat",
  repo: "o/r",
  repoUrl: null,
  rev: null,
  current: null,
  installedAt,
  harnesses: ["claude"],
  enabled: true,
  fork: null,
  catalog: null,
});

const at = (commit: string): VersionRef => ({
  commit,
  label: null,
  date: null,
});

const row = (
  scope: Scope,
  updateAvailable: boolean,
  current: VersionRef | null = null,
): UpdateRow => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current,
  latest: null,
  updateAvailable,
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

// Each stand-in carries the signature it stands in for, so a store the
// tab reads through keeps its own type at the seam.
type RemoveItem = (
  scope: Scope,
  kind: ItemKind,
  name: string,
) => Promise<boolean>;

let removeItem: Mock<RemoveItem>;
let updateOne: Mock<(row: UpdateRow) => Promise<void>>;
let updateRows: Mock<(rows: UpdateRow[]) => Promise<void>>;
let onDelete: Mock<() => void>;

beforeEach(() => {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  removeItem = vi.fn<RemoveItem>().mockResolvedValue(true);
  updateOne = vi.fn<(row: UpdateRow) => Promise<void>>().mockResolvedValue();
  updateRows = vi
    .fn<(rows: UpdateRow[]) => Promise<void>>()
    .mockResolvedValue();
  onDelete = vi.fn<() => void>();
  useAuditStore.setState({ removeItem, busy: false });
  useUpdatesStore.setState({
    rows: [],
    read: READ_LANDED,
    checking: false,
    pendingFollows: [],
    updateOne,
    updateRows,
  });
  useProvenanceStore.setState({ rows: [], loaded: false });
  joinSays(ownedBy([VG, OURS], [HYPR, OURS]));
  scanFound(install(VG), install(HYPR));
  vi.mocked(commands.packageMeta).mockImplementation((scope) =>
    Promise.resolve({
      status: "ok",
      data: meta(scopeKey(scope) === scopeKey(VG) ? THREE_DAYS_AGO : null),
    }),
  );
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** The tab about `gh`, installed in `scopes`, with its places read. */
const openTab = async (scopes: Scope[]) => {
  const host = mount(
    <PackageProjects
      kind="skill"
      name="gh"
      scopes={scopes}
      busy={false}
      onDelete={onDelete}
    />,
  );
  await settle();
  return host;
};

const buttons = (host: HTMLElement) =>
  Array.from(host.querySelectorAll("button"));

const click = async (host: HTMLElement, label: string, nth = 0) => {
  const found = buttons(host).filter((one) => one.textContent === label)[nth];
  if (!found) throw new Error(`no "${label}" button at index ${nth}`);
  await userEvent.click(found);
};

describe("the Projects tab", () => {
  it("says it is reading before any place has answered", () => {
    const host = mount(
      <PackageProjects
        kind="skill"
        name="gh"
        scopes={[VG]}
        busy={false}
        onDelete={onDelete}
      />,
    );
    expect(
      host.querySelector('[role="status"]')?.getAttribute("aria-label"),
    ).toBe(PROJECTS_LOADING);
  });

  it("draws a card per place, naming it and dating the copy", async () => {
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("vg");
    expect(host.textContent).toContain("/work/vg");
    expect(host.textContent).toContain("Installed 3d ago");
    expect(host.textContent).toContain("hyprtrade");
  });

  // A date nobody recorded is not a date to invent, and the card still has
  // to draw: the package is installed there either way.
  it("draws a place whose record carries no date", async () => {
    const host = await openTab([HYPR]);

    expect(host.textContent).toContain("hyprtrade");
    // "Installed in" is the section's own heading; no card dates itself.
    expect(host.textContent).not.toMatch(/Installed \d/);
  });
});

describe("the update a place is waiting for", () => {
  it("carries Update only on the place waiting for one", async () => {
    useUpdatesStore.setState({ rows: [row(VG, true), row(HYPR, false)] });
    const host = await openTab([VG, HYPR]);

    expect(
      buttons(host).filter((one) => one.textContent === "Update"),
    ).toHaveLength(1);
    await click(host, "Update");
    expect(updateOne).toHaveBeenCalledWith(
      expect.objectContaining({ scope: VG }),
    );
  });

  it("offers Update all while a place is waiting, and hands it that place", async () => {
    useUpdatesStore.setState({ rows: [row(VG, true), row(HYPR, false)] });
    const host = await openTab([VG, HYPR]);

    await click(host, UPDATE_ALL_LABEL);
    expect(updateRows).toHaveBeenCalledWith([
      expect.objectContaining({ scope: VG }),
    ]);
  });

  // The store keeps the last-known rows through a failed or running read
  // and refuses every update over them, saying so. A card that read those
  // rows alone would offer a button whose only outcome is that error.
  it("offers nothing while the update read has failed", async () => {
    useUpdatesStore.setState({
      rows: [row(VG, true), row(HYPR, true)],
      read: readFailed("the read failed"),
    });
    const host = await openTab([VG, HYPR]);

    expect(buttons(host).filter((one) => one.textContent === "Update")).toEqual(
      [],
    );
    expect(host.textContent).not.toContain(UPDATE_ALL_LABEL);
  });

  it("offers nothing while a check is running", async () => {
    useUpdatesStore.setState({
      rows: [row(VG, true), row(HYPR, true)],
      checking: true,
    });
    const host = await openTab([VG, HYPR]);

    expect(buttons(host).filter((one) => one.textContent === "Update")).toEqual(
      [],
    );
    expect(host.textContent).not.toContain(UPDATE_ALL_LABEL);
  });

  // Every card still draws while the rows are held: the package is
  // installed in those places whatever the update read is doing.
  it("still draws the cards while the rows are held", async () => {
    useUpdatesStore.setState({ rows: [row(VG, true)], checking: true });
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("vg");
    expect(host.textContent).toContain("hyprtrade");
    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toHaveLength(2);
  });

  it("offers no Update all while nothing is waiting", async () => {
    useUpdatesStore.setState({ rows: [row(VG, false), row(HYPR, false)] });
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).not.toContain(UPDATE_ALL_LABEL);
  });
});

// Core stamps a new install date whenever the source hash moves, and that
// date lives only in each place's own record. A tab that read the records
// once would keep showing the age of the copy the update replaced.
describe("the date a place shows after an update lands", () => {
  const A_DAY_AGO = "2026-08-27T12:00:00Z";

  it("follows the copy, not the read that drew the card", async () => {
    useUpdatesStore.setState({ rows: [row(VG, true, at("aaa"))] });
    const host = await openTab([VG]);
    expect(host.textContent).toContain("Installed 3d ago");

    await click(host, "Update");

    // What a landed update leaves behind: the place is on a new commit and
    // its record carries the date core stamped when the hash moved.
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: meta(A_DAY_AGO),
    });
    await act(async () => {
      useUpdatesStore.setState({ rows: [row(VG, false, at("bbb"))] });
    });
    await settle();

    expect(host.textContent).toContain("Installed 1d ago");
    expect(host.textContent).not.toContain("Installed 3d ago");
  });

  // A store touch that leaves the copies where they are must not put a
  // request behind every unrelated updates change.
  it("does not re-read the records when the copies have not moved", async () => {
    useUpdatesStore.setState({ rows: [row(VG, true, at("aaa"))] });
    const host = await openTab([VG]);
    const reads = vi.mocked(commands.packageMeta).mock.calls.length;

    await act(async () => {
      useUpdatesStore.setState({ checking: true });
    });
    await settle();

    expect(vi.mocked(commands.packageMeta).mock.calls).toHaveLength(reads);
    expect(host.textContent).toContain("Installed 3d ago");
  });
});

// `removeItem` removes what the manifest declares and what the lock owns,
// and deliberately cannot delete a file kendex only observed. A Remove on
// one of those advertises an action it cannot perform.
describe("a place kendex does not own", () => {
  it("draws its card without Remove", async () => {
    joinSays(ownedBy([VG, OURS]));
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("hyprtrade");
    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toHaveLength(1);
    await click(host, REMOVE_LABEL);
    expect(removeItem).toHaveBeenCalledWith(VG, "skill", "gh");
  });

  it("keeps Remove on the place it does own", async () => {
    joinSays(ownedBy([VG, OURS], [HYPR, OURS]));
    const host = await openTab([VG, HYPR]);

    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toHaveLength(2);
  });

  // A copy the scan only observed says so in the join; content the tool
  // ships carries no row at all. Neither is kendex's to remove.
  it("offers no Remove over a copy it only observed", async () => {
    joinSays(
      ownedBy([VG, { origin: "unmanaged" }], [HYPR, { origin: "unmanaged" }]),
    );
    const host = await openTab([VG, HYPR]);

    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toEqual([]);
  });

  it("offers no Remove over content the tool ships", async () => {
    joinSays([]);
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("vg");
    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toEqual([]);
  });

  // Held to the same judge as the cards: with nothing here kendex owns,
  // the link has no removal to ask for.
  it("drops Remove all when it owns none of the places", async () => {
    joinSays([]);
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).not.toContain(REMOVE_ALL_LABEL);
  });

  it("keeps Remove all while it owns one of them", async () => {
    joinSays(ownedBy([VG, OURS]));
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain(REMOVE_ALL_LABEL);
  });

  // A place holds one copy per harness and the join answers per harness.
  // Removing takes the declaration it finds and leaves the other copy, so
  // a place is only ours when every one of its copies is.
  it("offers no Remove where one of a place's harnesses is not ours", async () => {
    scanFound(install(VG, "claude"), install(VG, "codex"));
    joinSays(ownedBy([VG, OURS]));
    const host = await openTab([VG]);

    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toEqual([]);
  });

  it("keeps Remove where every one of a place's harnesses is ours", async () => {
    scanFound(install(VG, "claude"), install(VG, "codex"));
    joinSays([
      ...ownedBy([VG, OURS]),
      { scope: VG, kind: "skill", name: "gh", harness: "codex", origin: OURS },
    ]);
    const host = await openTab([VG]);

    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toHaveLength(1);
  });

  // The store keeps its older rows when the read fails, and those say
  // nothing about who owns these copies now. A destructive control drawn
  // from them is the fail-open case: it stays closed instead.
  it("offers no Remove when the ownership read fails", async () => {
    useProvenanceStore.setState({
      rows: ownedBy([VG, OURS], [HYPR, OURS]),
      loaded: true,
    });
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "error",
      error: "the join did not read",
    });
    const host = await openTab([VG, HYPR]);

    // The cards still draw: the package is installed there either way.
    expect(host.textContent).toContain("vg");
    expect(host.textContent).toContain("hyprtrade");
    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toEqual([]);
    expect(host.textContent).not.toContain(REMOVE_ALL_LABEL);
  });

  it("offers no Remove when the ownership read never answers", async () => {
    useProvenanceStore.setState({
      rows: ownedBy([VG, OURS], [HYPR, OURS]),
      loaded: true,
    });
    vi.mocked(commands.libraryProvenance).mockRejectedValue(
      new Error("the channel is gone"),
    );
    const host = await openTab([VG, HYPR]);

    expect(
      buttons(host).filter((one) => one.textContent === REMOVE_LABEL),
    ).toEqual([]);
  });
});

// An age label that froze at mount reads as a fact. The tab is a surface
// people leave open, so the card takes the shared clock every other age on
// screen takes rather than the moment it happened to render.
describe("the age a card shows as time passes", () => {
  it("follows the clock rather than the render that drew it", async () => {
    // Fake timers take Date over, so the clock the card reads and the
    // clock its tick runs on are the same one from here.
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    try {
      const host = await openTab([VG]);
      expect(host.textContent).toContain("Installed 3d ago");

      // Two days pass with the tab open and nothing else touching it.
      await act(async () => {
        vi.advanceTimersByTime(2 * 24 * 60 * 60 * 1000);
      });

      expect(host.textContent).toContain("Installed 5d ago");
      expect(host.textContent).not.toContain("Installed 3d ago");
    } finally {
      vi.useRealTimers();
    }
  });
});

// The generated command wrapper rethrows a transport failure rather than
// answering with an error status, so one unreachable place must not take
// the whole read with it.
describe("a place whose record could not be read", () => {
  it("draws every other place and stops loading", async () => {
    vi.mocked(commands.packageMeta).mockImplementation((scope) =>
      scopeKey(scope) === scopeKey(VG)
        ? Promise.reject(new Error("the channel is gone"))
        : Promise.resolve({ status: "ok", data: meta(THREE_DAYS_AGO) }),
    );
    const host = await openTab([VG, HYPR]);

    expect(host.querySelector('[role="status"]')).toBeNull();
    expect(host.textContent).toContain("hyprtrade");
    expect(host.textContent).toContain("Installed 3d ago");
  });

  // The place is installed there whatever the read managed to say, so it
  // keeps its card and loses only the date.
  it("keeps the unreachable place, dateless", async () => {
    vi.mocked(commands.packageMeta).mockRejectedValue(
      new Error("the channel is gone"),
    );
    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("vg");
    expect(host.textContent).toContain("hyprtrade");
    expect(host.textContent).not.toMatch(/Installed \d/);
  });
});

describe("removing a package from one place", () => {
  it("reaches that place alone", async () => {
    const host = await openTab([VG, HYPR]);

    await click(host, REMOVE_LABEL, 1);
    expect(removeItem).toHaveBeenCalledTimes(1);
    expect(removeItem).toHaveBeenCalledWith(HYPR, "skill", "gh");
  });

  // Deleting every copy is one decision about the package, and the dialog
  // is where it is confirmed — this link asks for it, it never runs it.
  it("leaves the whole-package deletion to the dialog", async () => {
    const host = await openTab([VG, HYPR]);

    await click(host, REMOVE_ALL_LABEL);
    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(removeItem).not.toHaveBeenCalled();
  });
});
