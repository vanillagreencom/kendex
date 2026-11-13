// @vitest-environment jsdom
import { act } from "react";
import { toast } from "sonner";
import { afterAll, beforeAll, beforeEach, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useMineStore } from "@/stores/mine";
import { mount, settle } from "@/test/dom";
import { MineImportDialog } from "./mine-import-dialog";

vi.mock("@/bindings", () => ({
  commands: {
    mineImportInventory: vi.fn(),
    mineImportApply: vi.fn(),
    mineList: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { message: vi.fn() } }));

// jsdom has no animations API; the real scroll viewport asks for running animations.
beforeAll(() => {
  Element.prototype.getAnimations = () => [];
});
afterAll(() => {
  Reflect.deleteProperty(Element.prototype, "getAnimations");
});

beforeEach(() => {
  vi.clearAllMocks();
  useMineStore.setState({
    candidates: null,
    outcome: null,
    busy: false,
    actionError: null,
  });
  vi.mocked(commands.mineList).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.mineImportInventory).mockResolvedValue({
    status: "ok",
    data: [
      {
        kind: "skill",
        name: "house-style",
        nameProblem: null,
        origins: [
          {
            group: { group: "unmanaged" },
            locations: ["/work/acme/.claude/skills/house-style"],
            hash: "selected-bytes",
            problem: null,
          },
        ],
      },
    ],
  });
});

it.each([
  { warnings: [] },
  { warnings: ["skills/house-style: link target could not be represented"] },
])(
  "presents import conversion warnings with the completed action: $warnings",
  async ({ warnings }) => {
    vi.mocked(commands.mineImportApply).mockResolvedValue({
      status: "ok",
      data: { written: ["skills/house-style"], alreadyPresent: [], warnings },
    });
    mount(
      <MineImportDialog target="/work/catalog" open onOpenChange={() => {}} />,
    );
    await settle();
    const choice = document.querySelector<HTMLElement>(
      '[aria-label="Import house-style"]',
    );
    if (!choice) throw new Error("missing import choice");
    await act(async () => choice.click());
    const submit = [
      ...document.querySelectorAll<HTMLButtonElement>("button"),
    ].find((button) => button.textContent === "Import 1");
    if (!submit) throw new Error("missing import action");
    await act(async () => submit.click());
    expect(commands.mineImportApply).toHaveBeenCalledWith("/work/catalog", [
      {
        kind: "skill",
        name: "house-style",
        destination: "house-style",
        hash: "selected-bytes",
        licenseConfirmed: false,
        licenseBasis: null,
      },
    ]);
    expect(document.body.textContent).toContain("Imported skills/house-style");
    // Converter text is the action's result, passed unchanged to the shared presenter.
    expect(
      vi.mocked(toast.message).mock.calls.map(([warning]) => warning),
    ).toEqual(warnings);
  },
);
