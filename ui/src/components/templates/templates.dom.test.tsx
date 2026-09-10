// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AppSettings,
  Draft_Serialize,
  Member_Serialize,
  Template_Serialize,
} from "@/bindings";
import { commands } from "@/bindings";
import { AddToTemplateDialog } from "@/components/templates/add-to-template-dialog";
import { CreateTemplateDialog } from "@/components/templates/create-template-dialog";
import { InstallTemplateDialog } from "@/components/templates/install-template-dialog";
import { templateSubject } from "@/components/templates/template-subject";
import { TemplatesView } from "@/components/templates/templates-view";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  BROWSE_PACKAGES_LABEL,
  CHOICE_LOCAL,
  COPIES_GO_INTO_THIS_TEMPLATE,
  INCLUDE_CUSTOMIZATIONS_LABEL,
  INCLUDE_LOCAL_LABEL,
  LICENSE_CONFIRM,
  NEW_TEMPLATE_LABEL,
  NO_TEMPLATES_TO_INSTALL,
  TEMPLATES_EMPTY,
  TEMPLATES_LAST_KNOWN,
  TEMPLATES_SEARCH,
  TEMPLATES_UNREADABLE,
  templateSummary,
} from "@/lib/copy-templates";
import { membersFor } from "@/lib/template-members";
import { useInstallFlow } from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useTemplatesStore } from "@/stores/templates";
import { mount, settle } from "@/test/dom";

vi.mock("@/bindings", () => ({
  commands: {
    templatesList: vi.fn(),
    templateDraft: vi.fn(),
    templateCreateFromProject: vi.fn(),
    templateInstall: vi.fn(),
    templateResolve: vi.fn(),
    templateFiles: vi.fn(),
    templateFile: vi.fn(),
    templateAddMembers: vi.fn(),
    templateCreateFromSelection: vi.fn(),
    scanMachine: vi.fn().mockResolvedValue({ status: "ok", data: null }),
    auditAll: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    // The three reads a write runs around itself, each answering the list
    // its command answers with, found empty. They are reached because these
    // cases drive a real install: `writingRepo` takes a commit baseline
    // before the write and reads the machine again behind it, and that read
    // asks what every tracked project has waiting.
    commitOfferBaseline: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    commitOfferScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    projectChangesScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

/** The project every case here installs into or reads a draft from. */
const ACME_ROOT = "/work/acme";

const RUST_SERVICE: Template_Serialize = {
  name: "Rust service",
  id: "rust-service",
  members: [
    {
      kind: "skill",
      name: "code-quality",
      enabled: true,
      source: {
        held: "marketplace",
        repo: "vanillagreencom/kendex",
        rev: null,
      },
    },
    {
      kind: "skill",
      name: "house-style",
      enabled: true,
      source: { held: "copy", copy: "skills/house-style", from: null },
    },
  ],
  customizations: {},
};

const DRAFT: Draft_Serialize = {
  project: "/work/acme",
  suggestedName: "acme",
  members: [
    {
      key: "skill:gh",
      kind: "skill",
      name: "gh",
      enabled: true,
      derived: false,
      requiredBy: [],
      origin: {
        origin: "marketplace",
        repo: "vanillagreencom/kendex",
        source: "kendex",
        rev: null,
      },
    },
  ],
  locals: [
    {
      key: "skill:stray",
      kind: "skill",
      name: "stray",
      at: ".claude/skills/stray",
      hash: "abc",
    },
  ],
  excluded: [
    {
      kind: "agent",
      name: "raw",
      why: "a catalog stores an agent as markdown",
    },
  ],
  customizations: {},
  incomplete: null,
};

beforeEach(() => {
  vi.clearAllMocks();
  useTemplatesStore.setState({
    templates: [],
    everRead: false,
    read: { status: "idle" },
    busy: false,
    refused: null,
  });
  useNavStore.setState({ page: "library", templateName: null, history: [] });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
  // A registered project whose folder a scan opened. Both halves are what
  // makes a place a destination: an install is aimed only at a folder
  // reading found, so a case that seeds the picked places and not the
  // reading behind them asks to write somewhere this machine never
  // confirmed, and the flow offers nothing.
  useSettingsStore.setState({
    settings: { projects: [ACME_ROOT] } as AppSettings,
  });
  useScanStore.setState({
    scanning: false,
    error: null,
    result: {
      harnesses: [],
      items: [],
      warnings: [],
      missingProjects: [],
      readProjects: [ACME_ROOT],
    },
  });
  vi.mocked(commands.templatesList).mockResolvedValue({
    status: "ok",
    data: [],
  });
});

/** Everything on screen, the dialogs included: a dialog renders into a
 *  portal, so its text is on the document rather than under the mount. */
const said = (): string => document.body.textContent ?? "";

/** The one button whose text is exactly this. */
function button(host: HTMLElement | Document, text: string): HTMLButtonElement {
  const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (one) => one.textContent?.trim() === text,
  );
  if (!found) throw new Error(`no button reading ${text}`);
  return found;
}

describe("the Templates tab", () => {
  it("lists what the read answered and opens the one a row names", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    const host = mount(<TemplatesView />);
    await settle();

    expect(host.textContent).toContain("Rust service");
    // The count is the template's own membership, and it says how much of
    // it the template keeps copies of.
    expect(host.textContent).toContain(templateSummary(2, 1));

    const row = button(host, "Rust service");
    await act(async () => row.click());
    expect(useNavStore.getState().page).toBe("template");
    expect(useNavStore.getState().templateName).toBe("Rust service");
  });

  // Nothing saved and a read that failed are different answers, and only
  // one of them is a person with no templates. A failure with nothing
  // behind it must not claim the list is empty.
  it("never claims the list is empty over a read that answered nothing", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "error",
      error: "the templates file could not be read",
    });
    const host = mount(<TemplatesView />);
    await settle();

    expect(host.textContent).toContain("Templates could not be read");
    expect(host.textContent).not.toContain(TEMPLATES_EMPTY);

    // The same read answering makes the empty list a fact, and the note
    // goes with the failure it was about.
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [],
    });
    await act(async () => {
      await useTemplatesStore.getState().load();
    });
    expect(host.textContent).toContain(TEMPLATES_EMPTY);
    expect(host.textContent).not.toContain("Templates could not be read");
  });
});

