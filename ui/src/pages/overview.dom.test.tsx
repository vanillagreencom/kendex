// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { EDITED_ATTENTION_ACTION } from "@/lib/copy";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { OverviewPage } from "./overview";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    marketplacesOverview: vi.fn(),
    scanMachine: vi.fn(),
    updatesRefresh: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const HYPR = { scope: "project", root: "/work/hyprtrade" } as const;

const edited = (name: string): UpdateRow =>
  ({
    kind: "skill",
    name,
    scope: HYPR,
    blockedByLocalEdit: true,
    editedHarnesses: ["claude"],
  }) as unknown as UpdateRow;

beforeEach(() => {
  vi.mocked(commands.auditAll).mockResolvedValue({
    status: "ok",
    data: [],
  } as never);
  vi.mocked(commands.marketplacesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [] },
  } as never);
  useScanStore.setState({
    result: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    error: null,
    scanning: false,
  });
  useAuditStore.setState({
    views: [],
    auditedAt: Date.now(),
    read: READ_LANDED,
  });
  useMarketplacesStore.setState({ rows: [], read: READ_LANDED } as never);
  useUpdatesStore.setState({
    rows: [edited("commit-guards"), edited("worktree")],
    read: READ_LANDED,
    unreadable: [],
  });
  useNavStore.setState({ page: "home", libraryFilter: null });
});

// The three links of the landing chain are each pinned elsewhere; this is
// the joint: the page hands the Library a narrowing to edited packages,
// not a bare link to everything.
describe("Home's edited row", () => {
  it("opens the Library narrowed to the edited packages", async () => {
    const host = mount(<OverviewPage />);
    const button = [...host.querySelectorAll("button")].find((el) =>
      el.textContent?.includes(EDITED_ATTENTION_ACTION),
    );
    expect(button).toBeDefined();
    await act(async () => {
      button?.click();
    });
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter).toEqual({ edited: true });
  });
});
