// The window between an action finishing and the editor being told about
// it. Every one of these rewrites a place's kendex.toml while the Customize
// tab may be holding a whole copy of that file, and every one of them runs
// under a flag the Save bar is disabled by. If the flag comes down before
// the editor has been told, a save pressed in that gap passes the outdated
// check and writes the pre-action manifest back over what was just recorded
// — the loss the protocol exists to prevent, narrowed to a race.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { packageVersionActions } from "@/components/package/use-package-data";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    toggleItem: vi.fn(),
    dismissFindings: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: {
    success: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
    message: vi.fn(),
  },
}));

const scope = { scope: "global" as const };

const emptyView = {
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
};

/** Typing arrives in the Customize tab while the action is in flight — the
 *  copy in hand is now older than the file the action is rewriting. */
const typingArrives = () => {
  useEditorStore.setState({
    draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
    dirty: true,
  });
};

/** The save the user presses the instant the Save bar comes back up, once.
 *  `pressed` is what keeps the assertion from passing on a save that never
 *  happened. */
const saveOnce = () => {
  const state = { pressed: false };
  return {
    press: () => {
      if (state.pressed) return;
      state.pressed = true;
      void useEditorStore.getState().save();
    },
    get pressed() {
      return state.pressed;
    },
  };
};

const refused = (save: ReturnType<typeof saveOnce>) => {
  expect(save.pressed).toBe(true);
  expect(commands.updateManifest).not.toHaveBeenCalled();
  expect(useProblemsStore.getState().dialog.title).toContain(
    "changed while you typed",
  );
};

describe("a save pressed the moment the busy flag comes down", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    useAuditStore.setState({ views: [], busy: false, auditedAt: null });
    useEditorStore.setState({
      scope,
      draft: { schema: 1, install: {} },
      dirty: false,
      outdated: null,
      saved: {},
    });
    useProblemsStore.getState().closeError();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "rewritten" },
    });
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "ok",
      data: {
        declaredAgents: [],
        declaredSkills: [],
        availableSkills: [],
        harnesses: [],
        hookEvents: [],
      },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
  });

  it("is refused after a version switch", async () => {
    vi.mocked(commands.packageSetRev).mockImplementation(async () => {
      typingArrives();
      return { status: "ok", data: emptyView };
    });
    const save = saveOnce();
    // The flag lives in the updates store now rather than in the page, so
    // the window is watched the same way the audit one is.
    const stop = useUpdatesStore.subscribe((state, previous) => {
      if (previous.busy && !state.busy) save.press();
    });
    const actions = packageVersionActions(
      { scope, kind: "skill", name: "gh" },
      "gh",
      true,
      () => {},
    );

    actions.switchTo({
      id: "b".repeat(40),
      label: "v2",
      date: "2026-08-20T00:00:00Z",
      summary: "newer",
      installed: false,
      newerThanInstalled: true,
    });
    await vi.waitUntil(() => save.pressed);
    stop();

    refused(save);
  });

  it("is refused after an audit action", async () => {
    vi.mocked(commands.toggleItem).mockImplementation(async () => {
      typingArrives();
      return { status: "ok", data: emptyView };
    });
    const save = saveOnce();
    const stop = useAuditStore.subscribe((state, previous) => {
      if (previous.busy && !state.busy) save.press();
    });

    await useAuditStore.getState().toggle(scope, "skill", "gh", false);
    stop();

    refused(save);
  });

  it("is refused after a finding is dismissed", async () => {
    vi.mocked(commands.dismissFindings).mockImplementation(async () => {
      typingArrives();
      return { status: "ok", data: { view: emptyView, records: [] } };
    });
    const save = saveOnce();
    const stop = useAuditStore.subscribe((state, previous) => {
      if (previous.busy && !state.busy) save.press();
    });

    await useAuditStore.getState().dismiss(scope, ["token"], "intended");
    stop();

    refused(save);
  });
});