// The dialog used to read emptiness off the list alone, so an index it
// could not read looked like a person with no templates and offered them
// Browse packages over it. The store now answers with its read state
// attached, and every surface has to say what it shows for a failure.
describe("the install dialog over a read that did not answer", () => {
  const acme = { scope: "project" as const, root: ACME_ROOT };

  it("offers the read again instead of claiming there are none", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "error",
      error: "the templates file could not be read",
    });
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();

    expect(said()).toContain(TEMPLATES_UNREADABLE);
    expect(said()).not.toContain(NO_TEMPLATES_TO_INSTALL);
    expect(said()).toContain(TRY_AGAIN_LABEL);
    // Browsing packages is what a person with no templates is offered, and
    // this is not that person.
    expect(said()).not.toContain(BROWSE_PACKAGES_LABEL);
  });

  it("keeps rows a read landed and heads them as the last answer", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();
    expect(said()).toContain("Rust service");

    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "error",
      error: "the templates file could not be read",
    });
    await act(async () => {
      await useTemplatesStore.getState().load();
    });

    // The rows stand, said to be the last kendex could check, and the
    // install is still offered over them.
    expect(said()).toContain(TEMPLATES_LAST_KNOWN);
    expect(said()).toContain("Rust service");
    expect(said()).not.toContain(NO_TEMPLATES_TO_INSTALL);
  });

  // The inverse, so the rows above cannot pass over a dialog that never
  // says it: a read that answered with none is the one state that claim
  // belongs to.
  it("says there are none only over a read that answered", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [],
    });
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();

    expect(said()).toContain(NO_TEMPLATES_TO_INSTALL);
    expect(said()).toContain(BROWSE_PACKAGES_LABEL);
    expect(said()).not.toContain(TEMPLATES_UNREADABLE);
  });
});

