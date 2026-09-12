// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  DriftRow,
  HarnessId,
  ObservedItem,
  ProjectChanges,
  ScanResult,
  Scope,
} from "@/bindings";
import { commands, PACKAGE_CHECK_HARNESSES } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { updateRow } from "@/components/updates-test-rows";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  PLACE_COUNTING_LABEL,
  PLACE_UNCHECKED_LABEL,
  unmanagedHereLabel,
} from "@/lib/copy";
import { NOT_CHECKED_BADGE } from "@/lib/copy-commit-offer";
import { ADD_PACKAGES_LABEL } from "@/lib/copy-install";
import {
  PLACE_MARKETPLACES_LABEL,
  placeMarketplacesTitle,
} from "@/lib/copy-model";
import {
  ENABLE_CHECKS_LABEL,
  INCOMPLETE_MEANS,
  notRunningIn,
  ON_MEANS,
  PACKAGE_CHECKS_LABEL,
  runsIn,
  STATE_UNKNOWN,
  UNKNOWN_MEANS,
} from "@/lib/copy-package-checks";
import {
  CHANGE_FOLDER_LABEL,
  REMOVE_FROM_LIST_LABEL,
  removeFromList,
} from "@/lib/copy-project-move";
import {
  CREATE_FROM_PROJECT_LABEL,
  INSTALL_TEMPLATE_LABEL,
} from "@/lib/copy-templates";
import {
  outOfDateHereLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_REVIEW_CONFIRM,
  updateReviewManyTitle,
} from "@/lib/copy-updates";
import { kindLabel } from "@/lib/labels";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useLibraryViewStore } from "@/stores/library-view";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useProjectChangesStore } from "@/stores/project-changes";
import { useProjectSetupStore } from "@/stores/project-setup";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";
import { ProjectList } from "./project-list";

vi.mock("@/bindings", () => ({
  PACKAGE_CHECK_HARNESSES: ["claude", "pi"] as const,
  commands: {
    templatesList: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    scanMachine: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    updateSettings: vi.fn(),
    enablePackageChecks: vi.fn(),
    packageCheckPlan: vi.fn(),
    // The passive read of what each tracked project has waiting for a
    // commit, which the card's own Review changes line draws from.
    projectChangesScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    // Read again on a registry write: update rows are keyed by the
    // folder each one is at.
    updatesOverview: vi.fn(),
    packageDiff: vi.fn().mockResolvedValue({
      status: "ok",
      data: {
        files: [],
        totalAdditions: 0,
        totalDeletions: 0,
        truncated: false,
      },
    }),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

/** A machine a scan has read, having opened every project folder these
 *  cases register: what a place's own actions are offered from. */
const emptyScan: ScanResult = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
  readProjects: ["/work/acme", "/work/client"],
};

const view = (scope: Scope, drift: DriftRow[]): AuditView => ({
  scope,
  drift,
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

const byHand = (name: string): DriftRow => ({
  kind: "skill",
  name,
  harness: "claude",
  state: "unmanaged",
  detail: `/work/acme/.claude/skills/${name}`,
  scope: ACME,
});

beforeEach(() => {
  vi.clearAllMocks();
  // The offer to fill a freshly added project outlives the write that
  // raised it, by design: it is a dialog somebody answers. Cleared here so
  // one case's registration does not leave it open over the next.
  useProjectSetupStore.setState({ justAdded: null });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: emptyScan as never,
  });
  useScanStore.setState({ scanning: false, result: emptyScan, error: null });
  useAuditStore.setState({
    views: [view({ scope: "global" }, [])],
    auditing: false,
    auditedAt: Date.now(),
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
  useSettingsStore.setState({ settings: { projects: [] } as never });
});

// The card's count is the app's only mention of unmanaged content, and the
// only way to the page that offers to take it on. A project registered while
// this page is open has no AuditView until something asks for one, and a
// scope with no view counts zero — so the card would hide the very items
// that project holds.
describe("a project added while the list is on screen", () => {
  it("counts what it holds, without a revisit", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: {
        read: { settings: { projects: ["/work/acme"] }, base: null },
        root: "/work/acme",
      } as never,
    });
    // The audit the registration forces is the one that first sees the
    // project at all.
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [
        view({ scope: "global" }, []),
        view(ACME, [byHand("gh"), byHand("lint")]),
      ],
    });

    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).not.toContain(unmanagedHereLabel(2));
    const beforeRegistering = vi.mocked(commands.auditAll).mock.calls.length;

    await act(async () => {
      await useSettingsStore.getState().registerProject("/work/acme");
    });
    await settle();

    expect(commands.auditAll).toHaveBeenCalled();
    expect(vi.mocked(commands.auditAll).mock.calls.length).toBeGreaterThan(
      beforeRegistering,
    );
    expect(host.textContent).toContain(unmanagedHereLabel(2));
  });
});

