import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceSubscribe: vi.fn(),
    marketplaceInstall: vi.fn(),
    marketplacesOverview: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: {
    success: vi.fn(),
    message: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
  },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const subscribed = (name: string) => ({
  status: "ok" as const,
  data: {
    name,
    reference: "Acme/Kit",
    rev: null,
    lead: null,
    notes: [],
    undone: [],
  },
});

const installed = {
  status: "ok" as const,
  data: {
    packages: [],
    repoEffects: { shown: [], withheld: [] },
    undone: [],
  },
};

const item = [{ kind: "skill" as const, name: "preflight" }];

// Installing from a marketplace nobody subscribes to used to be impossible
// from the row: it said "Available" and left the reader to find the
// header's Subscribe button. The subscription is what makes an install
// possible, so the one click makes it.
describe("installing from a marketplace nobody subscribes to", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useMarketplacesStore.setState({ rows: [], error: null, busy: false });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });
  });

  it("subscribes personally first, then installs under the alias it got back", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue(
      // The engine picks the alias; the install has to use that one, not
      // the repository spelling the click carried.
      subscribed("kit"),
    );
    vi.mocked(commands.marketplaceInstall).mockResolvedValue(installed);

    const ok = await useMarketplacesStore
      .getState()
      .subscribeAndInstall("Acme/Kit", item);

    expect(ok).toBe(true);
    expect(commands.marketplaceSubscribe).toHaveBeenCalledWith(
      { scope: "global" },
      "Acme/Kit",
      null,
    );
    const [scope, source, items] = vi.mocked(commands.marketplaceInstall).mock
      .calls[0];
    expect(scope).toEqual({ scope: "global" });
    expect(source).toBe("kit");
    expect(items).toEqual(item);
  });

  // A refusal is normally shown beside the dialog's input. There is no
  // input on a package row, so it has to be said out loud, and nothing may
  // be installed on top of a subscription that never landed.
  it("says why and installs nothing when the subscription is refused", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "error",
      error: "already subscribed as 'kit'",
    });

    const ok = await useMarketplacesStore
      .getState()
      .subscribeAndInstall("Acme/Kit", item);

    expect(ok).toBe(false);
    expect(commands.marketplaceInstall).not.toHaveBeenCalled();
    expect(toast.error).toHaveBeenCalledWith("already subscribed as 'kit'");
  });
});
