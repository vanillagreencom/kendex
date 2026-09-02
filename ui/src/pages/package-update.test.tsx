// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ItemKind, UpdateRow, VersionRow } from "@/bindings";
import { commands } from "@/bindings";
import {
  PREVIEW_CHANGES_LABEL,
  TRY_AGAIN_LABEL,
  UPDATE_LABEL,
} from "@/lib/copy";
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

/** A refusal core sent on the row. Pass-through is the whole property, so
 *  this is a string core would never send: core's own wording here would
 *  read as a cross-boundary pin and be none, since the equality asserted is
 *  fixture against rendered note. */
const NO_PER_PACKAGE = "REFUSED-BY-CORE: this kind moves another way";

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
// string, and this block is the update read's half of it. What that read
// says about the package — the kind's refusal, the row's own reasons, a
// place a settled check never covered — ranks ahead of everything. How the
// read itself is standing ranks last, behind the page's own reads, which the
// next block covers: a check that has not finished says nothing about this
// package.
describe("what the package page says instead of Update", () => {
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

// The page's own two gating reads, and what the header says when one of
// them does not land.
//
// Every answer that reaches them is a read that could have gone otherwise:
// the two commands hand back an absent value where core is saying there is
// no managed package here — undeclared, a plugin, a fork or another
// non-repository source — rather than that a read failed, so the page never
// tells an error apart from an answer and Try again is never dead.
describe("what the package page says when its own reads fail", () => {
  /** This place's row with nothing withholding an update, which is what
   *  leaves the update read with nothing to say about the package. */
  const HEALTHY = [updateRow(VG)];

  /** The button carrying this label, or null. */
  const button = (host: HTMLElement, label: string) =>
    [...host.querySelectorAll("button")].find(
      (one) => one.textContent === label,
    ) ?? null;

  /** What the commands answer where there is no managed package here: an
   *  absent record and an empty timeline, neither of them an error. */
  const noPackage = () => {
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: null,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: [],
    });
  };

  // Preview is gated on the timeline alone and survives a record read that
  // failed: it is read-only, and a record that did not land stops nobody
  // looking at what changed.
  it("names the record read, keeping the comparison it can still offer", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "error",
      error: "the manifest is unreadable",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(header(host)).toContain(
      packageReadFailedNote("the manifest is unreadable"),
    );
    expect(header(host)).not.toContain(UPDATE_LABEL);
    expect(header(host)).toContain(PREVIEW_CHANGES_LABEL);
  });

  // A timeline that did not read has no newer version on it, so a note held
  // behind newness is silent — which is how this page came to show an empty
  // action bar with nothing beside it.
  it("names the timeline read, where an empty version list is no answer", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "error",
      error: "the mirror is gone",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(header(host)).toContain(packageReadFailedNote("the mirror is gone"));
    expect(header(host)).not.toContain(UPDATE_LABEL);
  });

  // The generated wrapper rethrows a transport failure rather than answering
  // with one. Unwrapped, the landing never ran: the read stayed pending for
  // the life of the view, this note never appeared, and the rejection went
  // out unhandled. Both gating reads carry the wrapper, so both are asked.
  it.each([
    ["record", "packageMeta"],
    ["timeline", "packageVersions"],
  ] as const)(
    "answers a rejected %s read like a refused one",
    async (_, command) => {
      useUpdatesStore.setState({ rows: HEALTHY });
      vi.mocked(commands.packageMeta).mockResolvedValue({
        status: "ok",
        data: RECORD,
      });
      vi.mocked(commands.packageVersions).mockResolvedValue({
        status: "ok",
        data: TIMELINE,
      });
      vi.mocked(commands[command]).mockRejectedValue(new Error("ipc down"));

      const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

      expect(header(host)).toContain(packageReadFailedNote("ipc down"));
      expect(header(host)).not.toContain(UPDATE_LABEL);
    },
  );

  // The file list is not a gate on Update and has no read state of its own,
  // so what its wrapper buys is this: a rejection blanks the list rather
  // than leaving the files of the copy that was replaced under the new one.
  it("blanks the file list when its read is rejected", async () => {
    useUpdatesStore.setState({ rows: [updateRow(VG)] });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
    vi.mocked(commands.packageFiles).mockResolvedValue({
      status: "ok",
      data: [{ path: "BEFORE.md", size: 10, isReadme: false }],
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    expect(host.textContent).toContain("BEFORE.md");

    // A landed update moves the commit, and this time the read rejects.
    vi.mocked(commands.packageFiles).mockRejectedValue(new Error("ipc down"));
    await act(async () => {
      useUpdatesStore.setState({ rows: [movedRow()] });
    });
    await settle();

    expect(host.textContent).not.toContain("BEFORE.md");
  });

  // The reason stays put while the re-read runs: it is still the last answer
  // about this package, and blanking it would leave nothing to press and
  // nothing to say. The button is what reports the read is out.
  it("holds the note and disables Try again while the read is out", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "error",
      error: "the manifest is unreadable",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    const retry = button(host, TRY_AGAIN_LABEL);
    if (!retry) throw new Error("no Try again beside the note");
    expect(retry.disabled).toBe(false);

    // The re-read is held open, which is the state the button reports.
    vi.mocked(commands.packageMeta).mockImplementation(
      () => new Promise(() => {}),
    );
    await act(async () => {
      retry.click();
    });
    await settle();

    expect(header(host)).toContain(
      packageReadFailedNote("the manifest is unreadable"),
    );
    expect(button(host, TRY_AGAIN_LABEL)?.disabled).toBe(true);
  });

  // A failed read shows its error with a way to run it again — the invariant
  // docs/ARCHITECTURE.md states, and the affordance the safety tab one tab
  // over already carries.
  it("reads the package again when the note's Try again is pressed", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: TIMELINE,
    });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "error",
      error: "the manifest is unreadable",
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });
    const retry = button(host, TRY_AGAIN_LABEL);
    if (!retry) throw new Error("no Try again beside the note");

    // The second read answers, which is what the button is for.
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    await act(async () => {
      retry.click();
    });
    await settle();

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(header(host)).toContain(UPDATE_LABEL);
  });

  // Both reads landed, so nothing the page itself read withholds anything
  // and the button stands. Without this the cases above would pass over a
  // page that said the same thing whatever happened.
  it("says nothing of its own when both reads land", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
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
    expect(header(host)).toContain(UPDATE_LABEL);
  });

  // A check that has not finished, or one that failed, is the standing
  // behind every package on the machine and says nothing about this one. The
  // transport being down takes the standing out too, so ranking it first hid
  // a real failure in exactly the case the note exists for.
  it.each([
    ["a pending", READ_PENDING, UPDATES_CHECKING],
    ["a failed", readFailed("no network"), UPDATE_NEEDS_CHECK_HERE],
  ] as const)(
    "names its own failed reads over %s standing",
    async (_, read, standingNote) => {
      useUpdatesStore.setState({ rows: [], read });
      vi.mocked(commands.packageMeta).mockRejectedValue(new Error("ipc down"));
      vi.mocked(commands.packageVersions).mockRejectedValue(
        new Error("ipc down"),
      );

      const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

      expect(header(host)).toContain(packageReadFailedNote("ipc down"));
      expect(header(host)).not.toContain(standingNote);
      expect(button(host, TRY_AGAIN_LABEL)).not.toBeNull();
    },
  );

  // A plugin is declared nowhere, so core has no record and no timeline for
  // it. That is an answer about the manifest, not a read that failed: the
  // page says nothing of its own and core's reason for the kind stands.
  it("keeps core's refusal for the kind where it has no package to read", async () => {
    useUpdatesStore.setState({
      rows: [
        {
          ...updateRow(VG),
          kind: "plugin",
          noPerPackageUpdate: NO_PER_PACKAGE,
        },
      ],
    });
    noPackage();

    const host = await openPage(
      VG,
      [VG],
      { [scopeKey(VG)]: PLAIN },
      null,
      "plugin",
    );

    expect(host.textContent).toContain(NO_PER_PACKAGE);
    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(button(host, TRY_AGAIN_LABEL)).toBeNull();
  });

  // An unmanaged or vendor copy has no declaration either, and no row: the
  // update read's own answer about the place is the true one, and reading
  // the package again would answer exactly the same.
  it("leaves a package the check never covered to the update read", async () => {
    noPackage();

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).toContain(NO_UPDATE_STANDING_NOTE);
    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(button(host, TRY_AGAIN_LABEL)).toBeNull();
  });

  // A fork is declared against the local source, so core has a record for it
  // and no timeline, and emits a row that withholds nothing. Nothing is
  // being refused, so there is nothing to say and nothing to press.
  it("says nothing over a fork, which has a record and no timeline", async () => {
    useUpdatesStore.setState({ rows: HEALTHY });
    vi.mocked(commands.packageMeta).mockResolvedValue({
      status: "ok",
      data: RECORD,
    });
    vi.mocked(commands.packageVersions).mockResolvedValue({
      status: "ok",
      data: [],
    });

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(button(host, TRY_AGAIN_LABEL)).toBeNull();
    expect(header(host)).not.toContain(UPDATE_LABEL);
  });

  // A derived bundle member is in no scope's declared map, so both reads
  // answer absent; unpinned, its row withholds nothing either. The same
  // silence, reached from the other side.
  it("says nothing over an unpinned derived package", async () => {
    useUpdatesStore.setState({
      rows: [{ ...updateRow(VG), derived: true, requiredBy: ["bundle"] }],
    });
    noPackage();

    const host = await openPage(VG, [VG], { [scopeKey(VG)]: PLAIN });

    expect(host.textContent).not.toContain(PACKAGE_READ_FAILED);
    expect(button(host, TRY_AGAIN_LABEL)).toBeNull();
  });
});
