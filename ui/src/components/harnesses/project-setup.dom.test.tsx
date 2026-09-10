// @vitest-environment jsdom
// Adding a project, and finding the ones already on this machine.
//
// Registration and the read of what a project holds are separate answers,
// and every case here holds one of them unresolved: an indicator asserted
// after the work has landed passes against a dialog that never drew one.
import userEvent from "@testing-library/user-event";
import { act, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, ScanResult, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { ADD_PACKAGES_LABEL } from "@/lib/copy-install";
import {
  ADD_LABEL,
  ADD_PROJECT_ACTION,
  ADD_THIS_FOLDER,
  ADDING_LABEL,
  ADDING_PROJECT,
  ALREADY_ADDED,
  CHECK_FAILED,
  CHECKING_PACKAGES,
  FIND_PROJECTS_ACTION,
  foundProjects,
  NO_PROJECTS_FOUND,
  searchFailed,
  searchingIn,
} from "@/lib/copy-project-setup";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useProjectSetupStore } from "@/stores/project-setup";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import type { Discovered } from "@/stores/settings-projects";
import { mount, settle } from "@/test/dom";
import { AddProjectDialog } from "./add-project-dialog";
import { FindProjectsDialog } from "./find-projects-dialog";
import { ProjectList } from "./project-list";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    scanMachine: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    pickFolder: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const emptyScan: ScanResult = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
  readProjects: [ACME.root],
};

const view = (scope: Scope): AuditView => ({
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: emptyScan as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({
    status: "ok",
    data: [view({ scope: "global" })],
  });
  useScanStore.setState({ scanning: false, result: emptyScan, error: null });
  useAuditStore.setState({
    views: [view({ scope: "global" })],
    auditing: false,
    auditedAt: Date.now(),
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
  useSettingsStore.setState({ settings: { projects: [] } as never });
  useProjectSetupStore.setState({ checking: [], unchecked: [] });
  useNavStore.setState({ page: "projects", installInto: null });
});

const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  );
  if (!found) throw new Error(`no ${label} button`);
  return found;
};

/** The path field. A dialog draws into a portal, so it is read off the
 *  document rather than off the element the tree was mounted into. */
const field = (): HTMLInputElement => {
  const input = document.querySelector("input");
  if (!input) throw new Error("no path field rendered");
  return input;
};

/** The picker button inside the path field. */
const browse = (): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find((one) =>
    one.getAttribute("aria-label")?.startsWith("Browse"),
  );
  if (!found) throw new Error("no browse button");
  return found;
};

describe("adding a project", () => {
  // The press has to say it landed. A disabled button still reading "Add
  // project" is what left this looking frozen, so the state is asserted
  // while the registry write is still out.
  it("says it is adding while the registry write is out, and sends one", async () => {
    let land: (ok: boolean) => void = () => {};
    const registerProject = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          land = resolve;
        }),
    );
    mount(
      <AddProjectDialog
        open
        onOpenChange={() => {}}
        registerProject={registerProject}
      />,
    );
    await userEvent.type(field(), "/work/acme");
    await userEvent.click(button(ADD_PROJECT_ACTION));
    await settle();

    expect(document.body.textContent).toContain(ADDING_PROJECT);
    // A second press while the first is out would register the same folder
    // twice.
    await userEvent.click(button(ADD_PROJECT_ACTION));
    await settle();
    expect(registerProject).toHaveBeenCalledTimes(1);

    await act(async () => land(true));
  });

  // The dialog closes on the registry write, not on the machine read
  // behind it: the project is a place the moment the registry says so.
  it("closes on the registry write alone", async () => {
    const onOpenChange = vi.fn();
    mount(
      <AddProjectDialog
        open
        onOpenChange={onOpenChange}
        registerProject={async () => true}
      />,
    );
    await userEvent.type(field(), "/work/acme");
    await userEvent.click(button(ADD_PROJECT_ACTION));
    await settle();

    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  // A refused registration keeps the path: retyping it is worse than
  // reading the reason and pressing again.
  it("keeps the dialog and the typed path when registration fails", async () => {
    const onOpenChange = vi.fn();
    mount(
      <AddProjectDialog
        open
        onOpenChange={onOpenChange}
        registerProject={async () => false}
      />,
    );
    await userEvent.type(field(), "/work/acme");
    await userEvent.click(button(ADD_PROJECT_ACTION));
    await settle();

    expect(onOpenChange).not.toHaveBeenCalledWith(false);
    expect(field().value).toBe("/work/acme");
  });
});

