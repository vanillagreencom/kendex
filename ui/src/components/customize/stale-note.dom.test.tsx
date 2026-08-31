// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { EditorInventory, Scope, ScopeSettings } from "@/bindings";
import { commands } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { READ_PENDING } from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    getScopeSettings: vi.fn(),
    saveCustomize: vi.fn(),
  },
}));

vi.mock("@/stores/audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("@/stores/scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }), setState: vi.fn() },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };

const declares: ScopeSettings = {
  applies: true,
  base: "s1",
  skills: [
    {
      skill: "gh",
      template: {
        state: "rows",
        rows: [
          {
            key: "GH_MODE",
            explainer: ["what it does"],
            default: "enforce",
            current: { state: "value", value: "enforce", line: 3 },
          },
        ],
      },
    },
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
  useUpdatesStore.setState({ rows: [], read: READ_PENDING });
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: null, base: "b1" },
  });
  vi.mocked(commands.editorInventory).mockResolvedValue({
    status: "ok",
    data: {
      declaredSkillRows: {},
      harnesses: ["claude"],
    } as unknown as EditorInventory,
  });
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: declares,
  });
});

/** Change one settings value, save it alone, and have that save refused
 *  as stale — the path this PR added, and the one the note's old sentence
 *  was never written for. */
const refuseSettingsSave = async () => {
  await useEditorStore.getState().setScope(VG);
  useEditorStore.getState().editSetting({
    skill: "gh",
    key: "GH_MODE",
    value: { kind: "set", value: "advise" },
  });
  vi.mocked(commands.saveCustomize).mockResolvedValue({
    status: "error",
    error: { kind: "stale" },
  });
  await useEditorStore.getState().save();
  expect(commands.saveCustomize).toHaveBeenCalledWith(
    VG,
    null,
    expect.objectContaining({ base: "s1" }),
  );
  expect(useEditorStore.getState().stale).toBe(true);
};

// The sentence a person reads immediately before choosing a reload that
// discards what they typed. It has to be true of the file that actually
// moved, and a settings-only save refuses through the same path without
// kendex.toml having been touched at all.
describe("the stale note", () => {
  it("sends nobody to the wrong file after a settings-only refusal", async () => {
    await refuseSettingsSave();
    const host = mount(
      <ItemCustomize
        kind="skill"
        name="gh"
        scopes={[VG]}
        harnesses={["claude"]}
      />,
    );
    const note = host.querySelector('[role="alert"], .border-warning\\/30');
    expect(note?.textContent).toContain(
      "The file this draft came from changed after you opened it",
    );
    expect(host.textContent).not.toContain("kendex.toml");
  });
});
