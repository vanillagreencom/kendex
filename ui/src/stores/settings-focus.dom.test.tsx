// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useStartupLoads } from "@/App";
import { commands } from "@/bindings";
import { mount, settle } from "@/test/dom";
import { useCommitOfferStore } from "./commit-offer";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    accountStatus: vi.fn(),
    getSettings: vi.fn(),
    updateSettings: vi.fn(),
    capabilityTable: vi.fn(),
    windowZoomState: vi.fn(),
    scanMachine: vi.fn(),
    libraryProvenance: vi.fn(),
    auditAll: vi.fn(),
    updatesOverview: vi.fn(),
    appUpdateCheck: vi.fn(),
    appUpdateChannel: vi.fn(),
    appUpdateCommandChannel: vi.fn(),
    appVersion: vi.fn(),
    commitOfferScan: vi.fn(),
    relocateProject: vi.fn(),
    projectChangesScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

function Startup() {
  useStartupLoads();
  return null;
}

/** The folder a `kendex add` in a terminal registered while the window was
 *  away. */
const NEW_PROJECT = "/home/p/dev/vsys-view";

/** The folder that project is reconnected to. */
const MOVED_TO = "/home/p/dev/vsys";

type SettingsReply = Awaited<ReturnType<typeof commands.getSettings>>;

type SettingsData = Extract<SettingsReply, { status: "ok" }>["data"];

const settingsData = (
  projects: string[],
  appearance = "system",
): SettingsData =>
  ({
    settings: {
      schema: 1,
      appearance,
      "harness-roots": {},
      projects,
      zoom: 100,
    },
    base: null,
  }) as unknown as SettingsData;

const settingsRead = (
  projects: string[],
  appearance = "system",
): SettingsReply =>
  ({
    status: "ok",
    data: settingsData(projects, appearance),
  }) as unknown as SettingsReply;

