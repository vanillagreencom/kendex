// @vitest-environment jsdom
import { getByRole } from "@testing-library/dom";
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStartupLoads } from "@/App";
import { commands } from "@/bindings";
import { packageVersionActions } from "@/components/package/package-version-actions";
import { updateRow } from "@/components/updates-test-rows";
import { CHECK_FOR_UPDATES_LABEL } from "@/lib/copy";
import { READ_PENDING } from "@/lib/read-state";
import { UpdatesPage } from "@/pages/updates";
import { mount, settle } from "@/test/dom";
import { useNavStore } from "./nav";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";
import { takeNewVersion } from "./updates-edits";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    accountStatus: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    windowZoomState: vi.fn(),
    scanMachine: vi.fn(),
    libraryProvenance: vi.fn(),
    auditAll: vi.fn(),
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    packageUpdateMany: vi.fn(),
    applyDiscardEdits: vi.fn(),
    projectChangesScan: vi.fn(),
    commitOfferScan: vi.fn(),
    appUpdateCheck: vi.fn(),
    appUpdateChannel: vi.fn(),
    appUpdateCommandChannel: vi.fn(),
    appVersion: vi.fn(),
    commandLinkState: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

// The root owns startup and focus. Navigation mounts only the real Updates
// page, so the tests count its demand against the real standing store.
function Session() {
  useStartupLoads();
  const page = useNavStore((s) => s.page);
  return page === "updates" ? <UpdatesPage /> : null;
}

const report = {
  rows: [updateRow("gh", null)],
  warnings: [],
  unreadable: [],
  lastFetched: null,
};

beforeEach(() => {
  vi.resetAllMocks();
  useUpdatesStore.setState({
    ...report,
    rows: [],
    read: READ_PENDING,
    reading: false,
    busy: false,
    checking: false,
  });
  useNavStore.setState({ page: "updates" });
  useSettingsStore.setState({ settings: null });
  vi.mocked(commands.commandLinkState).mockResolvedValue({
    status: "ok",
    data: { command: { kind: "notCarried" }, ask: false },
  });
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "ok",
    data: { state: { state: "signed-out" }, endpoint: "https://kendex.ai" },
  } as Awaited<ReturnType<typeof commands.accountStatus>>);
  vi.mocked(commands.getSettings).mockResolvedValue({
    status: "ok",
    data: {
      settings: {
        schema: 1,
        appearance: "system",
        "harness-roots": {},
        projects: [],
        zoom: 100,
      },
      base: null,
    },
  } as unknown as Awaited<ReturnType<typeof commands.getSettings>>);
  vi.mocked(commands.capabilityTable).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.windowZoomState).mockResolvedValue({
    status: "ok",
    data: { percent: 100, launchRefused: false },
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      harnesses: [],
      items: [],
      missingProjects: [],
      readProjects: [],
      warnings: [],
    },
  });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.projectChangesScan).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.commitOfferScan).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: report,
  });
  vi.mocked(commands.updatesRefresh).mockResolvedValue({
    status: "ok",
    data: report,
  });
  vi.mocked(commands.updateSetIgnored).mockResolvedValue({
    status: "ok",
    data: report,
  });
  for (const command of [
    commands.appUpdateCheck,
    commands.appUpdateChannel,
    commands.appUpdateCommandChannel,
  ]) {
    vi.mocked(command).mockResolvedValue({
      status: "error",
      error: "no release service in the fixture",
    });
  }
  vi.mocked(commands.appVersion).mockResolvedValue({
    status: "ok",
    data: "0.0.0-test",
  });
});

afterEach(() => vi.restoreAllMocks());

