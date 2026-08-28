// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, DriftRow, RowExits, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  KEEP_FILES_CONFIRM_LABEL,
  KEEP_FILES_LABEL,
  MOVE_FILES_YOURSELF,
  REPLACE_FILES_CONFIRM_LABEL,
  REPLACE_FILES_LABEL,
} from "@/lib/copy-in-the-way";
import { useAuditStore } from "@/stores/audit";
import { mount, settle } from "@/test/dom";
import { ProblemsPage } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    scanMachine: vi.fn(),
    adoptItem: vi.fn(),
    replaceUnmanagedItem: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const inTheWay = (
  name: string,
  harness: DriftRow["harness"],
  over: Partial<DriftRow> = {},
): DriftRow => ({
  kind: "skill",
  name,
  harness,
  scope: ACME,
  state: "conflict",
  cause: "unmanaged-content",
  detail: `/work/acme/.${harness}/skills/${name}`,
  ...over,
});

const exit = (key: string, over: Partial<RowExits> = {}): RowExits => ({
  key,
  blocking: true,
  files: true,
  keep: true,
  enter: true,
  replace: true,
  tools: [key.split(":")[2] as RowExits["tools"][number]],
  ...over,
});

const view = (over: Partial<AuditView>): AuditView => ({
  scope: ACME,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
  ...over,
});

const stage = (views: AuditView[]) =>
  act(() => {
    useAuditStore.setState({
      views,
      auditedAt: Date.now(),
      scopeCheckedAt: {},
      checkError: null,
      busy: false,
    });
  });

const button = (host: HTMLElement, label: string) =>
  [...host.querySelectorAll("button")].find(
    (el) => el.textContent?.trim() === label,
  );

// The row's Replace button and the dialog's confirm carry the same words,
// so a search over the whole document would press the row again.
const dialog = () => {
  const el = document.body.querySelector('[role="dialog"]');
  expect(el).not.toBeNull();
  return el as HTMLElement;
};

const press = async (el: Element | undefined) => {
  expect(el).toBeDefined();
  await act(async () => {
    (el as HTMLButtonElement).click();
  });
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      items: [],
      harnesses: [],
      warnings: [],
      missingProjects: [],
    },
  } as never);
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    scopeCheckedAt: {},
    checkError: null,
    busy: false,
  });
});

describe("a declared item whose place already holds files", () => {
  it("offers only the exits core reported for the row", async () => {
    stage([
      view({
        drift: [
          // A folder where one file goes: core says it cannot be kept as
          // it stands, and the page must not offer to.
          inTheWay("scout", "claude", { cause: "unmanaged-wrong-shape" }),
        ],
        exits: [exit("skill:scout:claude", { keep: false, enter: true })],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    expect(host.textContent).toContain("scout");
    expect(button(host, KEEP_FILES_LABEL)).toBeUndefined();
    expect(host.textContent).toContain(MOVE_FILES_YOURSELF);
    expect(button(host, REPLACE_FILES_LABEL)).toBeDefined();
  });

  it("offers keeping alone where core refuses the replacement", async () => {
    stage([
      view({
        drift: [inTheWay("browser", "claude", { cause: "shared-link" })],
        exits: [exit("skill:browser:claude", { replace: false })],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    expect(button(host, KEEP_FILES_LABEL)).toBeDefined();
    expect(button(host, REPLACE_FILES_LABEL)).toBeUndefined();
  });

  it("takes the item over through replaceUnmanagedItem", async () => {
    vi.mocked(commands.replaceUnmanagedItem).mockResolvedValue({
      status: "ok",
      data: view({}),
    } as never);
    stage([
      view({
        drift: [inTheWay("release-notes", "claude")],
        exits: [exit("skill:release-notes:claude")],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, REPLACE_FILES_LABEL));
    // The dialog renders into a portal, so the confirm is off the page's
    // own tree.
    await press(button(dialog(), REPLACE_FILES_CONFIRM_LABEL));

    expect(commands.replaceUnmanagedItem).toHaveBeenCalledWith(
      ACME,
      "skill",
      "release-notes",
    );
  });

  it("keeps through every tool core says the move acts on", async () => {
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "ok",
      data: view({}),
    } as never);
    stage([
      view({
        drift: [
          inTheWay("browser", "claude", { cause: "shared-link" }),
          inTheWay("browser", "codex", { cause: "shared-link" }),
        ],
        exits: [
          exit("skill:browser:claude", {
            replace: false,
            tools: ["claude", "codex"],
          }),
          exit("skill:browser:codex", {
            enter: false,
            replace: false,
            tools: ["claude", "codex"],
          }),
        ],
      }),
    ]);
    const host = mount(<ProblemsPage />);
    await settle();

    await press(button(host, KEEP_FILES_LABEL));
    await press(button(dialog(), KEEP_FILES_CONFIRM_LABEL));

    // Codex has no exit of its own here and still reads the folder, so the
    // keep names it: core answers which tools the move acts on, and an
    // offer naming only the rows with buttons would repoint it in silence.
    expect(commands.adoptItem).toHaveBeenCalledWith(ACME, "skill", "browser", [
      "claude",
      "codex",
    ]);
  });
});
