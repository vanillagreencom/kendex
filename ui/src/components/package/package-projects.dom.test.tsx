// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
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
  ItemKind,
  PackageMeta_Serialize,
  Scope,
  UpdateRow,
} from "@/bindings";
import { commands } from "@/bindings";
import {
  PROJECTS_LOADING,
  REMOVE_ALL_LABEL,
  REMOVE_LABEL,
  UPDATE_ALL_LABEL,
} from "@/lib/copy-projects";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { PackageProjects } from "./package-projects";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: { packageMeta: vi.fn() },
}));

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

const row = (scope: Scope, updateAvailable: boolean): UpdateRow => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: null,
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
    loaded: true,
    checking: false,
    overviewInFlight: false,
    pendingFollows: [],
    updateOne,
    updateRows,
  });
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
      loaded: false,
      error: "the read failed",
    });
    const host = await openTab([VG, HYPR]);

    expect(buttons(host).filter((one) => one.textContent === "Update")).toEqual(
      [],
    );
    expect(host.textContent).not.toContain(UPDATE_ALL_LABEL);
  });

  it("offers nothing while a read that replaces every row is in flight", async () => {
    useUpdatesStore.setState({
      rows: [row(VG, true), row(HYPR, true)],
      overviewInFlight: true,
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
