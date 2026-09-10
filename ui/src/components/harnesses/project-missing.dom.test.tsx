// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Relocation, ScanResult, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  CHANGE_FOLDER_LABEL,
  LOCATE_CONFIRM,
  LOCATE_FOLDER_LABEL,
  LOCATE_JOIN,
  missingBadge,
  missingLead,
  RECONNECT_CLEAN,
  REMOVE_FROM_LIST_LABEL,
  reconnected,
  removeFromList,
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
    // The update standing is read again on a registry write: rows keyed
    // by the folder a project left answer for a place that is not there.
    updatesOverview: vi.fn(),
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

const openActions = async (host: HTMLElement) => {
  const project = card(host);
  if (!project) throw new Error("no card for the missing project");
  const trigger = [
    ...project.querySelectorAll<HTMLButtonElement>("button"),
  ].find((one) => one.getAttribute("aria-label")?.startsWith("More actions"));
  if (!trigger) throw new Error("no actions trigger");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  await settle();
};

const menuItems = (): string[] =>
  [...document.querySelectorAll('[role="menuitem"]')].map(
    (el) => el.textContent ?? "",
  );

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
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
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

  // The card body withholds the install, and the menu behind the same card
  // is the other way to the same errand: browsing on this place's behalf
  // opens the guided install for a place it cannot reach, and what a place
  // installs from is a write into the folder that is not there. What is
  // left is the two actions about the entry itself.
  it("offers nothing that writes to the folder", async () => {
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host);

    expect(menuItems()).toEqual([
      CHANGE_FOLDER_LABEL,
      removeFromList("vsys-view"),
    ]);
  });

  // The same hold before any reading at all. A scan that has not answered
  // names no missing folder and has found none either, and an offer to
  // install under a path nobody has looked at is that silence read as a
  // fact.
  it("offers nothing that writes before a scan has read the machine", async () => {
    useScanStore.setState({ scanning: true, result: null, error: null });
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host);

    expect(menuItems()).toEqual([
      CHANGE_FOLDER_LABEL,
      removeFromList("vsys-view"),
    ]);
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

// Everything the window filed under a folder that has stopped being a
// project — reconnected somewhere else, or removed. None of it is
// corrected by reading the machine again: these are answers about a path,
// and the path is not a project any more.
describe("what a folder leaving the list leaves behind", () => {
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
    useNavStore.setState({
      unmanagedScope: { scope: "project", root: OLD },
      packageRef: {
        kind: "skill",
        name: "gh",
        identity: "recorded",
        scope: { scope: "project", root: OLD },
      },
    });

    await useSettingsStore.getState().relocateProject(OLD, NEW, false);

    expect(useProjectSetupStore.getState().checking).toEqual([]);
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
    expect(useCommitOfferStore.getState().queue).toEqual([]);
    expect(useCommitOfferStore.getState().flagged).toEqual([]);
    expect(useNavStore.getState().unmanagedScope).toEqual({
      scope: "project",
      root: NEW,
    });
    // A package is addressed by the place its copy sits in, so a package
    // ref is one more scope: left naming the old folder, Back reopens the
    // package page on a copy the machine has no record of.
    expect(useNavStore.getState().packageRef).toEqual({
      kind: "skill",
      name: "gh",
      identity: "recorded",
      scope: { scope: "project", root: NEW },
    });
    // What a package's source has moved on to is a fourth read, keyed by
    // the place each row is at and not covered by the rescan.
    expect(commands.updatesOverview).toHaveBeenCalled();
  });

  it("drops them for a project removed from the list too", async () => {
    vi.mocked(commands.unregisterProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: [] }, base: null },
    } as never);
    useProjectSetupStore.setState({ checking: [OLD], unchecked: [OLD] });
    useCommitOfferStore.setState({
      queue: [{ root: OLD, message: "" }] as never,
      flagged: [{ root: OLD }] as never,
    });

    await useSettingsStore.getState().unregisterProject(OLD);

    expect(useProjectSetupStore.getState().checking).toEqual([]);
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
    expect(useCommitOfferStore.getState().queue).toEqual([]);
    expect(useCommitOfferStore.getState().flagged).toEqual([]);
  });
});
