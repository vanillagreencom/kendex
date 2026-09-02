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
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn(), info: vi.fn() },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const item = [{ kind: "skill" as const, name: "preflight" }];

// Installing from a marketplace nobody subscribes to has to subscribe
// first — that is what makes its packages installable, and it is the whole
// of what this action promises. The row's half, which arguments it hands
// over, is packages-table.test.tsx.
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
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "ok",
      // The engine picks the alias; the install has to use that one, not
      // the repository spelling the click carried.
      data: {
        name: "kit",
        reference: "Acme/Kit",
        rev: null,
        lead: null,
        notes: [],
        undone: [],
      },
    });
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "ok",
      data: {
        packages: [],
        repoEffects: { shown: [], withheld: [] },
        undone: [],
      },
    });

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
});
