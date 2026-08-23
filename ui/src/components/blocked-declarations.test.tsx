import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { DriftRow, HarnessId, RowExits } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { KEEP_FILES_LABEL, MOVE_FILES_YOURSELF } from "@/lib/copy-in-the-way";
import { mergeDriftRows } from "@/lib/drift-merge";
import { Exits } from "@/lib/drift-zones";
import { BlockedDeclarations } from "./blocked-declarations";

function row(harness: HarnessId): DriftRow {
  return {
    kind: "skill",
    name: "browser",
    harness,
    scope: { scope: "project", root: "/w/app" },
    state: "conflict",
    detail: "/w/app/shared/browser",
    cause: "shared-link",
  };
}

const exit = (harness: HarnessId, enter: boolean): RowExits => ({
  key: `skill:browser:${harness}`,
  blocking: true,
  files: true,
  keep: true,
  enter,
  replace: false,
  tools: [harness],
});

const render = (exits: RowExits[]) =>
  renderToStaticMarkup(
    <BlockedDeclarations
      rows={mergeDriftRows([row("claude"), row("codex")])}
      adoptable={ADOPTABLE}
      exits={new Exits(exits)}
      alsoApplies={false}
      busy={false}
      onKeep={async () => {}}
      onReplace={async () => {}}
    />,
  );

describe("a folder shared through a shortcut", () => {
  // Adoption works at a tool's own place. The cause alone says the shape can
  // be kept; whether this tool is one it can be kept through is core's
  // answer, and a button drawn without it fails on the click.
  it("offers Keep while a tool it can be entered through is blocked", () => {
    const html = render([exit("claude", true), exit("codex", false)]);

    expect(html).toContain(KEEP_FILES_LABEL);
  });

  it("says to move the files instead where no tool can be entered", () => {
    const html = render([]);

    expect(html).not.toContain(KEEP_FILES_LABEL);
    expect(html).toContain(MOVE_FILES_YOURSELF);
  });
});
