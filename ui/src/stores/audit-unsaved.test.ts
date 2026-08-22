import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { inEveryPlace, refusesForUnsavedIn } from "./unsaved-first";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    applyPlan: vi.fn(),
    adoptItem: vi.fn(),
    toggleItem: vi.fn(),
    removeItem: vi.fn(),
    dismissFindings: vi.fn(),
    revokeDismissal: vi.fn(),
    revokeSafetyOverride: vi.fn(),
  },
}));

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const globalScope = { scope: "global" as const };

const emptyView: AuditView = {
  scope: globalScope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
};

// Moving between places parks typing rather than dropping it, so the copy
// that a write would strand can be waiting behind another place. Apply,
// adopt, toggle and remove all rewrite the file that copy came from.
describe("an audit mutation beside unsaved customization", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [],
      auditing: false,
      error: null,
      busy: false,
    });
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
  });

  it("refuses while typing for that place waits behind another one", async () => {
    useEditorStore.setState({
      held: {
        global: {
          scope: globalScope,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    await useAuditStore.getState().toggle(globalScope, "skill", "gh", false);
    expect(commands.toggleItem).not.toHaveBeenCalled();
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.title).toContain("Save your");
    // The unsaved copy is not on screen, so the way back to it is named.
    expect(dialog.steps?.[0]).toContain("Personal");
  });

  it("goes ahead when the unsaved typing is about another place", async () => {
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: { schema: 1, install: {} },
      dirty: true,
      held: {},
    });
    vi.mocked(commands.toggleItem).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });
    await useAuditStore.getState().toggle(globalScope, "skill", "gh", false);
    expect(commands.toggleItem).toHaveBeenCalled();
  });
});

// Settling a finding writes the same file the rest of them write, and it
// went round the funnel rather than through it.
describe("a dismissal beside unsaved customization", () => {
  it("refuses while typing for that place waits behind another one", async () => {
    useAuditStore.setState({ views: [], busy: false, error: null });
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: null,
      dirty: false,
      held: {
        global: {
          scope: globalScope,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    vi.clearAllMocks();
    await useAuditStore.getState().dismiss(globalScope, ["t"], "intended");
    expect(commands.dismissFindings).not.toHaveBeenCalled();
    expect(useAuditStore.getState().busy).toBe(false);
  });
});

// Taking a decision back rewrites the same file, so it runs through the
// same funnel — the guard, the busy flag the Save bar watches, and the
// telling — rather than keeping its own in a component.
describe("taking a decision back", () => {
  it("refuses while typing for that place waits behind another one", async () => {
    useAuditStore.setState({ views: [], busy: false, error: null });
    useEditorStore.setState({
      scope: { scope: "project", root: "/work/vg" },
      draft: null,
      dirty: false,
      held: {
        global: {
          scope: globalScope,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    vi.clearAllMocks();
    await useAuditStore.getState().revokeDecision({
      scope: globalScope,
      key: "skill:gh",
      name: "gh",
      record: { kind: "dismissed", fingerprint: "f", dismissedAt: "then" },
    } as never);
    expect(commands.revokeDismissal).not.toHaveBeenCalled();
    expect(useAuditStore.getState().busy).toBe(false);
  });
});

// One click that means every place this package is installed in. Asked per
// place inside the loop, the first refusal would stop that place and let
// the rest be written — a package changed in two projects and not the
// third, from a click that said nothing about doing part of it.
describe("a package-wide action across several places", () => {
  const VG = { scope: "project" as const, root: "/work/vg" };

  it("refuses all of them when any one has unsaved typing", () => {
    useEditorStore.setState({
      scope: VG,
      draft: null,
      dirty: false,
      held: {
        global: {
          scope: globalScope,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    expect(refusesForUnsavedIn([VG, globalScope])).toBe(true);
    // And names the place to go back to, which is not the one on screen.
    expect(useProblemsStore.getState().dialog.steps?.[0]).toContain("Personal");
  });

  it("goes ahead when none of them does", () => {
    useEditorStore.setState({ scope: VG, draft: null, dirty: false, held: {} });
    expect(refusesForUnsavedIn([VG, globalScope])).toBe(false);
  });
});

// Every await between places is a window someone can type in, and these
// actions return nothing — so a refusal inside one is invisible to the
// loop unless the loop asks again itself.
describe("a package-wide action while someone types mid-run", () => {
  const VG = { scope: "project" as const, root: "/work/vg" };

  it("stops at the place the typing is about", async () => {
    useEditorStore.setState({ scope: VG, draft: null, dirty: false, held: {} });
    const done: string[] = [];
    await inEveryPlace([VG, globalScope], async (scope) => {
      done.push(scope.scope === "global" ? "global" : scope.root);
      // Typing arrives about the place still to come.
      useEditorStore.setState({
        held: {
          global: {
            scope: globalScope,
            draft: { schema: 1, install: {} },
            base: "read-earlier",
          },
        },
      });
      return true;
    });
    expect(done).toEqual(["/work/vg"]);
  });

  it("does every place when nobody types", async () => {
    useEditorStore.setState({ scope: VG, draft: null, dirty: false, held: {} });
    const done: string[] = [];
    await inEveryPlace([VG, globalScope], async (scope) => {
      done.push(scope.scope === "global" ? "global" : scope.root);
      return true;
    });
    expect(done).toEqual(["/work/vg", "global"]);
  });

  // A place the machine would not take is a reason to stop too: the
  // action has already said why, and going on would change the package in
  // some places and not others under one click.
  it("stops at the place the machine would not take", async () => {
    useEditorStore.setState({ scope: VG, draft: null, dirty: false, held: {} });
    const done: string[] = [];
    await inEveryPlace([VG, globalScope], async (scope) => {
      done.push(scope.scope === "global" ? "global" : scope.root);
      return false;
    });
    expect(done).toEqual(["/work/vg"]);
  });
});
