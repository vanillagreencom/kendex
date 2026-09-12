// @vitest-environment jsdom
// Where the Updates page leads when it has nothing to list. The static
// table beside this file pins what each empty state says; this pins the one
// thing a static render cannot reach — whether the control an empty machine
// is given actually goes anywhere. Browse Marketplaces is the only action
// that state offers, the check being deliberately absent, so a handler that
// leads nowhere leaves the page with no way on.
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
  // The page reloads the standing on mount; an empty machine answers with
  // nothing in every field, which is the state under test.
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [], unreadable: [], fetchedAt: null },
  } as never);
  // A settled, complete, successful scan of a machine with nothing on it,
  // and a join that answered about that scan: the one state in which the
  // page may say the machine is empty.
  useScanStore.setState({
    result: {
      harnesses: [],
      items: [],
      missingProjects: [],
      readProjects: [],
      warnings: [],
    },
    error: null,
    scanning: false,
    generation: 1,
  });
  useProvenanceStore.setState({ rows: [], loaded: true, answeredFor: 1 });
  useUpdatesStore.setState({
    rows: [],
    warnings: [],
    unreadable: [],
    read: READ_LANDED,
    lastFetched: null,
    busy: false,
    checking: false,
  });
  useNavStore.setState({ page: "updates", history: [], future: [] });
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
