// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Origin, Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
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
      onGone={() => {}}
    />,
  );
  await settle();
  return document.body.textContent ?? "";
};

const from = (...origins: [Scope, Origin][]) =>
  useProvenanceStore.setState({
    rows: origins.map(([scope, origin]) => ({
      scope,
      kind: "skill",
      name: "gh",
      harness: "claude",
      origin,
    })),
    loaded: true,
  });

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
  it("claims no origin while the join has not landed", async () => {
    useProvenanceStore.setState({ rows: [], loaded: false });

    const said = await openDialog([VG]);
    expect(said).not.toContain(REINSTALL_OWN);
    expect(said).not.toContain("install it again from");
  });
});
