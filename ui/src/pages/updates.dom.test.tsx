// @vitest-environment jsdom
// Where an empty machine's Updates page leads. Browse Marketplaces is the
// only action that state offers, the check being deliberately absent, so a
// handler that goes nowhere leaves the page with no way on — and a static
// render, which invokes no handler, cannot tell.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { BROWSE_MARKETPLACES_LABEL } from "@/lib/copy";
import { READ_LANDED } from "@/lib/read-state";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { scanFound } from "@/test/observed";
import { UpdatesPage } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    updatesOverview: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

beforeEach(() => {
  vi.mocked(commands.auditAll).mockResolvedValue({
    status: "ok",
    data: [],
  } as never);
  // The page reloads the standing on mount, and that answer replaces the
  // staged one, so it carries the same empty machine.
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [], unreadable: [], fetchedAt: null },
  } as never);
  // A settled scan of a machine with nothing on it, and a join answering
  // about that scan: the one state in which the page may say so. Only what
  // differs from each store's own defaults is set.
  useScanStore.setState({ result: scanFound([]), generation: 1 });
  useProvenanceStore.setState({ loaded: true, answeredFor: 1 });
  useUpdatesStore.setState({ read: READ_LANDED });
  useNavStore.setState({ page: "updates" });
});

describe("where an empty machine's Updates page leads", () => {
  it("opens the marketplaces from Browse Marketplaces", async () => {
    const host = mount(<UpdatesPage />);
    await settle();
    const button = [...host.querySelectorAll("button")].find(
      (one) => one.textContent?.trim() === BROWSE_MARKETPLACES_LABEL,
    );
    if (!button) throw new Error("no Browse Marketplaces on screen");
    await userEvent.click(button);
    expect(useNavStore.getState().page).toBe("marketplaces");
  });
});