describe("the project registry on window focus", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: null, base: null });
    useCommitOfferStore.setState({ queue: [], scanning: false });
    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "ok",
      data: { state: { state: "signed-out" }, endpoint: "https://kendex.ai" },
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    vi.mocked(commands.getSettings).mockResolvedValue(settingsRead([]));
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
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.appUpdateCheck).mockResolvedValue({
      status: "error",
      error: "no feed in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateCheck>>);
    vi.mocked(commands.appUpdateChannel).mockResolvedValue({
      status: "error",
      error: "no channel in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateChannel>>);
    vi.mocked(commands.appUpdateCommandChannel).mockResolvedValue({
      status: "error",
      error: "no command channel in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateCommandChannel>>);
    vi.mocked(commands.appVersion).mockResolvedValue({
      status: "ok",
      data: "0.0.0-test",
    });
  });

  /** Bring the window back, past the debounce window that holds a second
   *  focus off. */
  async function refocus(): Promise<void> {
    await vi.advanceTimersByTimeAsync(6000);
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    await settle();
  }

  // A `kendex add` in a terminal registers the folder it installed into,
  // and the window has to see that without being restarted. The scan reads
  // the registry itself, so the two are re-read together — otherwise the
  // scan finds the new project's packages while the Projects page draws
  // the list from before the install.
  it("re-reads the registry and the machine when the window comes back", async () => {
    vi.useFakeTimers();
    mount(<Startup />);
    await settle();
    expect(useSettingsStore.getState().settings?.projects).toEqual([]);
    expect(commands.scanMachine).toHaveBeenCalledTimes(1);

    vi.mocked(commands.getSettings).mockResolvedValue(
      settingsRead([NEW_PROJECT]),
    );
    await refocus();

    expect(useSettingsStore.getState().settings?.projects).toEqual([
      NEW_PROJECT,
    ]);
    expect(commands.scanMachine).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  // A command run in a terminal is not a reason to put a modal on screen.
  // The re-read asks the registry and the machine and nothing else: what to
  // do with a project's uncommitted files is a question the write that left
  // them asks, and this window made no write.
  it("asks no question about a project's files because a command ran", async () => {
    vi.useFakeTimers();
    // A project is already tracked when the window comes back, so the
    // question has somewhere to be asked about: a focus that asked one
    // would reach the scan behind it.
    vi.mocked(commands.getSettings).mockResolvedValue(
      settingsRead(["/home/p/dev/app"]),
    );
    mount(<Startup />);
    await settle();
    expect(useSettingsStore.getState().settings?.projects).toEqual([
      "/home/p/dev/app",
    ]);

    vi.mocked(commands.getSettings).mockResolvedValue(
      settingsRead(["/home/p/dev/app", NEW_PROJECT]),
    );
    await refocus();

    expect(commands.commitOfferScan).not.toHaveBeenCalled();
    expect(useCommitOfferStore.getState().queue).toEqual([]);
    vi.useRealTimers();
  });

  // A setting the person saved while the focus read was out is the newer
  // view of the file, and it stays. Both are views of one machine-local
  // file, and a reply older than the newest one held is dropped.
  it("keeps a setting saved while the read was out", async () => {
    vi.useFakeTimers();
    mount(<Startup />);
    await settle();

    let answerTheRead: (read: SettingsReply) => void = () => {};
    vi.mocked(commands.getSettings).mockReturnValue(
      new Promise<SettingsReply>((resolve) => {
        answerTheRead = resolve;
      }),
    );
    vi.mocked(commands.updateSettings).mockResolvedValue(
      settingsRead([NEW_PROJECT], "dark") as unknown as Awaited<
        ReturnType<typeof commands.updateSettings>
      >,
    );
    await refocus();

    // The save lands while the focus read is still out, so its reply is the
    // newer view of the file.
    await act(async () => {
      await useSettingsStore.getState().setAppearance("dark");
    });
    await act(async () => {
      answerTheRead(settingsRead([]));
      await settle();
    });

    expect(useSettingsStore.getState().settings?.appearance).toBe("dark");
    expect(useSettingsStore.getState().settings?.projects).toEqual([
      NEW_PROJECT,
    ]);
    vi.useRealTimers();
  });

  // The other order, and the one the ticket alone cannot place: the save
  // leaves first and the focus read answers first. A read waits on
  // nothing and a write waits on the settings lock, so its newer ticket
  // would become the newest held and drop the save's own reply — the
  // change on disk and off the screen.
  it("keeps a setting whose save left before the read that answered first", async () => {
    vi.useFakeTimers();
    mount(<Startup />);
    await settle();

    let answerTheWrite: (
      read: Awaited<ReturnType<typeof commands.updateSettings>>,
    ) => void = () => {};
    vi.mocked(commands.updateSettings).mockReturnValue(
      new Promise((resolve) => {
        answerTheWrite = resolve;
      }) as ReturnType<typeof commands.updateSettings>,
    );
    // The save leaves first and is still out.
    const saving = useSettingsStore.getState().setAppearance("dark");
    // The window comes back, and the read answers with the file from
    // before the save.
    vi.mocked(commands.getSettings).mockResolvedValue(settingsRead([]));
    await refocus();
    expect(commands.getSettings).toHaveBeenCalledTimes(2);

    await act(async () => {
      answerTheWrite(
        settingsRead([NEW_PROJECT], "dark") as unknown as Awaited<
          ReturnType<typeof commands.updateSettings>
        >,
      );
      await saving;
      await settle();
    });

    expect(useSettingsStore.getState().settings?.appearance).toBe("dark");
    expect(useSettingsStore.getState().settings?.projects).toEqual([
      NEW_PROJECT,
    ]);
    vi.useRealTimers();
  });

  // The completion order a count alone cannot see: the save leaves first,
  // so the read's ticket is the newer one; the save then lands while the
  // read is still out, and the read's reply arrives with nothing
  // outstanding any more. Nothing in the count says a write happened, and
  // the newer ticket would put the file from before the save back on
  // screen with the save already on disk.
  it("keeps a setting whose save landed while the read was still out", async () => {
    vi.useFakeTimers();
    mount(<Startup />);
    await settle();

    let answerTheWrite: (
      read: Awaited<ReturnType<typeof commands.updateSettings>>,
    ) => void = () => {};
    let answerTheRead: (read: SettingsReply) => void = () => {};
    vi.mocked(commands.updateSettings).mockReturnValue(
      new Promise((resolve) => {
        answerTheWrite = resolve;
      }) as ReturnType<typeof commands.updateSettings>,
    );
    vi.mocked(commands.getSettings).mockReturnValue(
      new Promise<SettingsReply>((resolve) => {
        answerTheRead = resolve;
      }),
    );

    // The save leaves first, so the read that follows holds the newer
    // ticket.
    const saving = useSettingsStore.getState().setAppearance("dark");
    await refocus();
    // Then the save lands, while the read is still out.
    await act(async () => {
      answerTheWrite(
        settingsRead([NEW_PROJECT], "dark") as unknown as Awaited<
          ReturnType<typeof commands.updateSettings>
        >,
      );
      await saving;
    });
    expect(useSettingsStore.getState().settings?.appearance).toBe("dark");

    await act(async () => {
      answerTheRead(settingsRead([]));
      await settle();
    });

    expect(useSettingsStore.getState().settings?.appearance).toBe("dark");
    expect(useSettingsStore.getState().settings?.projects).toEqual([
      NEW_PROJECT,
    ]);
    vi.useRealTimers();
  });

  // A reconnect is a write of this file like the other two, and the same
  // order defeats it: the write leaves first, the focus read answers
  // first with the registry from before it, and the read's newer ticket
  // would put the old missing path back on the card with the new one
  // already on disk.
  it("keeps a reconnection whose write left before the read that answered first", async () => {
    vi.useFakeTimers();
    useSettingsStore.setState({ settings: null, base: null });
    vi.mocked(commands.getSettings).mockResolvedValue(
      settingsRead([NEW_PROJECT]),
    );
    mount(<Startup />);
    await settle();

    let answerTheWrite: (
      read: Awaited<ReturnType<typeof commands.relocateProject>>,
    ) => void = () => {};
    vi.mocked(commands.relocateProject).mockReturnValue(
      new Promise((resolve) => {
        answerTheWrite = resolve;
      }) as ReturnType<typeof commands.relocateProject>,
    );
    // The reconnect leaves first and is still out.
    const moving = useSettingsStore
      .getState()
      .relocateProject(NEW_PROJECT, MOVED_TO, false);
    // The window comes back, and the read answers with the registry from
    // before the reconnect.
    await refocus();

    await act(async () => {
      answerTheWrite({
        status: "ok",
        data: {
          read: settingsData([MOVED_TO]),
          was: NEW_PROJECT,
          root: MOVED_TO,
        },
      } as unknown as Awaited<ReturnType<typeof commands.relocateProject>>);
      await moving;
      await settle();
    });

    expect(useSettingsStore.getState().settings?.projects).toEqual([MOVED_TO]);
    vi.useRealTimers();
  });
});
