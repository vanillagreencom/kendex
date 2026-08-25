import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { START_MANAGING_LABEL, startManagingAllLabel } from "@/lib/copy";
import type { MergedDriftRow } from "@/lib/drift-merge";
import { UnmanagedItems } from "./unmanaged-items";

const install = (name: string, harness: DriftRow["harness"]): DriftRow => ({
  kind: "skill",
  name,
  harness,
  state: "unmanaged",
  detail: `~/.claude/skills/${name}`,
  scope: { scope: "global" },
});

const group = (name: string, harnesses: DriftRow["harness"][]) =>
  ({
    kind: "skill",
    name,
    state: "unmanaged",
    installations: harnesses.map((harness) => install(name, harness)),
  }) as MergedDriftRow;

const render = (rows: MergedDriftRow[]) =>
  renderToStaticMarkup(
    <UnmanagedItems rows={rows} busy={false} onAdopt={async () => true} />,
  );

describe("a place's unmanaged items", () => {
  // The summary row exists to carry the one action covering the whole list.
  // Over a single item it repeats that item's own row and its own button.
  it("summarises only once there is more than one to summarise", () => {
    expect(render([group("gh", ["claude"])])).not.toContain(
      startManagingAllLabel(1),
    );
    const two = render([group("gh", ["claude"]), group("lint", ["codex"])]);
    expect(two).toContain(startManagingAllLabel(2));
    expect(two).toContain("2 Skills");
  });

  // Nothing folds here: the page this sits on is about exactly this list, so
  // every row arrives ready to act on rather than behind a chevron.
  it("shows every row with its own offer, none hidden", () => {
    const html = render([
      group("gh", ["claude", "codex"]),
      group("lint", ["codex"]),
      group("fmt", ["pi"]),
    ]);
    for (const name of ["gh", "lint", "fmt"]) expect(html).toContain(name);
    // The summary's own button reads "Start managing all 3", so only the
    // per-row label exactly is counted.
    expect(html.split(`>${START_MANAGING_LABEL}<`).length - 1).toBe(3);
  });

  it("renders nothing at all where a place has nothing unmanaged", () => {
    expect(render([])).toBe("");
  });
});