describe("Updates standing request ownership", () => {
  it("starts one overview with Updates open while startup is pending", async () => {
    let answer!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        answer = resolve;
      }),
    );
    const host = mount(<Session />);
    expect(useUpdatesStore.getState().reading).toBe(true);
    await act(async () => answer({ status: "ok", data: report }));
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    expect(useUpdatesStore.getState().rows).toBe(report.rows);
    expect(useUpdatesStore.getState().reading).toBe(false);
    expect(host.textContent).toContain("gh");
  });

  it("returns to retained rows without another overview", async () => {
    const host = mount(<Session />);
    await settle();
    const kept = useUpdatesStore.getState().rows;
    vi.mocked(commands.updatesOverview).mockClear();
    act(() => useNavStore.getState().setPage("settings"));
    act(() => useNavStore.getState().setPage("updates"));
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalledTimes(0);
    expect(useUpdatesStore.getState().rows).toBe(kept);
    expect(host.textContent).toContain("gh");
  });

  it("checks explicitly without an extra overview", async () => {
    const host = mount(<Session />);
    await settle();
    vi.mocked(commands.updatesOverview).mockClear();
    await userEvent.click(
      getByRole(host, "button", { name: CHECK_FOR_UPDATES_LABEL }),
    );
    await settle();
    expect(commands.updatesRefresh).toHaveBeenCalledTimes(1);
    expect(commands.updatesOverview).toHaveBeenCalledTimes(0);
    expect(useUpdatesStore.getState().read.status).toBe("landed");
  });

  it("reads once behind a mutation and retains its answer on return", async () => {
    mount(<Session />);
    await settle();
    vi.mocked(commands.updatesOverview).mockClear();
    const changed = {
      ...report,
      rows: [updateRow("gh", null, { ignored: true })],
    };
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: changed,
    });
    await act(async () =>
      useUpdatesStore.getState().setIgnored(report.rows[0], true),
    );
    expect(commands.updateSetIgnored).toHaveBeenCalledTimes(1);
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    expect(useUpdatesStore.getState().rows).toBe(changed.rows);
    act(() => useNavStore.getState().setPage("settings"));
    act(() => useNavStore.getState().setPage("updates"));
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
  });

  it("returns to the standing read behind a package version switch", async () => {
    const host = mount(<Session />);
    await settle();
    expect(host.textContent).toContain("gh");
    vi.mocked(commands.updatesOverview).mockClear();
    act(() => useNavStore.getState().setPage("package"));
    const subject = report.rows[0];
    const latest = subject.latest;
    if (!latest)
      throw new Error("version-switch fixture has no latest version");
    const current = {
      ...report,
      rows: [
        {
          ...subject,
          current: subject.latest,
          updateAvailable: false,
          pinned: true,
        },
      ],
    };
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: current,
    });
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: {
        view: {
          scope: subject.scope,
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: [],
          exits: [],
        },
        heldBack: [],
        removed: [],
        moved: [],
      },
    });
    await act(async () => {
      await packageVersionActions(
        {
          scope: subject.scope,
          kind: subject.kind,
          name: subject.name,
          identity: "recorded",
        },
        "gh",
        false,
        () => {},
        () => {},
      ).switchTo({
        id: latest.commit,
        label: "v2",
        date: "2026-01-01",
        summary: "latest",
        installed: false,
        newerThanInstalled: true,
      });
    });
    await settle();
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      subject.scope,
      subject.kind,
      subject.name,
      latest.commit,
    );
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    expect(useUpdatesStore.getState().rows).toBe(current.rows);
    act(() => useNavStore.getState().setPage("updates"));
    await settle();
    expect(host.textContent).not.toContain("gh");
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
  });

  // These owners already order their standing read around the scan. A
  // shared rescan must not add a second read or move that read outside busy.
  for (const mutation of [
    {
      name: "updateOne",
      run: () => useUpdatesStore.getState().updateOne(report.rows[0]),
      scanFirst: false,
    },
    {
      name: "repairOne",
      run: () => useUpdatesStore.getState().repairOne(report.rows[0]),
      scanFirst: true,
    },
    {
      name: "updateRows",
      run: () => useUpdatesStore.getState().updateRows(report.rows),
      scanFirst: false,
    },
    {
      name: "discard edits",
      run: () => takeNewVersion(report.rows[0]),
      scanFirst: false,
    },
  ]) {
    it(`keeps one ordered standing read inside ${mutation.name}'s write hold`, async () => {
      mount(<Session />);
      await settle();
      vi.mocked(commands.updatesOverview).mockClear();
      vi.mocked(commands.scanMachine).mockClear();
      for (const command of [
        commands.packageUpdate,
        commands.packageUpdateMany,
        commands.applyDiscardEdits,
      ]) {
        vi.mocked(command).mockResolvedValue({
          status: "error",
          error: "scope refused",
        });
      }
      const holds: boolean[] = [];
      vi.mocked(commands.updatesOverview).mockImplementation(async () => {
        holds.push(useUpdatesStore.getState().busy);
        return { status: "ok", data: report };
      });
      await act(async () => mutation.run());
      expect(holds).toEqual([true]);
      expect(commands.scanMachine).toHaveBeenCalledTimes(1);
      const scanAt = vi.mocked(commands.scanMachine).mock
        .invocationCallOrder[0];
      const updatesAt = vi.mocked(commands.updatesOverview).mock
        .invocationCallOrder[0];
      expect(scanAt < updatesAt).toBe(mutation.scanFirst);
      expect(useUpdatesStore.getState().busy).toBe(false);
    });
  }

  it("keeps a failed startup visible and retries through Check for updates", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "error",
      error: "overview unavailable",
    });
    const host = mount(<Session />);
    await settle();
    expect(host.textContent).toContain("overview unavailable");
    vi.mocked(commands.updatesOverview).mockClear();
    await userEvent.click(
      getByRole(host, "button", { name: CHECK_FOR_UPDATES_LABEL }),
    );
    await settle();
    expect(commands.updatesRefresh).toHaveBeenCalledTimes(1);
    expect(commands.updatesOverview).toHaveBeenCalledTimes(0);
    expect(useUpdatesStore.getState().read.error).toBeNull();
    expect(useUpdatesStore.getState().rows).toBe(report.rows);
  });

  it("reads again on window focus but not on page return", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(0);
    mount(<Session />);
    await settle();
    vi.mocked(commands.updatesOverview).mockClear();
    now.mockReturnValue(6000);
    await act(async () => window.dispatchEvent(new Event("focus")));
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    act(() => useNavStore.getState().setPage("settings"));
    act(() => useNavStore.getState().setPage("updates"));
    await settle();
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    await act(async () => window.dispatchEvent(new Event("focus")));
    expect(commands.updatesOverview).toHaveBeenCalledTimes(1);
    now.mockReturnValue(12000);
    await act(async () => window.dispatchEvent(new Event("focus")));
    expect(commands.updatesOverview).toHaveBeenCalledTimes(2);
  });
});
