import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import { subscription } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: {
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    marketplaceSubscribe: vi.fn(),
    marketplaceInstall: vi.fn(),
    marketplacesOverview: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn(), info: vi.fn() },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

// Installing from a marketplace nobody subscribes to has to subscribe
// first — that is what makes its packages installable, and it is the whole
// of what this action promises. It installs nothing itself: the guided
// install owns every install request, and this hands it a subscription to
// ask about. The row's half is packages-table.test.tsx.
describe("installing from a marketplace nobody subscribes to", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useMarketplacesStore.setState({ rows: [], error: null, busy: false });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });
  });

  it("subscribes personally and answers with the alias it got back", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "ok",
      data: {
        name: "kit",
        reference: "Acme/Kit",
        rev: null,
        lead: null,
        notes: [],
        undone: [],
      },
    });
    const made = await useMarketplacesStore
      .getState()
      .subscribeForInstall("Acme/Kit");

    expect(commands.marketplaceSubscribe).toHaveBeenCalledWith(
      { scope: "global" },
      "Acme/Kit",
      null,
    );
    // The engine picks the alias; everything downstream names that one,
    // not the repository spelling the click carried.
    expect(made).toEqual(subscription({ scope: "global" }, "kit"));
    // Nothing is written here. Where the packages go is a question the
    // reader has not been asked yet.
    expect(commands.marketplaceInstall).not.toHaveBeenCalled();
  });

  // A refused subscription has no subscription to install from, so the
  // caller is told plainly rather than being handed one to ask about.
  it("answers with nothing when the subscription is refused", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "error",
      error: "already declared here",
    });

    expect(
      await useMarketplacesStore.getState().subscribeForInstall("Acme/Kit"),
    ).toBeNull();
    expect(commands.marketplaceInstall).not.toHaveBeenCalled();
  });
});
