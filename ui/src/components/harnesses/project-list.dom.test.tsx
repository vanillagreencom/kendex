// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  DriftRow,
  ObservedItem,
  ScanResult,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { updateRow } from "@/components/updates-test-rows";
import { ADOPTABLE } from "@/lib/adoptable";
import { unmanagedHereLabel } from "@/lib/copy";
import { ADD_PACKAGES_LABEL } from "@/lib/copy-install";
import {
  PLACE_MARKETPLACES_LABEL,
  placeMarketplacesTitle,
} from "@/lib/copy-model";
import {
  SESSION_NOTE_LABEL,
  SESSION_NOTE_ON,
  SESSION_NOTE_WAITING,
} from "@/lib/copy-session-note";
import {
  outOfDateHereLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_REVIEW_CONFIRM,
  updateReviewManyTitle,
} from "@/lib/copy-updates";
import { kindLabel } from "@/lib/labels";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useLibraryViewStore } from "@/stores/library-view";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";
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

const emptyScan: ScanResult = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
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

// The note's line is the card's, wired to the scan the list already
// reads: a project whose settings run the hook says so, Personal carries
// no such line. The words are the copy's own, so a relabel fails here.
describe("the start-of-session note on a project's card", () => {
  it("names the state the scan shows, on the project's card only", async () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
    useScanStore.setState({
      scanning: false,
      error: null,
      result: {
        ...emptyScan,
        items: [
          installed({
            kind: "hook",
            name: "SessionStart:*:kendex-drift",
            scope: ACME,
            path: "/work/acme/.claude/settings.json",
          }),
        ],
      },
    });
    const host = mount(<ProjectList />);
    await settle();
    const cards = [...host.querySelectorAll<HTMLElement>('[data-slot="card"]')];
    const personal = cards.find((el) => el.textContent?.startsWith("Personal"));
    const acme = cards.find((el) => el.textContent?.startsWith("acme"));
    expect(acme?.textContent).toContain(SESSION_NOTE_ON);
    expect(personal?.textContent).not.toContain(SESSION_NOTE_LABEL);
  });

  // Declared and nothing rendered is the audit's to say: the install ran
  // with other changes pending, so only the declaration landed. A card
  // reading the scan alone would say off, with a button that re-runs an
  // install already declared.
  it("says the note is waiting from the audit's missing row", async () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
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
    expect(host.textContent).toContain(SESSION_NOTE_WAITING);
  });

  // The audit reads every place over seconds, and a cold start can fail
  // it outright. "Off" at first paint would claim a state the app has not
  // checked, on a card whose note may be declared and waiting.
  it("says nothing about the note until the audit has answered for the place", async () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
    useAuditStore.setState({ views: [view({ scope: "global" }, [])] });
    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).toContain("acme");
    expect(host.textContent).not.toContain(SESSION_NOTE_LABEL);
  });

  // Before the scan has answered there is nothing to say either: a card
  // that may already run the hook must not offer to add it.
  it("says nothing about the note until the scan has answered", async () => {
    useSettingsStore.setState({
      settings: { projects: ["/work/acme"] } as never,
    });
    useScanStore.setState({ scanning: true, result: null, error: null });
    useAuditStore.setState({ views: [view(ACME, [])] });
    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).toContain("acme");
    expect(host.textContent).not.toContain(SESSION_NOTE_LABEL);
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
// other and has no tracking to stop.
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
      PLACE_MARKETPLACES_LABEL,
      "Stop tracking acme…",
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

  it("offers Personal its marketplaces and no tracking to stop", async () => {
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "Personal");
    expect(menuItems()).toEqual([ADD_PACKAGES_LABEL, PLACE_MARKETPLACES_LABEL]);
  });

  // Stopping tracking moved off its own button and into this menu, and a
  // menu item is the shape whose click the card used to answer. Rendering
  // the item proves nothing about the path behind it: the removal has to
  // reach the settings store with this card's own root, and the card must
  // not navigate out from under the confirm.
  it("stops tracking the project the card names, without leaving the page", async () => {
    vi.mocked(commands.unregisterProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: [] }, base: null } as never,
    });
    const host = mount(<ProjectList />);
    await settle();

    await openActions(host, "acme");
    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent === "Stop tracking acme…",
    );
    if (!(item instanceof HTMLElement))
      throw new Error("no stop-tracking item");
    await userEvent.click(item);
    await settle();
    expect(useNavStore.getState().page).toBe("projects");

    const confirm = [...document.querySelectorAll("button")].find(
      (one) => one.textContent === "Stop tracking",
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
      PLACE_MARKETPLACES_LABEL,
      "Stop tracking /work/client…",
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
    description: null,
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
