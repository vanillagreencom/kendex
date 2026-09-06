// @vitest-environment jsdom
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
import { ADOPTABLE } from "@/lib/adoptable";
import { unmanagedHereLabel } from "@/lib/copy";
import { kindLabel } from "@/lib/labels";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
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
      data: { settings: { projects: ["/work/acme"] }, base: null } as never,
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

    await act(async () => {
      await useSettingsStore.getState().registerProject("/work/acme");
    });
    await settle();

    expect(commands.auditAll).toHaveBeenCalled();
    expect(host.textContent).toContain(unmanagedHereLabel(2));
  });

  // The mount's own audit is inside the freshness window by the time the
  // registration lands, so an unforced ask would return without calling the
  // backend at all and the count would stay at zero.
  it("asks past the freshness window rather than reusing the last answer", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: ["/work/acme"] }, base: null } as never,
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view(ACME, [byHand("gh")])],
    });

    mount(<ProjectList />);
    await settle();
    const beforeRegistering = vi.mocked(commands.auditAll).mock.calls.length;

    await act(async () => {
      await useSettingsStore.getState().registerProject("/work/acme");
    });

    expect(vi.mocked(commands.auditAll).mock.calls.length).toBeGreaterThan(
      beforeRegistering,
    );
  });
});

const installed = (overrides: Partial<ObservedItem>): ObservedItem => ({
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

    act(() => skillBadge(host, "Personal").click());
    expect(useNavStore.getState().libraryFilter).toEqual({
      scope: "global",
      kind: "skill",
    });
    expect(badge).toBe(destinationRows());
  });

  // The must-fail control: three installations of two packages sit behind
  // Personal, so 3 is the pre-fix number this case rejects. Without it the
  // equality above would hold on any pair that moved together. The project
  // card pins that a place counts only what is at it.
  it("counts packages rather than the installations behind them", () => {
    const host = mount(<ProjectList />);
    expect(badgeCount(host, "Personal")).toBe(2);
    expect(badgeCount(host, "acme")).toBe(1);
  });
});