describe("creating a template from a project", () => {
  it("sends the project's managed packages, with both opt-ins off", async () => {
    vi.mocked(commands.templateDraft).mockResolvedValue({
      status: "ok",
      data: DRAFT,
    });
    vi.mocked(commands.templateCreateFromProject).mockResolvedValue({
      status: "ok",
      data: RUST_SERVICE,
    });
    mount(
      <CreateTemplateDialog
        project="/work/acme"
        place="acme"
        open
        onOpenChange={() => {}}
      />,
    );
    await settle();

    // The one sentence that promises the project is left alone.
    expect(document.body.textContent).toContain(COPIES_GO_INTO_THIS_TEMPLATE);
    // What a template cannot carry is named with its reason.
    expect(document.body.textContent).toContain(
      "a catalog stores an agent as markdown",
    );

    await act(async () => button(document, NEW_TEMPLATE_LABEL).click());
    expect(commands.templateCreateFromProject).toHaveBeenCalledWith(
      "/work/acme",
      {
        name: "acme",
        members: ["skill:gh"],
        locals: [],
        sides: {},
        customizations: false,
      },
    );
  });

  it("carries the local packages and the settings when both are ticked", async () => {
    vi.mocked(commands.templateDraft).mockResolvedValue({
      status: "ok",
      data: DRAFT,
    });
    vi.mocked(commands.templateCreateFromProject).mockResolvedValue({
      status: "ok",
      data: RUST_SERVICE,
    });
    mount(
      <CreateTemplateDialog
        project="/work/acme"
        place="acme"
        open
        onOpenChange={() => {}}
      />,
    );
    await settle();

    const tick = (label: string) => {
      const box = [
        ...document.querySelectorAll<HTMLElement>('[role="checkbox"]'),
      ].find((one) => one.getAttribute("aria-label") === label);
      if (!box) throw new Error(`no checkbox labelled ${label}`);
      return box;
    };
    await act(async () => tick(INCLUDE_LOCAL_LABEL).click());
    await act(async () => tick(INCLUDE_CUSTOMIZATIONS_LABEL).click());
    await act(async () => button(document, NEW_TEMPLATE_LABEL).click());

    expect(commands.templateCreateFromProject).toHaveBeenCalledWith(
      "/work/acme",
      {
        name: "acme",
        members: ["skill:gh"],
        locals: ["skill:stray"],
        sides: {},
        customizations: true,
      },
    );
  });
});

describe("installing a template into a place", () => {
  it("hands the guided install the template, and the install writes there", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    vi.mocked(commands.templateInstall).mockResolvedValue({
      status: "ok",
      data: {
        subscribed: [],
        declared: [],
        copied: [],
        notes: [],
        stopped: null,
      },
    });
    const acme = { scope: "project" as const, root: ACME_ROOT };
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();

    await act(async () => button(document, "Install").click());
    // The guided install is what asks where and which tools — this dialog
    // answers only which template.
    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects[0]?.template).toBe("Rust service");
    expect(useNavStore.getState().installInto).toEqual(acme);

    await act(async () => {
      useInstallFlow.setState({ places: [acme] });
      await useInstallFlow.getState().install();
    });
    expect(commands.templateInstall).toHaveBeenCalledWith(
      "Rust service",
      acme,
      null,
      null,
    );
    expect(useInstallFlow.getState().outcome?.places[0]?.wrote).toBe(true);
  });

  // A refused install is reported at the place that refused it, not
  // swallowed into a run that looks like it worked.
  it("reports the place that refused, with the reason", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    vi.mocked(commands.templateInstall).mockResolvedValue({
      status: "error",
      error: "skill 'house-style' is not available",
    });
    const acme = { scope: "project" as const, root: ACME_ROOT };
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();
    await act(async () => button(document, "Install").click());
    await act(async () => {
      useInstallFlow.setState({ places: [acme] });
      await useInstallFlow.getState().install();
    });

    const outcome = useInstallFlow.getState().outcome?.places[0];
    expect(outcome?.wrote).toBe(false);
    expect(outcome?.refused).toBe("skill 'house-style' is not available");
  });
});

