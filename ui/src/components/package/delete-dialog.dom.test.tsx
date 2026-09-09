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
import { READ_PENDING } from "@/lib/read-state";
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
  useProvenanceStore.setState({
    rows: [],
    loaded: true,
    read: READ_PENDING,
    reading: false,
  });
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
      reference={{ kind: "skill", name: "gh", identity: "recorded" }}
      scopes={scopes}
    />,
  );
  await settle();
  const dialog = [
    ...document.querySelectorAll('[data-slot="dialog-content"]'),
  ].at(-1);
  if (!dialog) throw new Error("the open dialog has no content");
  return dialog.textContent ?? "";
};

const rowsFor = (origins: [Scope, Origin][]): ProvenanceRow[] =>
  origins.map(([scope, origin]) => ({
    scope,
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin,
    package: { kind: "skill", name: "gh" },
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

/** A join read this test answers by hand, to hold one open. */
const park = () => {
  let land: (value: JoinAnswer) => void = () => {};
  const promise = new Promise<JoinAnswer>((resolve) => {
    land = resolve;
  });
  return { promise, land };
};

type JoinAnswer = Awaited<ReturnType<typeof commands.libraryProvenance>>;

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

  it("names all known reinstall sources without inventing an origin", async () => {
    const rows: {
      name: string;
      origins: [Scope, Origin][] | null;
      scopes: Scope[];
      present: string[];
      absent: string[];
    }[] = [
      {
        name: "marketplace",
        origins: [[VG, MARKET("acme")]],
        scopes: [VG],
        present: [reinstallFrom(["acme"])],
        absent: [],
      },
      {
        name: "several marketplaces sorted",
        origins: [
          [VG, MARKET("beta")],
          [HYPR, MARKET("acme")],
        ],
        scopes: [VG, HYPR],
        present: ["acme", "beta", reinstallFrom(["acme", "beta"])],
        absent: [],
      },
      {
        name: "marketplace beside own",
        origins: [
          [VG, MARKET("acme")],
          [HYPR, OWN],
        ],
        scopes: [VG, HYPR],
        present: [reinstallFrom(["acme"])],
        absent: [REINSTALL_OWN],
      },
      {
        name: "own copy",
        origins: [[VG, OWN]],
        scopes: [VG],
        present: [REINSTALL_OWN],
        absent: [],
      },
      {
        name: "unknown origin",
        origins: null,
        scopes: [VG],
        present: [],
        absent: [REINSTALL_OWN, reinstallFrom(["acme"])],
      },
    ];
    expect(rows).toHaveLength(5);
    for (const entry of rows) {
      if (entry.origins !== null) from(...entry.origins);
      else {
        useProvenanceStore.setState({ rows: [], loaded: false });
        vi.mocked(commands.libraryProvenance).mockResolvedValue({
          status: "error",
          error: "not in this test",
        });
      }
      const said = await openDialog(entry.scopes);
      expect(
        {
          present: entry.present.filter((text) => said.includes(text)),
          forbidden: entry.absent.filter((text) => said.includes(text)),
        },
        entry.name,
      ).toEqual({ present: entry.present, forbidden: [] });
    }
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

  // A read that rejects rather than answering is the same failed read and
  // must not come out as an unhandled rejection. The note is where to get
  // the package again, not what the deletion does, so its absence leaves
  // Delete live.
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
  // reader somewhere the package may not be installable from.
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

  // The dialog's own read is routinely overtaken: the sidebar's Scan again
  // and every write's rescan read the same join, and an open landing under
  // one gets the newer read's answer. The note has to arrive with that
  // read — a dialog latching its own call's verdict would go the whole open
  // with nothing under the confirm step.
  it("names the marketplace the read that overtook this open's landed", async () => {
    useProvenanceStore.setState({ rows: rowsFor([[VG, OWN]]), loaded: true });
    const mine = park();
    const rescan = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(mine.promise)
      .mockReturnValueOnce(rescan.promise);

    const said = await openDialog([VG]);
    expect(said).not.toContain(reinstallFrom(["acme"]));

    // A rescan behind a write begins its own read while this open's is
    // still out, then this open's answers first and is overtaken.
    void useProvenanceStore.getState().reload();
    mine.land({ status: "ok", data: rowsFor([[VG, OWN]]) });
    await settle();
    expect(document.body.textContent).not.toContain(REINSTALL_OWN);

    rescan.land({ status: "ok", data: rowsFor([[VG, MARKET("acme")]]) });
    await settle();
    expect(document.body.textContent).toContain(reinstallFrom(["acme"]));
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