// The checks line is the card's, wired to the scan and the audit the list
// already reads. What it may say is decided per tool: the check is on only
// where every tool this installation registers it in runs it, and a card
// that cannot be read says so rather than vanishing. The words are the
// copy's own, so a relabel fails here.
describe("package checks on a project's card", () => {
  const rendered = (harness: HarnessId, root = "/work/acme"): ObservedItem =>
    installed({
      kind: "hook",
      name: "SessionStart:*:kendex-drift",
      harness,
      scope: { scope: "project", root },
      path: `${root}/.claude/settings.json`,
    });

  const onProject = () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
  };

  /** Tell the join that every hook the scan saw is kendex's own. The card
   *  reads whose a hook is from the record of what installed it, never
   *  from its name, so a scan alone establishes no On. */
  const oursByRecord = () => {
    const scanned = useScanStore.getState().result?.items ?? [];
    useProvenanceStore.setState({
      rows: scanned.map((item) => ({
        scope: item.scope,
        kind: item.kind,
        name: item.name,
        harness: item.harness,
        at: item.at,
        origin: {
          origin: "own" as const,
          forkedFrom: null,
          source: "local",
        },
        summary: null,
        package: { kind: item.kind, name: item.name },
      })),
      loaded: true,
      answeredFor: useScanStore.getState().generation,
      read: READ_LANDED,
    });
  };

  it("says On only once every supported tool runs the check", async () => {
    onProject();
    useScanStore.setState({
      scanning: false,
      error: null,
      result: {
        ...emptyScan,
        items: PACKAGE_CHECK_HARNESSES.map((harness) => rendered(harness)),
      },
    });
    oursByRecord();
    const host = mount(<ProjectList />);
    await settle();
    const cards = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')];
    const personal = cards.find((el) => el.textContent?.startsWith("Personal"));
    const acme = cards.find((el) => el.textContent?.startsWith("acme"));
    expect(acme?.textContent).toContain(ON_MEANS);
    expect(acme?.textContent).toContain(runsIn([...PACKAGE_CHECK_HARNESSES]));
    expect(personal?.textContent).not.toContain(PACKAGE_CHECKS_LABEL);
  });

  // One discovered registration is not the whole promise. A card reading
  // "On" off the first tool it finds would say the check runs where it
  // does not.
  it("says the setup is incomplete while a supported tool is not registered", async () => {
    onProject();
    useScanStore.setState({
      scanning: false,
      error: null,
      result: { ...emptyScan, items: [rendered("claude")] },
    });
    oursByRecord();
    useAuditStore.setState({ views: [view(ACME, [])] });
    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).toContain(INCOMPLETE_MEANS);
    expect(host.textContent).toContain(runsIn(["claude"]));
    expect(host.textContent).toContain(notRunningIn(["pi"]));
  });

  // Declared and nothing rendered is the audit's to say: the install ran
  // with other changes pending, so only the declaration landed. A card
  // reading the scan alone would say Off, with a button that re-runs an
  // install already declared.
  it("says the setup is incomplete from the audit's missing row", async () => {
    onProject();
    useAuditStore.setState({
      views: [
        view(ACME, [
          {
            kind: "hook",
            name: "kendex-drift",
            harness: "claude",
            state: "missing",
            detail: "not registered yet",
            scope: ACME,
          },
        ]),
      ],
    });
    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).toContain(INCOMPLETE_MEANS);
  });

  // The audit reads every place over seconds, and a cold start can fail it
  // outright. "Off" at first paint would claim a state the app has not
  // checked, on a card whose check may be declared and waiting — and the
  // line stays on screen, because a card that drops it leaves the reader
  // with nothing to read at all.
  it("says Unknown and offers nothing until the audit has answered", async () => {
    onProject();
    useAuditStore.setState({ views: [view({ scope: "global" }, [])] });
    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).toContain(PACKAGE_CHECKS_LABEL);
    expect(host.textContent).toContain(STATE_UNKNOWN);
    expect(button(host, ENABLE_CHECKS_LABEL)).toBeUndefined();
    // Nothing failed here — the reads are still out — so the line says
    // what it does not know rather than reporting a failure.
    expect(useScanStore.getState().error).toBeNull();
    expect(host.textContent).toContain(UNKNOWN_MEANS);
  });

  // A hook wearing the check's name that a marketplace package installed.
  // The scan sees exactly what an On card sees; only the record of what
  // put it there differs, and that is the whole of whose it is.
  it("does not report a marketplace hook of the same name as On", async () => {
    onProject();
    useScanStore.setState({
      scanning: false,
      error: null,
      result: {
        ...emptyScan,
        items: PACKAGE_CHECK_HARNESSES.map((harness) => rendered(harness)),
      },
    });
    const scanned = useScanStore.getState().result?.items ?? [];
    useProvenanceStore.setState({
      rows: scanned.map((item) => ({
        scope: item.scope,
        kind: item.kind,
        name: item.name,
        harness: item.harness,
        at: item.at,
        origin: { origin: "marketplace" as const, source: "cat", repo: "o/c" },
        summary: null,
        package: { kind: item.kind, name: item.name },
      })),
      loaded: true,
      answeredFor: useScanStore.getState().generation,
      read: READ_LANDED,
    });
    useAuditStore.setState({ views: [view(ACME, [])] });
    const host = mount(<ProjectList />);
    await settle();
    const acme = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
      .filter((el) => el.textContent?.startsWith("acme"))
      .at(0);
    expect(acme?.textContent).toContain(STATE_UNKNOWN);
    expect(acme?.textContent).not.toContain(ON_MEANS);
    expect(button(host, ENABLE_CHECKS_LABEL)).toBeUndefined();
  });

  // The scan store keeps the last good result through a failure, which is
  // right for the pages drawing figures off it. Read here as this pass's
  // observations it is a read that did not happen: a card saying the check
  // runs, with a button offering to install over it, on evidence nothing
  // gathered.
  it("says Unknown and offers nothing after a scan that failed", async () => {
    onProject();
    useScanStore.setState({
      scanning: false,
      error: "the machine could not be read",
      // What a landed scan would have to say for the card to read On.
      result: {
        ...emptyScan,
        items: PACKAGE_CHECK_HARNESSES.map((harness) => rendered(harness)),
      },
    });
    useAuditStore.setState({ views: [view(ACME, [])] });
    const host = mount(<ProjectList />);
    await settle();
    const acme = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
      .filter((el) => el.textContent?.startsWith("acme"))
      .at(0);
    expect(acme?.textContent).toContain(STATE_UNKNOWN);
    expect(acme?.textContent).not.toContain(ON_MEANS);
    expect(button(host, ENABLE_CHECKS_LABEL)).toBeUndefined();
  });
});