/** The dialog as `project-list.tsx` holds it: mounted throughout, opened
 *  and closed by a control outside it, so its own state survives a close. */
const REOPEN = "Reopen";
function ReopenableFind({
  discoverProjects,
}: {
  discoverProjects: (root: string) => Promise<Discovered>;
}) {
  const [open, setOpen] = useState(true);
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>
        {REOPEN}
      </button>
      <FindProjectsDialog
        open={open}
        onOpenChange={setOpen}
        projects={[]}
        registerProject={async () => true}
        discoverProjects={discoverProjects}
      />
    </>
  );
}

describe("finding existing projects", () => {
  const mountFind = (
    discoverProjects: Parameters<
      typeof FindProjectsDialog
    >[0]["discoverProjects"],
    projects: string[] = [],
    registerProject = vi.fn(async () => true),
  ) =>
    mount(
      <FindProjectsDialog
        open
        onOpenChange={() => {}}
        projects={projects}
        registerProject={registerProject}
        discoverProjects={discoverProjects}
      />,
    );

  // Choosing a folder in the picker is the whole request. A second press
  // to say "yes, that one" is the unexplained extra step this removes.
  it("searches the folder the picker returns, with no second press", async () => {
    vi.mocked(commands.pickFolder).mockResolvedValue({
      status: "ok",
      data: "/work",
    });
    let land: (found: { status: "found"; paths: string[] }) => void = () => {};
    const discoverProjects = vi.fn(
      () =>
        new Promise<{ status: "found"; paths: string[] }>((resolve) => {
          land = resolve;
        }),
    );
    mountFind(discoverProjects);

    await userEvent.click(browse());
    await settle();

    expect(discoverProjects).toHaveBeenCalledWith("/work");
    // The searching state is read while the search is still out.
    expect(document.body.textContent).toContain(searchingIn("/work"));
    expect(field().value).toBe("/work");

    await act(async () => land({ status: "found", paths: ["/work/acme"] }));
    await settle();
    expect(document.body.textContent).toContain(foundProjects(1));
  });

  // A typed path is still being filled in as it is typed, so it keeps its
  // own action.
  it("waits for the action on a typed path", async () => {
    const discoverProjects = vi.fn(async () => ({
      status: "found" as const,
      paths: [],
    }));
    mountFind(discoverProjects);

    await userEvent.type(field(), "/work");
    expect(discoverProjects).not.toHaveBeenCalled();

    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(discoverProjects).toHaveBeenCalledWith("/work");
  });

  // Four results, each with its own way on: add one of these, add the
  // folder itself, or try the read again. Nothing folds a failure into an
  // empty result — the folder kendex could not read may be full of
  // projects.
  it("always reports what the search came back with", async () => {
    const answers: Discovered[] = [
      { status: "found", paths: ["/work/acme", "/work/beta"] },
      { status: "found", paths: [] },
      { status: "failed", reason: "/nope is not a directory" },
    ];
    let next = 0;
    // One dialog, three searches: the panel has to change with each
    // answer, and three dialogs in the document would let one case read
    // another's result.
    mountFind(async () => answers[next++]);

    await userEvent.type(field(), "/work");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(document.body.textContent).toContain(foundProjects(2));

    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(document.body.textContent).toContain(NO_PROJECTS_FOUND);
    expect(document.body.textContent).toContain(ADD_THIS_FOLDER);

    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(document.body.textContent).toContain(searchFailed("/work"));
    expect(document.body.textContent).toContain("/nope is not a directory");
    expect(document.body.textContent).not.toContain(NO_PROJECTS_FOUND);
    expect(button(TRY_AGAIN_LABEL)).toBeTruthy();
    // The path searched is still in the field, so trying again is a press
    // rather than typing it out afresh.
    expect(field().value).toBe("/work");
  });

  // A result already registered is not offered again, and one being added
  // says so on its own row rather than putting every row into a state its
  // own press did not cause.
  it("shows per-result progress and what is already added", async () => {
    let land: (ok: boolean) => void = () => {};
    const registerProject = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          land = resolve;
        }),
    );
    mountFind(
      async () => ({ status: "found", paths: ["/work/acme", "/work/beta"] }),
      ["/work/beta"],
      registerProject,
    );
    await userEvent.type(field(), "/work");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();

    expect(button(ALREADY_ADDED).disabled).toBe(true);
    await userEvent.click(button(ADD_LABEL));
    await settle();

    expect(registerProject).toHaveBeenCalledWith("/work/acme");
    expect(button(ADDING_LABEL).disabled).toBe(true);
    // The other row is untouched by a press that was not its own.
    expect(button(ALREADY_ADDED)).toBeTruthy();

    await act(async () => land(true));
  });

  // The registry stores the canonical path, so a folder added under the
  // spelling the reader typed is in `projects` under a name this panel
  // never saw. Compared against that list alone the button goes back to
  // offering it, and a second press meets a duplicate-registration
  // refusal.
  it("keeps a folder added under a spelling the registry rewrote", async () => {
    const registerProject = vi.fn(async () => true);
    mountFind(
      async () => ({ status: "found", paths: [] }),
      // What the registry holds afterwards: the canonical root, not the
      // typed one.
      ["/home/u/work"],
      registerProject,
    );
    await userEvent.type(field(), "~/work");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();

    await userEvent.click(button(ADD_THIS_FOLDER));
    await settle();

    expect(registerProject).toHaveBeenCalledWith("~/work");
    expect(button(ALREADY_ADDED).disabled).toBe(true);
  });

  // A refused registration is not an addition: the offer stands so the
  // reader can act on the reason and press again.
  it("keeps offering a folder whose registration was refused", async () => {
    mountFind(
      async () => ({ status: "found", paths: [] }),
      [],
      vi.fn(async () => false),
    );
    await userEvent.type(field(), "~/work");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();

    await userEvent.click(button(ADD_THIS_FOLDER));
    await settle();

    expect(button(ADD_THIS_FOLDER).disabled).toBe(false);
  });

  // A dismissed search's answer is not this dialog's state. `discoverProjects`
  // cannot be called off, so an abandoned answer landing on the panel would
  // reopen the dialog showing the result of a search the reader closed.
  it("drops the answer to a search that was dismissed", async () => {
    let land: (found: Discovered) => void = () => {};
    const discoverProjects = vi.fn(
      () =>
        new Promise<Discovered>((resolve) => {
          land = resolve;
        }),
    );
    let open = true;
    const host = mount(
      <FindProjectsDialog
        open
        onOpenChange={(next) => {
          open = next;
        }}
        projects={[]}
        registerProject={vi.fn(async () => true)}
        discoverProjects={discoverProjects}
      />,
    );
    await userEvent.type(field(), "/work");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(document.body.textContent).toContain(searchingIn("/work"));

    await userEvent.click(button("Done"));
    await settle();
    expect(open).toBe(false);

    await act(async () => land({ status: "found", paths: ["/work/acme"] }));
    await settle();
    expect(host.ownerDocument.body.textContent).not.toContain(foundProjects(1));
  });

  // The same rule across a dismissal: the reader closes one search, opens
  // the dialog again and starts another, and the first answer arrives
  // last. Only the newest may land, or the abandoned search's result
  // replaces the one on screen. The dialog holds its own state across a
  // close — `project-list.tsx` keeps it mounted — so the answer really can
  // outlive the panel it was started on. It is not reachable inside one
  // open dialog: the field and both actions are disabled while a search is
  // out.
  it("drops the answer to a search a later one superseded", async () => {
    const answers: ((found: Discovered) => void)[] = [];
    const discoverProjects = vi.fn(
      () =>
        new Promise<Discovered>((resolve) => {
          answers.push(resolve);
        }),
    );
    mount(<ReopenableFind discoverProjects={discoverProjects} />);

    await userEvent.type(field(), "/first");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    await userEvent.click(button("Done"));
    await settle();

    await userEvent.click(button(REOPEN));
    await settle();
    // The path the dismissed search used is still in the field, which is
    // the point of keeping it — the second search names its own folder.
    await userEvent.clear(field());
    await userEvent.type(field(), "/second");
    await userEvent.click(button(FIND_PROJECTS_ACTION));
    await settle();
    expect(document.body.textContent).toContain(searchingIn("/second"));

    // The abandoned search answers last, and says nothing.
    await act(async () =>
      answers[1]({ status: "found", paths: ["/second/acme"] }),
    );
    await act(async () =>
      answers[0]({ status: "found", paths: ["/a", "/b", "/c"] }),
    );
    await settle();

    expect(document.body.textContent).toContain(foundProjects(1));
    expect(document.body.textContent).not.toContain(foundProjects(3));
  });
});

