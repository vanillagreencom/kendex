// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Origin, ProvenanceRow, Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  DELETE_LABEL,
  DELETE_PLACES_LABEL,
  REINSTALL_OWN,
  reinstallFrom,
} from "@/lib/copy-projects";
import { useAuditStore } from "@/stores/audit";
import { useProvenanceStore } from "@/stores/provenance";
import { mount, settle } from "@/test/dom";
import { DeleteDialog } from "./delete-dialog";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: { libraryProvenance: vi.fn() },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
const MINE: Scope = { scope: "global" };

beforeEach(() => {
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "error",
    error: "not in this test",
  });
  useAuditStore.setState({ busy: false, removeItem: vi.fn() });
  useProvenanceStore.setState({ rows: [], loaded: true });
});

/** The dialog's Delete button, read out of the portal. */
const deleteButton = () =>
  Array.from(document.querySelectorAll("button")).find(
    (one) => one.textContent === DELETE_LABEL,
  );

/** The dialog open over `gh`, installed in `scopes`. base-ui portals the
 *  content out of the mount, so the document is what it is read from. */
const openDialog = async (scopes: Scope[]) => {
  mount(
    <DeleteDialog
      open
      onOpenChange={() => {}}
      kind="skill"
      name="gh"
      scopes={scopes}
    />,
  );
  await settle();
  return document.body.textContent ?? "";
};

const rowsFor = (origins: [Scope, Origin][]): ProvenanceRow[] =>
  origins.map(([scope, origin]) => ({
    scope,
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin,
  }));

/** The join as it stands and as a fresh read answers: the dialog takes its
 *  own read on every open, so both have to say the same thing for the
 *  ordinary cases. */
const from = (...origins: [Scope, Origin][]) => {
  const rows = rowsFor(origins);
  useProvenanceStore.setState({ rows, loaded: true });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: rows,
  });
};

const MARKET = (source: string): Origin => ({
  origin: "marketplace",
  source,
  repo: `${source}/pack`,
});
const OWN: Origin = { origin: "own", source: "own", forkedFrom: null };

describe("the Delete dialog", () => {
  it("names the package and every place the deletion reaches", async () => {
    const said = await openDialog([VG, HYPR, MINE]);

    expect(said).toContain("Delete gh?");
    expect(said).toContain(DELETE_PLACES_LABEL);
    expect(said).toContain("vg");
    expect(said).toContain("/work/vg");
    expect(said).toContain("hyprtrade");
    expect(said).toContain("User level");
  });

  it("names the marketplace it can be installed from again", async () => {
    from([VG, MARKET("acme")]);

    expect(await openDialog([VG])).toContain(reinstallFrom(["acme"]));
  });

  // Each place records the source it was installed from, so the copies
  // this one deletion reaches can come from different marketplaces. One
  // of them is not an answer: it sends the reader somewhere that never
  // held the rest.
  it("names every marketplace the deleted copies came from", async () => {
    from([VG, MARKET("beta")], [HYPR, MARKET("acme")]);

    const said = await openDialog([VG, HYPR]);
    expect(said).toContain("acme");
    expect(said).toContain("beta");
    expect(said).toContain(reinstallFrom(["acme", "beta"]));
  });

  // A place of the reader's own beside a marketplace one leaves the
  // marketplace worth naming; there is nowhere to send them for the other.
  it("names the marketplace beside a copy that is the reader's own", async () => {
    from([VG, MARKET("acme")], [HYPR, OWN]);

    const said = await openDialog([VG, HYPR]);
    expect(said).toContain(reinstallFrom(["acme"]));
    expect(said).not.toContain(REINSTALL_OWN);
  });

  it("says so where the copy is the reader's own", async () => {
    from([VG, OWN]);

    expect(await openDialog([VG])).toContain(REINSTALL_OWN);
  });

  // Where the package came from is a read like any other: unread is not
  // "your own", and the dialog would rather say nothing than guess.
  it("claims no origin when the read does not answer", async () => {
    useProvenanceStore.setState({ rows: [], loaded: false });

    const said = await openDialog([VG]);
    expect(said).not.toContain(REINSTALL_OWN);
    expect(said).not.toContain(reinstallFrom(["acme"]));
  });
});

// `loaded` says a snapshot landed once, never that it covers this
// package: installing refreshes the scan and the audit and leaves this
// join alone. A dialog trusting it would name the marketplace the reader
// had before they installed anything.
describe("the read behind the note", () => {
  it("takes its own read rather than trusting a loaded snapshot", async () => {
    useProvenanceStore.setState({ rows: rowsFor([[VG, OWN]]), loaded: true });
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "ok",
      data: rowsFor([[VG, MARKET("acme")]]),
    });

    const said = await openDialog([VG]);
    expect(said).toContain(reinstallFrom(["acme"]));
    expect(said).not.toContain(REINSTALL_OWN);
  });

  // The generated wrapper rethrows a transport failure, which is the same
  // failed read and must not come out as an unhandled rejection. The note
  // is where to get the package again, not what the deletion does, so its
  // absence leaves Delete live.
  it("leaves Delete live when the read never answers", async () => {
    vi.mocked(commands.libraryProvenance).mockRejectedValue(
      new Error("the channel is gone"),
    );

    const said = await openDialog([VG]);
    expect(said).not.toContain(reinstallFrom(["acme"]));
    expect(deleteButton()?.disabled).toBe(false);
  });

  // A read that failed leaves the rows a previous one put in the store,
  // and those may answer for a different installation. Naming a
  // marketplace off them at the confirm step of a deletion sends the
  // reader somewhere the package may no longer be installable from.
  it("names nothing off rows this open's read did not land", async () => {
    useProvenanceStore.setState({
      rows: rowsFor([[VG, MARKET("acme")]]),
      loaded: true,
    });
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "error",
      error: "the join did not read",
    });

    const said = await openDialog([VG]);
    expect(said).not.toContain(reinstallFrom(["acme"]));
    expect(said).not.toContain(REINSTALL_OWN);
  });

  it("names nothing off rows a rejected read left standing", async () => {
    useProvenanceStore.setState({ rows: rowsFor([[VG, OWN]]), loaded: true });
    vi.mocked(commands.libraryProvenance).mockRejectedValue(
      new Error("the channel is gone"),
    );

    const said = await openDialog([VG]);
    expect(said).not.toContain(REINSTALL_OWN);
  });
});