/** Open the actions menu on the card whose name starts with `name`. A
 *  base-ui trigger does not open on a click under jsdom. */
async function openActions(host: HTMLElement, name: string): Promise<void> {
  const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
    .filter((el) => el.textContent?.startsWith(name))
    .at(0);
  if (!card) throw new Error(`no card for ${name}`);
  const trigger = [...card.querySelectorAll<HTMLButtonElement>("button")].find(
    (one) => one.getAttribute("aria-label")?.startsWith("More actions"),
  );
  if (!trigger) throw new Error(`no actions trigger on the ${name} card`);
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
}

const menuItems = (): string[] =>
  [...document.querySelectorAll('[role="menuitem"]')].map(
    (el) => el.textContent ?? "",
  );

// Every setting that decides what a place installs is reached from that
// place's card — the marketplaces it installs from included, since the
// marketplace's own page changes none of them. Personal is a place like any
// other, and Personal has no folder to change and no entry to remove.
describe("a place card's actions", () => {
  beforeEach(() => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
    useMarketplacesStore.setState({ rows: [], load: vi.fn(async () => {}) });
    useNavStore.setState({ page: "projects" });
  });

  // The menu sits in the card's action slot, and the card is a whole-surface
  // shortcut into the Library. A menu popup is a portal, so its clicks come
  // back up the React tree through the card — a click that opened the dialog
  // and left the page would leave the reader in the Library with the dialog
  // unmounted, which is every item on this menu.
  it("opens that place's marketplaces from the card that names it", async () => {
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "acme");
    expect(menuItems()).toEqual([
      ADD_PACKAGES_LABEL,
      INSTALL_TEMPLATE_LABEL,
      CREATE_FROM_PROJECT_LABEL,
      PLACE_MARKETPLACES_LABEL,
      CHANGE_FOLDER_LABEL,
      removeFromList("acme"),
    ]);

    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent === PLACE_MARKETPLACES_LABEL,
    );
    if (!(item instanceof HTMLElement)) throw new Error("no marketplaces item");
    await userEvent.click(item);
    await settle();
    expect(document.body.textContent).toContain(placeMarketplacesTitle("acme"));
    expect(useNavStore.getState().page).toBe("projects");
  });

  // The menu withholds every write once the folder cannot be read, and a
  // dialog already open is the same write one step past the menu: its
  // controls rewrite this place's manifest, and a write aimed at a folder
  // nothing was read from is what the guard exists to stop. A folder goes
  // unreadable while a window is open — a rescan on focus, an unmounted
  // disk — so the dialog closes on the same bit the menu reads.
  it("closes an open marketplaces dialog when the folder stops being readable", async () => {
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "acme");
    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent === PLACE_MARKETPLACES_LABEL,
    );
    if (!(item instanceof HTMLElement)) throw new Error("no marketplaces item");
    await userEvent.click(item);
    await settle();
    expect(document.body.textContent).toContain(placeMarketplacesTitle("acme"));

    await act(async () => {
      useScanStore.setState({
        result: {
          ...emptyScan,
          readProjects: ["/work/client"],
          missingProjects: [
            { root: "/work/acme", why: { kind: "gone" } },
          ] as never,
        },
      });
    });
    await settle();

    expect(document.body.textContent).not.toContain(
      placeMarketplacesTitle("acme"),
    );
  });

  it("offers Personal its marketplaces and nothing about a folder", async () => {
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "Personal");
    // Personal is a place, so it takes a template like any other; it is
    // not a project, so there is nothing to create one from and nothing to
    // stop tracking.
    expect(menuItems()).toEqual([
      ADD_PACKAGES_LABEL,
      INSTALL_TEMPLATE_LABEL,
      PLACE_MARKETPLACES_LABEL,
    ]);
  });

  // Removal moved off its own button and into this menu, and a menu item
  // is the shape whose click the card used to answer. Rendering the item
  // proves nothing about the path behind it: the removal has to reach the
  // settings store with this card's own root, and the card must not
  // navigate out from under the confirm.
  it("removes the project the card names, without leaving the page", async () => {
    vi.mocked(commands.unregisterProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: [] }, base: null } as never,
    });
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "acme");
    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent === removeFromList("acme"),
    );
    if (!(item instanceof HTMLElement)) throw new Error("no removal item");
    await userEvent.click(item);
    await settle();
    expect(useNavStore.getState().page).toBe("projects");

    const confirm = [...document.querySelectorAll("button")].find(
      (one) => one.textContent === REMOVE_FROM_LIST_LABEL,
    );
    if (!confirm) throw new Error("no confirm");
    await userEvent.click(confirm);
    await settle();

    expect(commands.unregisterProject).toHaveBeenCalledWith("/work/acme");
    expect(useNavStore.getState().page).toBe("projects");
  });

  // Two roots ending in the same folder name the same card, and the menu
  // opens dialogs that say whose files an action rewrites. The names come
  // from the one collision-aware rule, so each card's menu and each dialog
  // it opens names one project.
  it("names two projects whose folders share a name apart", async () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/client", "/personal/client"] } as never,
    });
    const host = mount(<ProjectList />);
    await settle();

    // Both cards head as "client" — their paths are right beneath them —
    // so the first one is /work/client, the order settings names them in.
    await openActions(host, "client");
    expect(menuItems()).toEqual([
      ADD_PACKAGES_LABEL,
      INSTALL_TEMPLATE_LABEL,
      CREATE_FROM_PROJECT_LABEL,
      PLACE_MARKETPLACES_LABEL,
      CHANGE_FOLDER_LABEL,
      removeFromList("/work/client"),
    ]);

    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent === PLACE_MARKETPLACES_LABEL,
    );
    if (!(item instanceof HTMLElement)) throw new Error("no marketplaces item");
    await userEvent.click(item);
    await settle();
    expect(document.body.textContent).toContain(
      placeMarketplacesTitle("/work/client"),
    );
    expect(document.body.textContent).not.toContain(
      placeMarketplacesTitle("client"),
    );
  });
});