describe("a project's card while its contents are being read", () => {
  // Registered, and what it holds still unknown. Zero packages would be a
  // checked result the card has not got.
  it("says the check is running rather than showing an empty place", () => {
    useSettingsStore.setState({
      settings: { projects: [ACME.root] } as never,
    });
    useProjectSetupStore.setState({ checking: [ACME.root], unchecked: [] });
    const host = mount(<ProjectList />);

    const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
      .filter((el) => el.textContent?.startsWith("acme"))
      .at(0);
    expect(card?.textContent).toContain(CHECKING_PACKAGES);
    expect(card?.textContent).not.toContain("Nothing from kendex yet.");
  });

  // The project is added either way, which is what the first half of the
  // sentence says. The read is the half that can be tried again.
  it("says the project is added and the check failed, with a way to try again", async () => {
    useSettingsStore.setState({
      settings: { projects: [ACME.root] } as never,
    });
    useProjectSetupStore.setState({ checking: [], unchecked: [ACME.root] });
    const host = mount(<ProjectList />);
    await settle();

    const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
      .filter((el) => el.textContent?.startsWith("acme"))
      .at(0);
    expect(card?.textContent).toContain(CHECK_FAILED);

    const retry = [...(card?.querySelectorAll("button") ?? [])].find(
      (one) => one.textContent === TRY_AGAIN_LABEL,
    );
    if (!retry) throw new Error("no retry on the card");
    await userEvent.click(retry);
    await settle();
    expect(useProjectSetupStore.getState().unchecked).toEqual([]);
  });

  // The next step from a place with nothing in it, on the card that says
  // so — and it carries the project, so the guided install opens on it.
  it("browses on the project's behalf from the card", async () => {
    useSettingsStore.setState({
      settings: { projects: [ACME.root] } as never,
    });
    const host = mount(<ProjectList />);
    await settle();

    const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
      .filter((el) => el.textContent?.startsWith("acme"))
      .at(0);
    const add = [...(card?.querySelectorAll("button") ?? [])].find((one) =>
      one.textContent?.startsWith(ADD_PACKAGES_LABEL),
    );
    if (!add) throw new Error("no add-packages button on the card");
    await userEvent.click(add);
    await settle();

    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(useNavStore.getState().marketplacesTab).toBe("packages");
    expect(useNavStore.getState().installInto).toEqual(ACME);
  });
});
