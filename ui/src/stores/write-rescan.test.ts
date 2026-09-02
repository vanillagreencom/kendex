// One rule, five write paths: a command that reaches `repo_effects` reads
// the machine again whatever it answered. `lib/rescan.ts` holds the rule and
// the reason — the leaving packages' uninstallers run before the plan, so a
// refusal comes back with what they did to the disk standing, and Home's
// inventory and the audit scores would go on counting copies already gone.
//
// The refusal arm is what this file is about: the landing arm has always
// rescanned, and the mechanism these five now share cannot tell the two
// apart. `scanMachine` and `auditAll` are the two commands `rescanEverything`
// sends, so asking whether they were called is asking whether the rule held.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { emptyDraft } from "@/lib/editor-draft";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { useMarketplacesStore } from "./marketplaces";
import { useProvenanceStore } from "./provenance";
import { useScanStore } from "./scan";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the editor's empty draft is stamped
  // with core's own manifest schema through them.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    marketplaceInstall: vi.fn(),
    sourceToggle: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    marketplacesOverview: vi.fn(),
    saveCustomize: vi.fn(),
    removeItem: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
    info: vi.fn(),
    message: vi.fn(),
  },
}));

const scope = { scope: "global" as const };

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      items: [],
      harnesses: [],
      warnings: [],
      missingProjects: [],
    } as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  useScanStore.setState({
    scanning: false,
    result: null,
    error: null,
    backgroundFailureAnnounced: false,
  });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    read: READ_LANDED,
    busy: false,
    backgroundFailureAnnounced: false,
  });
  useProvenanceStore.setState({ rows: [], loaded: false });
});

/** What every case below asks: the machine was read again, both halves of
 *  it, behind a command that answered with a refusal. */
const readAgain = () => {
  expect(commands.scanMachine).toHaveBeenCalled();
  expect(commands.auditAll).toHaveBeenCalled();
};

describe("a write that reaches repo_effects and is refused", () => {
  it("reads the machine again behind a marketplace install", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "error",
      error: "the scope is busy",
    });

    const landed = await useMarketplacesStore.getState().install({
      scope,
      source: "kit",
      items: [{ kind: "skill", name: "gh" }],
    });

    expect(landed).toBe(false);
    readAgain();
  });

  it("reads the machine again behind a source toggle", async () => {
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "error",
      error: "the settings file is read-only",
    });

    await useMarketplacesStore.getState().toggle(scope, "kit", false);

    // The refusal is honoured — the overview is not re-asked behind a write
    // that did not land — and the machine is still read again.
    expect(commands.marketplacesOverview).not.toHaveBeenCalled();
    readAgain();
  });

  it("reads the machine again behind an unsubscribe", async () => {
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "error",
      error: "the scope is busy",
    });

    const outcome = await useMarketplacesStore
      .getState()
      .unsubscribe(scope, "kit", false, false);

    expect(outcome).toEqual({ error: "the scope is busy" });
    readAgain();
  });

  it("reads the machine again behind an editor save", async () => {
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "disk is full" },
    });
    useEditorStore.setState({ scope, draft: emptyDraft(), base: null });

    await useEditorStore.getState().save();

    expect(useEditorStore.getState().error).toBe("disk is full");
    readAgain();
  });

  // The stale arm is the one refusal that claims nothing was written, and
  // it is still no account of the disk: the write reaches `repo_effects`
  // before it reads the file it refuses over.
  it("reads the machine again behind an editor save refused as stale", async () => {
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    useEditorStore.setState({ scope, draft: emptyDraft(), base: null });

    await useEditorStore.getState().save();

    expect(useEditorStore.getState().stale).toBe(true);
    readAgain();
  });

  it("reads the machine again behind an audit item action", async () => {
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });

    const landed = await useAuditStore
      .getState()
      .removeItem(scope, "hook", "lint");

    expect(landed).toBe(false);
    readAgain();
  });
});