const installed = (overrides: Partial<ObservedItem>): ObservedItem =>
  observed({
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    path: "/h/.claude/skills/deploy",
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    summary: null,
    action: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
    ...overrides,
  });

// Personal holds two skills over three installations: one of them is applied
// to two harnesses. Counting installations puts 3 on the card's badge over a
// table of 2 rows, which is what these cases are here to catch. The project's
// own skill is at another place and belongs to neither number.
const machine: ScanResult = {
  ...emptyScan,
  items: [
    installed({}),
    installed({ harness: "codex", path: "/h/.codex/skills/deploy" }),
    installed({ name: "lint", path: "/h/.claude/skills/lint" }),
    installed({
      name: "release",
      scope: ACME,
      path: "/work/acme/.claude/skills/release",
    }),
  ],
};

// Read off the badge's own wording rather than a second copy of it here, so
// a relabelled kind fails as a missing badge rather than passing vacuously.
const SKILL_BADGE = new RegExp(
  `^(\\d+) (${kindLabel("skill", 1)}|${kindLabel("skill", 2)})$`,
);

/** The skills badge on the card whose name button reads `name`. */
function skillBadge(host: HTMLElement, name: string): HTMLButtonElement {
  const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
    .filter((el) => el.textContent?.startsWith(name))
    .at(0);
  if (!card) throw new Error(`no card for ${name}`);
  const badge = [...card.querySelectorAll<HTMLButtonElement>("button")].find(
    (b) => SKILL_BADGE.test(b.textContent ?? ""),
  );
  if (!badge) throw new Error(`no skills badge on the ${name} card`);
  return badge;
}

