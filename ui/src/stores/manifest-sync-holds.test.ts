// Every mutation that rewrites a place's kendex.toml tells the editor the
// moment its command answers, before it re-reads any table of its own. The
// helper refuses the save from the instant it is called, so what is left to
// the caller is calling it soon enough — these are the windows where a save
// would otherwise land between the write and the telling.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
    marketplaceSubscribe: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    sourceToggle: vi.fn(),
    marketplacesOverview: vi.fn(),
    packageFork: vi.fn(),
    packageSetRev: vi.fn(),
    updatesOverview: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), message: vi.fn(), info: vi.fn() },
}));

vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));

vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const scope = { scope: "global" as const };
const typed = { schema: 1, install: {}, "skill-instructions": { gh: "mine" } };

const view = {
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
};

const inventory = {
  declaredAgents: [],
  declaredSkills: [],
  availableSkills: [],
  harnesses: [],
  hookEvents: [],
};

/** Typing arrives in the Customize tab. */
const type = () => useEditorStore.setState({ draft: typed, dirty: true });

/** The save the user presses in the window under test. */
const press = () => void useEditorStore.getState().save();

const refused = () => {
  expect(commands.updateManifest).not.toHaveBeenCalled();
  expect(useProblemsStore.getState().dialog.title).toContain(
    "changed while you typed",
  );
};

// Switching a place between following its source and holding at what is
// installed writes that place's kendex.toml, like every other version move.
describe("holding a version tells the editor before it re-reads", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    // Clean at the start: an unsaved draft would now refuse the mutation
    // outright, and the window this is about is the one typing lands in
    // while the write is going through.
    useEditorStore.setState({ scope, draft: null, dirty: false, saved: {} });
    useEditorStore.setState({ outdated: null });
    useProblemsStore.getState().closeError();
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "rewritten" },
    });
    vi.mocked(commands.editorInventory).mockResolvedValue({
      status: "ok",
      data: inventory,
    });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
    vi.mocked(commands.packageSetRev).mockImplementation(async () => {
      type();
      return {
        status: "ok",
        data: view,
      };
    });
    vi.mocked(commands.updatesOverview).mockImplementation(async () => {
      press();
      return { status: "ok", data: { rows: [], warnings: [] } };
    });
  });

  it("refuses the save after turning following off", async () => {
    await useUpdatesStore
      .getState()
      .setAutoUpdate(updateRow("gh", null, { updateAvailable: false }), false);

    expect(commands.packageSetRev).toHaveBeenCalled();
    refused();
  });
});
