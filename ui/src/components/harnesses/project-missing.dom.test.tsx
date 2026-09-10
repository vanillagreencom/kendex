// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Relocation, ScanResult, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  LOCATE_CONFIRM,
  LOCATE_FOLDER_LABEL,
  LOCATE_JOIN,
  missingBadge,
  missingLead,
  RECONNECT_CLEAN,
  REMOVE_FROM_LIST_LABEL,
  reconnected,
  standingSaid,
} from "@/lib/copy-project-move";
import { SESSION_NOTE_LABEL } from "@/lib/copy-session-note";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useNavStore } from "@/stores/nav";
import { useProjectSetupStore } from "@/stores/project-setup";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { ProjectList } from "./project-list";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    scanMachine: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    updateSettings: vi.fn(),
    installDriftHook: vi.fn(),
    pickFolder: vi.fn(),
    projectRelocation: vi.fn(),
    relocateProject: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const OLD = "/work/vsys-view";
const NEW = "/work/vsys";
const GONE = { root: OLD, why: { kind: "gone" } } as const;

const scan = (missing: ScanResult["missingProjects"]): ScanResult => ({
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: missing,
});

const view = (scope: Scope) => ({
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

const relocation = (standing: Relocation["standing"]): Relocation => ({
  from: OLD,
  to: NEW,
  standing,
});

const card = (host: HTMLElement): HTMLElement | undefined =>
  [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')].find((one) =>
    one.textContent?.startsWith("vsys-view"),
  );

const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  );
  if (!found) throw new Error(`no ${label} button`);
  return found;
};