const badgeCount = (host: HTMLElement, name: string): number =>
  Number(SKILL_BADGE.exec(skillBadge(host, name).textContent ?? "")?.[1]);

/** The rows the Library actually renders for the view the click handed it. */
const destinationRows = (): number =>
  mount(<InstalledView />).querySelectorAll("tbody tr").length;

// A badge is a promise about the page behind it. The Library shows one row
// per package however many harnesses or places carry it, so a badge counting
// installations lands on a table shorter than the number just clicked.
describe("a place card's kind badge", () => {
  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({ scanning: false, result: machine, error: null });
    // What the fixture means by a package held in two places: each name is
    // one recorded package, whichever place or tool holds a copy. Said to
    // the join, because that is what establishes it — two files wearing
    // one name establish nothing on their own.
    joinAnswered(
      (useScanStore.getState().result?.items ?? []).map((item) => ({
        scope: item.scope,
        kind: item.kind,
        name: item.name,
        harness: item.harness,
        at: item.path,
        origin: { origin: "marketplace" as const, source: "cat", repo: "o/r" },
        summary: null,
        package: { kind: item.kind, name: item.name },
      })),
    );
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
    useNavStore.setState({
      page: "projects",
      libraryFilter: null,
      libraryScope: "all",
      search: "",
    });
    useLibraryViewStore.setState({
      kind: "any",
      harness: "any",
      tag: "any",
      from: "any",
    });
  });

  it("shows the row count of the view its click opens", () => {
    const host = mount(<ProjectList />);
    const badge = badgeCount(host, "Personal");
    expect(badge).toBe(2);
    expect(badgeCount(host, "acme")).toBe(1);

    act(() => skillBadge(host, "Personal").click());
    expect(useNavStore.getState().libraryFilter).toEqual({
      scope: "global",
      kind: "skill",
    });
    expect(badge).toBe(destinationRows());
  });

  // A package whose rendering was deleted by hand is installed at this
  // place — the record says so, and the Library's table the badge opens
  // stands its row up from the same rows. A badge without it lands on a
  // table one row longer than its number. Those rows are also what a failed
  // re-check was asked to confirm, so the badges go rather than publishing
  // a number short by exactly them, and the card says which read is missing.
  it("counts a package with no copy left, and says so when nothing may count it", () => {
    const gone = updateRow("orch", ACME.root, { filesMissing: true });
    const cases: [string, ReadState, number | null, string | null][] = [
      [
        "a read that landed counts it beside the one on disk",
        READ_LANDED,
        2,
        null,
      ],
      [
        "a re-check that failed over the rows it kept counts nothing",
        readFailed("no network"),
        null,
        PLACE_UNCHECKED_LABEL,
      ],
      [
        "a read still on its way is not a failure and says so",
        READ_PENDING,
        null,
        PLACE_COUNTING_LABEL,
      ],
    ];
    expect(cases).toHaveLength(3);
    for (const [name, read, count, said] of cases) {
      useUpdatesStore.setState({ rows: [gone], read });
      const host = mount(<ProjectList />);
      const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
        .filter((el) => el.textContent?.startsWith("acme"))
        .at(0);
      if (!card) throw new Error("no acme card");
      if (count !== null) {
        expect(badgeCount(host, "acme"), name).toBe(count);
      } else {
        expect(
          [...card.querySelectorAll("button")].some((one) =>
            SKILL_BADGE.test(one.textContent ?? ""),
          ),
          name,
        ).toBe(false);
        // Nor the offer worded for a place with nothing in it, which is the
        // same wrong claim the badges are withholding.
        expect(
          [...card.querySelectorAll("button")].some((one) =>
            one.textContent?.startsWith(ADD_PACKAGES_LABEL),
          ),
          name,
        ).toBe(false);
      }
      if (said !== null) expect(card.textContent, name).toContain(said);
    }
  });

  // A place the update read could not cover at all contributes no rows, so
  // the packages there whose rendering is gone are missing from its badges
  // and nothing on the card would say so. The card's own rule — only a
  // landed read puts a number on it, and a place the read could not cover
  // has no number to put — is what `outOfDate` already follows.
  it("puts no number on a place the update read could not cover", () => {
    const cases: [string, Scope[], number | null][] = [
      ["a place the read covered", [], 1],
      ["a place it could not read", [ACME], null],
    ];
    expect(cases).toHaveLength(2);
    for (const [name, places, count] of cases) {
      useUpdatesStore.setState({
        rows: [],
        read: READ_LANDED,
        unreadable: places.map((scope) => ({ scope, message: "no lock" })),
      });
      const host = mount(<ProjectList />);
      const card = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')]
        .filter((el) => el.textContent?.startsWith("acme"))
        .at(0);
      if (!card) throw new Error("no acme card");
      if (count !== null) {
        expect(badgeCount(host, "acme"), name).toBe(count);
        expect(card.textContent, name).not.toContain(PLACE_UNCHECKED_LABEL);
      } else {
        expect(
          [...card.querySelectorAll("button")].some((one) =>
            SKILL_BADGE.test(one.textContent ?? ""),
          ),
          name,
        ).toBe(false);
        expect(card.textContent, name).toContain(PLACE_UNCHECKED_LABEL);
      }
      // Personal is in the same list and this one is not in it, so its own
      // badges are untouched either way.
      expect(badgeCount(host, "Personal"), name).toBe(2);
    }
  });

  // The card reads as one target, so the keyboard opens it too — asking
  // for everything at that place, which is what the card's name is for.
  it("opens the whole place from the card on Enter", async () => {
    const host = mount(<ProjectList />);
    const card = host.querySelectorAll<HTMLElement>('[data-slot="card"]')[1];
    if (!card) throw new Error("no project card rendered");
    expect(card.getAttribute("tabindex")).toBe("0");
    act(() => card.focus());
    await userEvent.keyboard("{Enter}");
    expect(useNavStore.getState().libraryFilter).toEqual({
      scope: { project: "/work/acme" },
    });
  });
});