describe("saving a marketplace selection into a template", () => {
  it("saves the packages the table ticked into the template that is picked", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    vi.mocked(commands.templateAddMembers).mockResolvedValue({
      status: "ok",
      data: RUST_SERVICE,
    });
    const saveable = membersFor(
      [
        {
          catalog: {
            by: "subscription",
            scope: { scope: "global" },
            source: "kendex",
          },
          row: { kind: "skill", name: "gh" } as never,
          recordsUnreadable: false,
        },
      ],
      [
        {
          scope: { scope: "global" },
          name: "kendex",
          repo: "vanillagreencom/kendex",
        } as never,
      ],
    );
    // The identity a template saves is the repository, never the alias:
    // an alias is a per-place manifest key and a template belongs to no
    // place.
    expect(saveable.members).toEqual([
      {
        kind: "skill",
        name: "gh",
        enabled: true,
        source: {
          held: "marketplace",
          repo: "vanillagreencom/kendex",
          rev: null,
        },
      },
    ]);

    mount(
      <AddToTemplateDialog saveable={saveable} open onOpenChange={() => {}} />,
    );
    await settle();
    await act(async () => button(document, "Save").click());
    expect(commands.templateAddMembers).toHaveBeenCalledWith(
      "Rust service",
      saveable.members,
    );
  });
});

describe("a template install that stopped part-way", () => {
  // The guided install already draws a place that took some of an
  // install and refused the rest. A template that landed one repository
  // and stopped on the next is exactly that, so both halves travel.
  it("reports what landed and why it went no further", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    vi.mocked(commands.templateInstall).mockResolvedValue({
      status: "ok",
      data: {
        subscribed: ["vanillagreencom/kendex"],
        declared: ["skill code-quality"],
        copied: [],
        notes: [],
        stopped: "skill 'house-style' is already here with different bytes",
      },
    });
    const acme = { scope: "project" as const, root: ACME_ROOT };
    mount(<InstallTemplateDialog into={acme} open onOpenChange={() => {}} />);
    await settle();
    await act(async () => button(document, "Install").click());
    await act(async () => {
      useInstallFlow.setState({ places: [acme] });
      await useInstallFlow.getState().install();
    });

    const outcome = useInstallFlow.getState().outcome?.places[0];
    expect(outcome?.wrote).toBe(true);
    expect(outcome?.refused).toBe(
      "skill 'house-style' is already here with different bytes",
    );
  });
});

describe("a marketplace selection nothing can name", () => {
  it("names the rows it cannot record and refuses to save none of them", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    // A row from a bare repository: no subscription, so no repository a
    // template could record it under.
    const saveable = membersFor(
      [
        {
          catalog: { by: "repo", repo: "someone/unsubscribed" },
          row: { kind: "skill", name: "stranger" } as never,
          recordsUnreadable: false,
        },
      ],
      [],
    );
    expect(saveable.members).toEqual([]);
    expect(saveable.dropped).toEqual(["stranger"]);

    mount(
      <AddToTemplateDialog saveable={saveable} open onOpenChange={() => {}} />,
    );
    await settle();
    // The row is named rather than silently missing from a count, and
    // there is nothing to save.
    expect(document.body.textContent).toContain("stranger");
    expect(button(document, "Save").disabled).toBe(true);
  });
});

