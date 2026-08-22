// Every mutation that rewrites a place's kendex.toml tells the editor the
// moment its command answers, before it re-reads any table of its own. The
// helper refuses the save from the instant it is called, so what is left to
// the caller is calling it soon enough — these are the windows where a save
// would otherwise land between the write and the telling.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { useEditorStore } from "./editor";
import { useMarketplacesStore } from "./marketplaces";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { keepAsOwn } from "./updates-edits";

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

// Each of these rewrites the scope's kendex.toml and then re-reads the
// marketplace tables. The save pressed during that re-read is the window.
describe("a subscription mutation tells the editor before it re-reads", () => {
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
    // The tables re-read after the manifest was rewritten: the save lands
    // in that window.
    vi.mocked(commands.marketplacesOverview).mockImplementation(async () => {
      press();
      return { status: "ok", data: [] };
    });
  });

  it("refuses the save after subscribing", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockImplementation(async () => {
      type();
      return {
        status: "ok",
        data: {
          name: "kit",
          reference: "acme/kit",
          rev: null,
          notes: [],
          lead: null,
        },
      };
    });
    await useMarketplacesStore.getState().subscribe(scope, "acme/kit", null);

    refused();
  });

  it("refuses the save after unsubscribing", async () => {
    vi.mocked(commands.marketplaceUnsubscribe).mockImplementation(async () => {
      type();
      return {
        status: "ok",
        data: null,
      };
    });
    await useMarketplacesStore
      .getState()
      .unsubscribe(scope, "kit", false, false);

    refused();
  });

  it("refuses the save after turning a subscription off", async () => {
    vi.mocked(commands.sourceToggle).mockImplementation(async () => {
      type();
      return {
        status: "ok",
        data: [],
      };
    });
    await useMarketplacesStore.getState().toggle(scope, "kit", false);

    refused();
  });
});

// Keeping an edited place as a fork writes the fork record into the same
// kendex.toml the Customize tab holds a copy of, and then re-reads the
// updates table. The record lives nowhere else, so a save landing in that
// read would take it back.
describe("keeping a fork tells the editor before it re-reads", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
    // Clean at the start: the tab refuses the fork outright while unsaved.
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
      data: inventory,
    });
    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
    // Typing arrives while the fork is being written, and the save lands
    // in the updates read that follows it.
    vi.mocked(commands.packageFork).mockImplementation(async () => {
      type();
      return { status: "ok", data: view };
    });
    vi.mocked(commands.updatesOverview).mockImplementation(async () => {
      press();
      return { status: "ok", data: { rows: [], warnings: [] } };
    });
  });

  it("refuses the save after keeping an edited place as a fork", async () => {
    await keepAsOwn(updateRow("gh", null, { forkableHarness: "claude" }));

    expect(commands.packageFork).toHaveBeenCalled();
    refused();
  });
});