// A place says when its packages are out of date, and the click is the
// same flow the Updates page runs — the changes first, then the write.
// Distinct from the card's uncommitted-files badge: what a source has
// moved on to is not what kendex wrote here and has not committed.
describe("out-of-date packages on a place's card", () => {
  const card = (host: HTMLElement, name: string) => {
    const found = [
      ...host.querySelectorAll<HTMLElement>('[data-slot="card"]'),
    ].find((el) => el.textContent?.startsWith(name));
    if (!found) throw new Error(`no ${name} card`);
    return found;
  };

  beforeEach(() => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
  });

  it("counts each place's own packages and opens their review", async () => {
    useUpdatesStore.setState({
      rows: [
        updateRow("gh", "/work/acme"),
        updateRow("dev", "/work/acme"),
        updateRow("orch", null),
      ],
      read: READ_LANDED,
      unreadable: [],
    });
    const host = mount(<ProjectList />);
    await settle();

    expect(card(host, "acme").textContent).toContain(outOfDateHereLabel(2));
    expect(card(host, "Personal").textContent).toContain(outOfDateHereLabel(1));

    const line = [...card(host, "acme").querySelectorAll("button")].find(
      (b) => b.textContent === outOfDateHereLabel(2),
    );
    if (!line) throw new Error("no out-of-date line");
    await userEvent.click(line);
    expect(document.body.textContent).toContain(
      updateReviewManyTitle(2, "acme"),
    );
    expect(document.body.textContent).toContain(UPDATE_REVIEW_CONFIRM);
  });

  it("says nothing where it has not been told, and nothing where there is nothing", async () => {
    const cases = [
      {
        name: "nothing out of date",
        rows: [],
        read: READ_LANDED,
        unreadable: [],
      },
      {
        // A read still on its way has counted nothing, and a card saying
        // so would be the claim it cannot make.
        name: "no read has landed",
        rows: [updateRow("gh", "/work/acme")],
        read: READ_PENDING,
        unreadable: [],
      },
      {
        // This place has no standing at all: whatever rows an earlier read
        // left for it answer for a state kendex can no longer see, so a
        // count over them would be a claim about a place it cannot read.
        name: "the place could not be read",
        rows: [updateRow("gh", "/work/acme")],
        read: READ_LANDED,
        unreadable: [{ scope: ACME, message: "newer schema" }],
      },
    ];
    expect(cases).toHaveLength(3);
    for (const one of cases) {
      useUpdatesStore.setState({
        rows: one.rows,
        read: one.read,
        unreadable: one.unreadable as never,
      });
      const host = mount(<ProjectList />);
      await settle();
      expect(card(host, "acme").textContent, one.name).not.toContain(
        "out of date",
      );
    }
  });

  // A package its source dropped has no version to move to. Counting it
  // would draw a line whose review has nothing in it — a dead end where
  // the card promised work.
  it("counts no package whose news is not an update", async () => {
    useUpdatesStore.setState({
      rows: [
        updateRow("gone", "/work/acme", {
          updateAvailable: false,
          removedUpstream: true,
        }),
      ],
      read: READ_LANDED,
      unreadable: [],
    });
    const host = mount(<ProjectList />);
    await settle();
    expect(card(host, "acme").textContent).not.toContain("out of date");
  });

  // The store refuses a write read off rows a landing is about to replace.
  // The card says so on the button rather than letting the click answer
  // with an error dialog.
  it("holds its update while a read that will replace the rows is out", async () => {
    useUpdatesStore.setState({
      rows: [updateRow("gh", "/work/acme")],
      read: READ_LANDED,
      unreadable: [],
      reading: true,
    });
    const host = mount(<ProjectList />);
    await settle();

    const line = [...card(host, "acme").querySelectorAll("button")].find(
      (b) => b.textContent === outOfDateHereLabel(1),
    );
    if (!line) throw new Error("no out-of-date line");
    await userEvent.click(line);

    const update = [...document.querySelectorAll("button")].find(
      (b) => b.textContent === UPDATE_REVIEW_CONFIRM,
    );
    expect(update?.disabled).toBe(true);
    expect(update?.getAttribute("title")).toBe(UPDATE_NEEDS_CHECK_NOTE);
  });
});

