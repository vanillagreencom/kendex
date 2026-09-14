// @vitest-environment jsdom
import { act } from "react";
import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { BlockedDeclarations } from "@/components/blocked-declarations";
import { TooltipProvider } from "@/components/ui/tooltip";
import { mergeDriftRows, summarizePaths } from "@/lib/drift-merge";
import { Exits } from "@/lib/exits";
import { mount } from "@/test/dom";

const PATHS = [
  "/work/acme/.claude/skills/deploy",
  "/work/acme/.agents/skills/deploy",
  "/work/acme/.codex/skills/deploy",
];

const row: DriftRow = {
  kind: "skill",
  name: "deploy",
  harness: "claude",
  scope: { scope: "project", root: "/work/acme" },
  state: "conflict",
  cause: "unmanaged-content",
  detail: PATHS[0],
  alsoInTheWay: PATHS.slice(1),
};

const pointer = (target: Element, type: string, clientX: number) =>
  act(() => {
    target.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX }));
  });

describe("the path under a blocked item", () => {
  // The path is cut short on screen, so the tooltip is the only place the
  // whole of it can be read — for as long as the pointer rests on it.
  it("keeps the full paths on screen while the pointer moves along them", () => {
    const host = mount(
      <TooltipProvider>
        <BlockedDeclarations
          rows={mergeDriftRows([row])}
          exits={
            new Exits([
              {
                key: "skill:deploy:claude",
                blocking: true,
                files: true,
                keep: true,
                enter: true,
                replace: true,
                tools: ["claude"],
              },
            ])
          }
          alsoApplies={false}
          busy={false}
          onKeep={async () => {}}
          onReplace={async () => {}}
        />
      </TooltipProvider>,
    );
    const shown = summarizePaths(PATHS)?.text;
    const path = [...host.querySelectorAll("span")].find(
      (span) => span.textContent === shown,
    );
    if (!path) throw new Error("no path summary rendered");

    pointer(path, "mouseenter", 10);
    for (const x of [20, 60, 120, 200]) pointer(path, "mousemove", x);

    const content = document.querySelector('[data-slot="tooltip-content"]');
    expect(content).not.toBeNull();
    expect(content?.textContent).toBe(PATHS.join("\n"));
  });
});
