// Actions that write before they can say what they wrote. A dismissal is
// applied and then read back to build its undo, and an undo of several
// records is one write per record — so both can fail with the file already
// changed. Told only that the action failed, the app says nothing was
// changed and leaves the marks drawn from a manifest that moved. The save
// that follows is still refused on the file's own base, so nothing is
// overwritten; what is wrong is what the reader is told, and what the marks
// go on showing until something else re-reads.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, Manifest_Serialize } from "@/bindings";
import { commands } from "@/bindings";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    dismissFindings: vi.fn(),
    revokeDismissal: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn(), message: vi.fn() },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./settings", () => ({
  useSettingsStore: {
    getState: () => ({ settings: { schema: 1, projects: [] } }),
    setState: () => {},
  },
}));

const scope = { scope: "global" as const };

const view: AuditView = {
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
};

/** The file as the dismissal left it — what the marks should end up on. */
const settled: Manifest_Serialize = {
  schema: 1,
  install: {},
  "skill-instructions": { gh: "after the dismissal" },
};

const record = {
  key: "gh",
  fingerprint: "f1",
  dismissedAt: "2026-08-20T00:00:00Z",
};

beforeEach(() => {
  vi.clearAllMocks();
  useAuditStore.setState({
    views: [],
    auditing: false,
    error: null,
    busy: false,
  });
  useEditorStore.setState({
    scope,
    draft: null,
    dirty: false,
    held: {},
    saved: { global: { schema: 1, install: {} } },
    base: "before",
    outdated: null,
    unreadPlaces: {},
  });
  useProblemsStore.getState().closeError();
  vi.mocked(commands.auditAll).mockResolvedValue({
    status: "ok",
    data: [view],
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
  // Whatever re-reads the place finds the file the write left.
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: settled, base: "after" },
  });
});

describe("a dismissal that landed and then could not be described", () => {
  it("tells the editor the file moved, and says the decision stands", async () => {
    vi.mocked(commands.dismissFindings).mockResolvedValue({
      status: "error",
      error: { kind: "written", message: "could not be read back" },
    });

    await useAuditStore.getState().dismiss(scope, ["gh:f1"], "intended");

    // The marks come off the file as it is now, not as it was before.
    expect(useEditorStore.getState().saved.global).toEqual({
      schema: 1,
      install: {},
      "skill-instructions": { gh: "after the dismissal" },
    });
    expect(useProblemsStore.getState().dialog.title).toContain(
      "decision was recorded",
    );
  });

  it("still says nothing changed when nothing was written", async () => {
    vi.mocked(commands.dismissFindings).mockResolvedValue({
      status: "error",
      error: { kind: "untouched", message: "the token did not parse" },
    });

    await useAuditStore.getState().dismiss(scope, ["gh:f1"], "intended");

    // Untouched means untouched: no re-read, and the marks stand.
    expect(useEditorStore.getState().saved.global).toEqual({
      schema: 1,
      install: {},
    });
    expect(useProblemsStore.getState().dialog.steps?.[0]).toContain(
      "Nothing was changed",
    );
  });
});

/** The Undo the dismissal's toast offered. */
const undoOffered = async () => {
  const { toast } = await import("sonner");
  const offered = vi.mocked(toast.success).mock.calls.at(-1);
  if (!offered) throw new Error("the dismissal offered no undo");
  return (offered[1] as unknown as { action: { onClick: () => void } }).action;
};

/** Press it and wait for the funnel to finish everything the outcome owes;
 *  the flag comes down in its `finally`. */
const press = async (undo: { onClick: () => void }) => {
  undo.onClick();
  expect(useAuditStore.getState().busy).toBe(true);
  await vi.waitUntil(() => !useAuditStore.getState().busy);
};

describe("an undo that took some of its records back", () => {
  it("tells the editor about the ones that landed", async () => {
    vi.mocked(commands.dismissFindings).mockResolvedValue({
      status: "ok",
      data: { view, records: [record, { ...record, key: "rev" }] },
    });
    await useAuditStore
      .getState()
      .dismiss(scope, ["gh:f1", "rev:f1"], "intended");
    // The dismissal itself re-read the place; the undo below is what is
    // under test, so the marks start from the file it left.
    useEditorStore.setState({ saved: { global: { schema: 1, install: {} } } });

    // The first record comes back, the second refuses.
    vi.mocked(commands.revokeDismissal)
      .mockResolvedValueOnce({ status: "ok", data: view })
      .mockResolvedValueOnce({ status: "error", error: "a newer decision" });

    await press(await undoOffered());
    expect(commands.revokeDismissal).toHaveBeenCalledTimes(2);

    expect(useEditorStore.getState().saved.global).toEqual({
      schema: 1,
      install: {},
      "skill-instructions": { gh: "after the dismissal" },
    });
  });

  // Each revoke is pinned to the exact dismissal it takes back, so one
  // already taken back refuses. A retry that starts over therefore stops on
  // the record that already succeeded and never reaches the one that
  // failed — offering a way out that can never finish.
  it("picks up where it stopped rather than starting over", async () => {
    const three = [
      record,
      { ...record, key: "rev" },
      { ...record, key: "orch" },
    ];
    vi.mocked(commands.dismissFindings).mockResolvedValue({
      status: "ok",
      data: { view, records: three },
    });
    await useAuditStore
      .getState()
      .dismiss(scope, ["gh:f1", "rev:f1", "orch:f1"], "intended");

    // The first comes back; the second refuses, whatever the reason was.
    vi.mocked(commands.revokeDismissal)
      .mockResolvedValueOnce({ status: "ok", data: view })
      .mockResolvedValueOnce({ status: "error", error: "a newer decision" });
    const undo = await undoOffered();
    await press(undo);
    expect(
      vi.mocked(commands.revokeDismissal).mock.calls.map((c) => c[1]),
    ).toEqual(["gh", "rev"]);

    // Pressed again with whatever blocked the second now cleared. Starting
    // over would ask for `gh` again — already taken back, so pinned-refused
    // — and stop there with `rev` and `orch` still dismissed.
    vi.mocked(commands.revokeDismissal).mockClear();
    vi.mocked(commands.revokeDismissal).mockResolvedValue({
      status: "ok",
      data: view,
    });
    await press(undo);

    expect(
      vi.mocked(commands.revokeDismissal).mock.calls.map((c) => c[1]),
    ).toEqual(["rev", "orch"]);
  });
});