// The card is where a person decides whether to look, so all four states of
// the read behind it are distinguishable there. A project kendex could not
// check must never draw the way a clean one does.
describe("a card's badge about what is waiting", () => {
  const ROOT = "/work/acme";

  beforeEach(() => {
    useSettingsStore.setState({ settings: { projects: [ROOT] } as never });
  });

  it("marks a project the read could not cover, and one it could not confirm", async () => {
    const rows: {
      name: string;
      state: { rows: ProjectChanges[]; read: ReadState };
      badge: boolean;
    }[] = [
      // Nothing has looked yet: no badge, the answer is coming.
      {
        name: "waiting",
        state: { rows: [], read: READ_PENDING },
        badge: false,
      },
      // The landed read carries no row for it — the backend skipped it.
      { name: "skipped", state: { rows: [], read: READ_LANDED }, badge: true },
      // Its own read refused.
      {
        name: "unreadable",
        state: {
          rows: [
            {
              root: ROOT,
              name: "acme",
              state: { kind: "unreadable", said: ["fatal: bad object"] },
            },
          ],
          read: READ_LANDED,
        },
        badge: true,
      },
      // A row the current read could not confirm.
      {
        name: "stale",
        state: {
          rows: [{ root: ROOT, name: "acme", state: { kind: "clean" } }],
          read: readFailed("git is not on the path"),
        },
        badge: true,
      },
      // A clean project a landed read confirmed says nothing at all.
      {
        name: "clean",
        state: {
          rows: [{ root: ROOT, name: "acme", state: { kind: "clean" } }],
          read: READ_LANDED,
        },
        badge: false,
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows) {
      useProjectChangesStore.setState(one.state);
      const host = mount(<ProjectList />);
      await settle();
      expect(
        host.ownerDocument.body.textContent?.includes(NOT_CHECKED_BADGE),
        one.name,
      ).toBe(one.badge);
    }
  });
});
