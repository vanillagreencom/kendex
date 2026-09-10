// Registering a project and reading what it holds are two answers.
//
// The registry write lands in a moment; reading the machine takes seconds
// and can fail on its own. Every case here holds the read unresolved,
// because that is the state the old flow spent on screen with a dead
// button — asserted after the read has landed, a split would pass against
// a store that never made one.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ScanResult } from "@/bindings";
import { commands } from "@/bindings";
import { useAuditStore } from "./audit";
import { useProjectSetupStore } from "./project-setup";
import { useScanStore } from "./scan";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    registerProject: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
    projectChangesScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    commitOfferBaseline: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    commitOfferScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const emptyScan: ScanResult = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
  readProjects: [],
};

/** The machine read, held until the case lets it answer. Once only: a
 *  second call answers straight away, so nothing is left pending for the
 *  case after this one to queue behind. */
function heldScan(): () => void {
  let land: () => void = () => {};
  vi.mocked(commands.scanMachine).mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        land = () => resolve({ status: "ok", data: emptyScan as never });
      }),
  );
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: emptyScan as never,
  });
  return () => land();
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.registerProject).mockResolvedValue({
    status: "ok",
    data: {
      read: { settings: { projects: ["/work/acme"] }, base: null },
      root: "/work/acme",
    } as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  useProjectSetupStore.setState({ checking: [], unchecked: [] });
  useScanStore.setState({ scanning: false, result: emptyScan, error: null });
});

describe("adding a project", () => {
  // The registry write is the whole answer the caller waits for. Waiting
  // for the machine read behind it is what held the add dialog open.
  it("answers the registry write without waiting for the machine read", async () => {
    const land = heldScan();

    const added = await useSettingsStore
      .getState()
      .registerProject("/work/acme");

    // Registered, and the read of what it holds still out. Waiting for
    // that read is what the caller no longer does.
    expect(added).toBe(true);
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(useProjectSetupStore.getState().checking).toEqual(["/work/acme"]);

    land();
    await vi.waitFor(() =>
      expect(useProjectSetupStore.getState().checking).toEqual([]),
    );
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
  });

  // The registry expands a tilde and canonicalises, so what it records is
  // not the string the reader typed — and the card matches its setup state
  // against settings' own roots. Keyed on the typed string, the checking
  // and check-failed states never appear for that project and the card
  // draws it as empty instead. The write says which root it made; the
  // answer's project list is deliberately unhelpful here, because a set
  // difference is what this replaces.
  it("keys the check on the root the registry recorded, not the typed path", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: {
        read: {
          settings: { projects: ["/home/u/dev/acme", "/home/u/dev/beta"] },
          base: null,
        },
        root: "/home/u/dev/acme",
      } as never,
    });
    const land = heldScan();

    await useSettingsStore.getState().registerProject("~/dev/acme");

    expect(useProjectSetupStore.getState().checking).toEqual([
      "/home/u/dev/acme",
    ]);

    land();
    await vi.waitFor(() =>
      expect(useProjectSetupStore.getState().checking).toEqual([]),
    );
  });

  // The project is registered either way. A read that failed is its own
  // state, so the card can say so and offer the read again rather than
  // drawing a place with nothing in it.
  it("records a failed read as unchecked, and clears it when one answers", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });
    await useProjectSetupStore.getState().check("/work/acme");
    expect(useProjectSetupStore.getState().unchecked).toEqual(["/work/acme"]);

    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: emptyScan as never,
    });
    useAuditStore.setState({ backgroundFailureAnnounced: false });
    await useProjectSetupStore.getState().check("/work/acme");
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
    expect(useProjectSetupStore.getState().checking).toEqual([]);
  });

  // Every check reads the whole machine, so a read that answered answers
  // for every root a previous read failed on too. Clearing only its own
  // would leave another project marked "package check failed" over a
  // reading that has since refreshed it, with a Try again that does
  // nothing new.
  it("clears every failed root when a read answers", async () => {
    useProjectSetupStore.setState({
      checking: [],
      unchecked: ["/work/beta", "/work/gamma"],
    });

    await useProjectSetupStore.getState().check("/work/acme");

    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
  });
});

// The read is not awaited by whoever starts it, so it can land after the
// project it was started for has stopped being one. Its failure is about
// a folder nothing tracks, and putting it back is the mark the forget
// took off — the card at the folder the project moved to would inherit
// "package check failed" from the path it left.
describe("a read still out when the project stops being one", () => {
  it("lands nothing back onto a forgotten folder, and takes nothing else off", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });
    // Another project, marked from a read that failed earlier. No read has
    // answered since, so nothing here may clear its mark.
    useProjectSetupStore.setState({ unchecked: ["/work/other"] });

    const out = useProjectSetupStore.getState().check("/work/vsys-view");
    useProjectSetupStore.getState().forget("/work/vsys-view");
    await out;

    expect(useProjectSetupStore.getState().unchecked).toEqual(["/work/other"]);
    expect(useProjectSetupStore.getState().checking).toEqual([]);
  });

  // The same folder registered afresh is a project again, and the read
  // that names it says so.
  it("records a failure again once the folder is asked about again", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });
    useProjectSetupStore.getState().forget("/work/vsys");

    await useProjectSetupStore.getState().check("/work/vsys");

    expect(useProjectSetupStore.getState().unchecked).toEqual(["/work/vsys"]);
  });
});

// The offer to fill a freshly added project is about a registration, and
// the card's Try again calls the same read. Set inside that read, a retry
// of a failed scan on a project kendex already tracks opened the
// install-a-template offer for a project nobody had just added.
describe("which read counts as an addition", () => {
  it("records the project only for a read that follows a registration", async () => {
    useProjectSetupStore.setState({ justAdded: null });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: emptyScan as never,
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "ok",
      data: [],
    });

    // The card's Try again: a read on its own behalf, no registration.
    await useProjectSetupStore.getState().check("/work/acme");
    expect(useProjectSetupStore.getState().justAdded).toBeNull();

    // The registration path says so, and that is what the offer reads.
    await useProjectSetupStore.getState().check("/work/acme", true);
    expect(useProjectSetupStore.getState().justAdded).toBe("/work/acme");

    // A later retry does not clear it either — answering the offer does.
    await useProjectSetupStore.getState().check("/work/acme");
    expect(useProjectSetupStore.getState().justAdded).toBe("/work/acme");
    useProjectSetupStore.getState().clearJustAdded();
    expect(useProjectSetupStore.getState().justAdded).toBeNull();
  });

  // A folder that stops being a project takes the offer about it with it:
  // the offer names a root, and that root is what this verb is letting go
  // of. Another project's offer is not its to clear.
  it("lets go of the offer when the folder it names stops being a project", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: emptyScan as never,
    });

    await useProjectSetupStore.getState().check("/work/acme", true);
    useProjectSetupStore.getState().forget("/work/other");
    expect(useProjectSetupStore.getState().justAdded).toBe("/work/acme");

    useProjectSetupStore.getState().forget("/work/acme");
    expect(useProjectSetupStore.getState().justAdded).toBeNull();
  });
});
