// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { EDITED_ATTENTION_ACTION, UPDATES_ATTENTION_TITLE } from "@/lib/copy";
import { updatesWaitingTitle } from "@/lib/copy-updates";
import { READ_LANDED, readFailed } from "@/lib/read-state";
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

const removedUpstream = (name: string): UpdateRow =>
  ({
    kind: "skill",
    name,
    scope: HYPR,
    updateAvailable: false,
    removedUpstream: true,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    repoIdentity: "vanillagreencom/kendex",
  }) as unknown as UpdateRow;

const outOfDate = (name: string): UpdateRow =>
  ({
    kind: "skill",
    name,
    scope: HYPR,
    updateAvailable: true,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    repoIdentity: "vanillagreencom/kendex",
  }) as unknown as UpdateRow;

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
    result: {
      harnesses: [],
      items: [],
      missingProjects: [],
      readProjects: [],
      warnings: [],
    },
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

// Home says how many packages have updates and takes the reader to them.
// Only a landed read may put a number here: rows kept from a failed check
// are last-known, and the failed-check row is what stands over them.
describe("Home's updates row", () => {
  it("counts the packages with updates and goes to them", async () => {
    useUpdatesStore.setState({
      rows: [outOfDate("gh"), outOfDate("dev")],
      read: READ_LANDED,
    });
    const host = mount(<OverviewPage />);
    const button = [...host.querySelectorAll("button")].find((el) =>
      el.textContent?.includes(updatesWaitingTitle(2)),
    );
    expect(button).toBeDefined();
    await act(async () => {
      button?.click();
    });
    expect(useNavStore.getState().page).toBe("updates");
  });

  it("counts nothing off rows a failed check left behind", () => {
    useUpdatesStore.setState({
      rows: [outOfDate("gh"), outOfDate("dev")],
      read: readFailed("no network"),
    });
    const host = mount(<OverviewPage />);
    expect(host.textContent).not.toContain(updatesWaitingTitle(2));
    expect(host.textContent).not.toContain("packages have updates");
    // What the reader gets instead: the check that could not answer.
    expect(host.textContent).toContain(UPDATES_ATTENTION_TITLE);
  });
});

// A package its source dropped has no version to move to, and this row's
// words promise one. It stays on the Updates page, tagged, and out of this
// count.
describe("what Home's updates row counts", () => {
  it("counts only packages with an update to take", () => {
    useUpdatesStore.setState({
      rows: [outOfDate("gh"), removedUpstream("gone")],
      read: READ_LANDED,
    });
    const host = mount(<OverviewPage />);
    expect(host.textContent).toContain(updatesWaitingTitle(1));
    expect(host.textContent).not.toContain(updatesWaitingTitle(2));
  });

  it("says nothing at all where the only news is not an update", () => {
    useUpdatesStore.setState({
      rows: [removedUpstream("gone")],
      read: READ_LANDED,
    });
    const host = mount(<OverviewPage />);
    expect(host.textContent).not.toContain("packages have updates");
    expect(host.textContent).not.toContain("package has an update");
  });
});
