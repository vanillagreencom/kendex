// @vitest-environment jsdom
// Only the import can say which links a copied skill kept: the copy reads
// the same afterwards whether a link was converted or kept. The dialog
// stays open on its outcome, so that is where they must be said.
import { describe, expect, it, vi } from "vitest";
import type { ImportOutcome } from "@/bindings";
import { IMPORT_LINKS_KEPT } from "@/lib/copy-marketplaces";
import { useMineStore } from "@/stores/mine";
import { mount, settle } from "@/test/dom";
import { MineImportDialog } from "./mine-import-dialog";

vi.mock("@/bindings", () => ({ commands: {} }));

const FIX = "use an absolute path or URL";

const kept = (file: string) => ({
  kind: "skill" as const,
  name: "house-style",
  harness: null,
  message: `skill-link-kept: ${file}: ../../memory/x.md`,
  remediation: FIX,
});

const said = () => document.body.textContent ?? "";

/** Count of `text` in what the window says. */
const times = (text: string) => said().split(text).length - 1;

describe("an import's outcome", () => {
  it.each<{ name: string; outcome: ImportOutcome; lines: string[] }>([
    {
      name: "two kept links share one fix",
      outcome: {
        written: ["house-style"],
        alreadyPresent: [],
        warnings: [kept("SKILL.md"), kept("references/a.md")],
      },
      lines: [kept("SKILL.md").message, kept("references/a.md").message],
    },
    {
      name: "every link converted",
      outcome: { written: ["house-style"], alreadyPresent: [] },
      lines: [],
    },
  ])("says what the copy kept: $name", async ({ outcome, lines }) => {
    // The inventory read is not under test: stubbed, the dialog opens on
    // the outcome already in the store.
    useMineStore.setState({
      outcome,
      candidates: [],
      loadInventory: async () => {},
      clearAction: () => {},
    });
    mount(
      <MineImportDialog target="/home/ada/kit" open onOpenChange={() => {}} />,
    );
    await settle();

    expect(said()).toContain("house-style");
    for (const line of lines) expect(said()).toContain(line);
    expect(times(IMPORT_LINKS_KEPT)).toBe(lines.length > 0 ? 1 : 0);
    expect(times(FIX)).toBe(lines.length > 0 ? 1 : 0);
  });
});