const press = async (label: string) => {
  await userEvent.click(button(label));
  await settle();
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: scan([GONE]) as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({
    status: "ok",
    data: [view({ scope: "global" }), view({ scope: "project", root: OLD })],
  } as never);
  vi.mocked(commands.pickFolder).mockResolvedValue({
    status: "ok",
    data: NEW,
  } as never);
  useScanStore.setState({ scanning: false, result: scan([GONE]), error: null });
  useAuditStore.setState({
    views: [view({ scope: "global" }), view({ scope: "project", root: OLD })],
    auditing: false,
    auditedAt: Date.now(),
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
  useProjectSetupStore.setState({ checking: [], unchecked: [] });
  useCommitOfferStore.setState({ queue: [], flagged: [] });
  useSettingsStore.setState({ settings: { projects: [OLD] } as never });
});

// The reported bug: the card said "Nothing from kendex yet" over a folder
// nothing had been read from, offered to write a hook into it, and left
// removing the entry as the only way out.
describe("a project whose folder the scan could not read", () => {
  it("says nothing can be checked, and offers the ways out", async () => {
    const host = mount(<ProjectList />);
    await settle();

    const project = card(host);
    expect(project?.textContent).toContain(missingBadge(GONE.why));
    expect(project?.textContent).toContain(missingLead(GONE.why));
    expect(project?.textContent).toContain(LOCATE_FOLDER_LABEL);
    expect(project?.textContent).toContain(REMOVE_FROM_LIST_LABEL);
    // None of what a read of that folder would have produced: no measured
    // empty place, no offer to write into it, no note about it.
    expect(project?.textContent).not.toContain("Nothing from kendex yet.");
    expect(project?.textContent).not.toContain("Add packages to");
    expect(project?.textContent).not.toContain(SESSION_NOTE_LABEL);
  });

  // A folder that may come back — a disk not mounted yet, a permission
  // about to be granted — is read again on the spot rather than being
  // reconnected somewhere it did not move to.
  it("reads the folder again when asked", async () => {
    mount(<ProjectList />);
    await settle();
    const before = vi.mocked(commands.scanMachine).mock.calls.length;

    await press(TRY_AGAIN_LABEL);

    expect(vi.mocked(commands.scanMachine).mock.calls.length).toBeGreaterThan(
      before,
    );
  });

  it("says what the system said, where it could not read the folder", async () => {
    const unreadable = {
      root: OLD,
      why: { kind: "unreadable" as const, said: "Permission denied (os 13)" },
    };
    useScanStore.setState({ result: scan([unreadable]) });
    const host = mount(<ProjectList />);
    await settle();

    expect(card(host)?.textContent).toContain("Permission denied (os 13)");
    expect(card(host)?.textContent).toContain(missingBadge(unreadable.why));
  });
});

describe("locating the folder a project moved to", () => {
  it("confirms both paths and what the folder holds, then reconnects", async () => {
    vi.mocked(commands.projectRelocation).mockResolvedValue({
      status: "ok",
      data: relocation({ kind: "moved" }),
    } as never);
    vi.mocked(commands.relocateProject).mockResolvedValue({
      status: "ok",
      data: {
        read: { settings: { projects: [NEW] }, base: null },
        was: OLD,
        root: NEW,
      },
    } as never);
    mount(<ProjectList />);
    await settle();

    await press(LOCATE_FOLDER_LABEL);

    expect(commands.projectRelocation).toHaveBeenCalledWith(OLD, NEW);
    expect(document.body.textContent).toContain(OLD);
    expect(document.body.textContent).toContain(NEW);
    expect(document.body.textContent).toContain(
      standingSaid({ kind: "moved" }, "vsys-view"),
    );

    await press(LOCATE_CONFIRM);

    expect(commands.relocateProject).toHaveBeenCalledWith(OLD, NEW, false);
    expect(useSettingsStore.getState().settings?.projects).toEqual([NEW]);
    // The reconnect repairs nothing, so it says what the read that
    // followed it found — never that the project is fixed.
    expect(document.body.textContent).toContain(reconnected("vsys-view", NEW));
    expect(document.body.textContent).toContain(RECONNECT_CLEAN);
  });

  it("explains a folder that belongs to another project and offers no reconnect", async () => {
    vi.mocked(commands.projectRelocation).mockResolvedValue({
      status: "ok",
      data: relocation({ kind: "record-elsewhere", root: "/work/other" }),
    } as never);
    mount(<ProjectList />);
    await settle();

    await press(LOCATE_FOLDER_LABEL);

    expect(document.body.textContent).toContain("/work/other");
    expect(
      [...document.querySelectorAll("button")].map((one) => one.textContent),
    ).not.toContain(LOCATE_CONFIRM);
    expect(commands.relocateProject).not.toHaveBeenCalled();
    expect(useSettingsStore.getState().settings?.projects).toEqual([OLD]);
  });

  it("joins two entries only on the choice that says so", async () => {
    vi.mocked(commands.projectRelocation).mockResolvedValue({
      status: "ok",
      data: relocation({ kind: "registered" }),
    } as never);
    vi.mocked(commands.relocateProject).mockResolvedValue({
      status: "ok",
      data: {
        read: { settings: { projects: [NEW] }, base: null },
        was: OLD,
        root: NEW,
      },
    } as never);
    mount(<ProjectList />);
    await settle();

    await press(LOCATE_FOLDER_LABEL);
    await press(LOCATE_JOIN);

    expect(commands.relocateProject).toHaveBeenCalledWith(OLD, NEW, true);
  });

  it("writes nothing when the confirmation is cancelled", async () => {
    vi.mocked(commands.projectRelocation).mockResolvedValue({
      status: "ok",
      data: relocation({ kind: "moved" }),
    } as never);
    mount(<ProjectList />);
    await settle();

    await press(LOCATE_FOLDER_LABEL);
    await press("Cancel");

    expect(commands.relocateProject).not.toHaveBeenCalled();
    expect(useSettingsStore.getState().settings?.projects).toEqual([OLD]);
  });

  it("asks about nothing when the folder chooser is cancelled", async () => {
    vi.mocked(commands.pickFolder).mockResolvedValue({
      status: "ok",
      data: null,
    } as never);
    mount(<ProjectList />);
    await settle();

    await press(LOCATE_FOLDER_LABEL);

    expect(commands.projectRelocation).not.toHaveBeenCalled();
    expect(useSettingsStore.getState().settings?.projects).toEqual([OLD]);
  });
});

// Everything the window filed under the folder the project left. None of
// it is corrected by reading the machine again: these are answers about a
// path, and the path is not a project any more.
describe("what the reconnect leaves behind", () => {
  it("drops the old folder's held reads, offer and navigation", async () => {
    vi.mocked(commands.relocateProject).mockResolvedValue({
      status: "ok",
      data: {
        read: { settings: { projects: [NEW] }, base: null },
        was: OLD,
        root: NEW,
      },
    } as never);
    useProjectSetupStore.setState({ checking: [OLD], unchecked: [OLD] });
    useCommitOfferStore.setState({
      queue: [{ root: OLD, message: "" }] as never,
      flagged: [{ root: OLD }] as never,
    });
    useNavStore.setState({ unmanagedScope: { scope: "project", root: OLD } });

    await useSettingsStore.getState().relocateProject(OLD, NEW, false);

    expect(useProjectSetupStore.getState().checking).toEqual([]);
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
    expect(useCommitOfferStore.getState().queue).toEqual([]);
    expect(useCommitOfferStore.getState().flagged).toEqual([]);
    expect(useNavStore.getState().unmanagedScope).toEqual({
      scope: "project",
      root: NEW,
    });
  });
});