describe("an edited marketplace package in the modal", () => {
  // Taking the project's copy copies the marketplace's bytes, so the
  // modal asks about the terms before the save does. Core refuses
  // without the answer; this is the surface that collects it.
  it("collects the licence answer and sends it with the save", async () => {
    vi.mocked(commands.templateDraft).mockResolvedValue({
      status: "ok",
      data: {
        ...DRAFT,
        locals: [],
        members: [
          {
            key: "skill:gh",
            kind: "skill",
            name: "gh",
            enabled: true,
            derived: false,
            requiredBy: [],
            origin: {
              origin: "choice",
              repo: "vanillagreencom/kendex",
              source: "kendex",
              rev: null,
              at: ".claude/skills/gh",
              hash: "abc",
              why: null,
              license: "MIT",
              licenseRecognized: true,
            },
          },
        ],
      },
    });
    vi.mocked(commands.templateCreateFromProject).mockResolvedValue({
      status: "ok",
      data: RUST_SERVICE,
    });
    mount(
      <CreateTemplateDialog
        project="/work/acme"
        place="acme"
        open
        onOpenChange={() => {}}
      />,
    );
    await settle();

    // Neither side is chosen, so there is nothing to save yet.
    expect(button(document, NEW_TEMPLATE_LABEL).disabled).toBe(true);
    await act(async () => button(document, CHOICE_LOCAL).click());
    // The terms are shown, and the save still waits on the answer.
    expect(document.body.textContent).toContain("MIT");
    expect(button(document, NEW_TEMPLATE_LABEL).disabled).toBe(true);

    const confirm = [
      ...document.querySelectorAll<HTMLElement>('[role="checkbox"]'),
    ].find((one) => one.getAttribute("aria-label") === LICENSE_CONFIRM);
    if (!confirm) throw new Error("no licence confirmation on screen");
    await act(async () => confirm.click());
    await act(async () => button(document, NEW_TEMPLATE_LABEL).click());

    expect(commands.templateCreateFromProject).toHaveBeenCalledWith(
      "/work/acme",
      {
        name: "acme",
        members: ["skill:gh"],
        locals: [],
        // The answer travels inside the side: a copy cannot be asked
        // for without it.
        sides: {
          "skill:gh": {
            side: "copy",
            license: { confirmed: true, basis: null },
          },
        },
        customizations: false,
      },
    );
  });
});

// The tools picker is built from a subject's kinds, and what a curated set
// holds is the catalog's to say. Naming the direct kinds beside a set — and
// passing a plugin as a package kind, which core resolves as a set — offered
// a narrower list of tools than the set's own members can install to.
describe("the kinds a template subject names", () => {
  /** A template holding whatever members a case needs. */
  const holding = (members: Member_Serialize[]): Template_Serialize => ({
    name: "Mixed",
    id: "mixed",
    members,
    customizations: {},
  });
  const fromMarket = (
    kind: Member_Serialize["kind"],
    name: string,
  ): Member_Serialize => ({
    kind,
    name,
    enabled: true,
    source: {
      held: "marketplace",
      repo: "vanillagreencom/kendex",
      rev: null,
    },
  });

  it("names no kind where a member is a whole set, and the kinds otherwise", () => {
    // Direct members only: the picker can offer exactly what they install to.
    expect(
      templateSubject(
        holding([fromMarket("skill", "gh"), fromMarket("command", "note")]),
      ).kinds,
    ).toEqual(["skill", "command"]);

    // A bundle beside them: what it holds is not knowable from here, so no
    // kind is named and core performs the precise check.
    expect(
      templateSubject(
        holding([fromMarket("skill", "gh"), fromMarket("bundle", "starter")]),
      ).kinds,
    ).toEqual([]);

    // A plugin is its registry's own curated set, and core resolves it as
    // one, so it answers the same way a bundle does.
    expect(
      templateSubject(
        holding([fromMarket("skill", "gh"), fromMarket("plugin", "review")]),
      ).kinds,
    ).toEqual([]);
  });
});

// The "/" shortcut fires from any page and bumps one counter; the box on
// screen is the one that reads it. The Templates box was outside that
// mechanism, so "/" on this tab reached nothing. Only the tab in front is
// mounted — `Tabs.Panel` renders an inactive panel only under
// `keepMounted`, which `pages/library.tsx` does not pass — so the box that
// reads the counter here is always the one a person is looking at.
describe("the search shortcut on the Templates tab", () => {
  it("focuses this tab's search box", async () => {
    vi.mocked(commands.templatesList).mockResolvedValue({
      status: "ok",
      data: [RUST_SERVICE],
    });
    mount(<TemplatesView />);
    await settle();

    const search = document.querySelector(`[aria-label="${TEMPLATES_SEARCH}"]`);
    expect(document.activeElement).not.toBe(search);

    await act(async () => {
      useNavStore.getState().focusSearch();
    });
    await settle();
    expect(document.activeElement).toBe(search);
  });
});
