import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { harnessName } from "@/lib/labels";
import { showEverythingLabel } from "@/lib/show-everything-label";
import { HarnessRow } from "./harness-row";

const render = (detectedRoot: string | null) =>
  renderToStaticMarkup(
    <HarnessRow
      id="claude"
      detectedRoot={detectedRoot}
      version={null}
      counts={[["skill", 3]]}
      folder=""
      onFolderChange={() => {}}
    />,
  );

describe("the harness row's name", () => {
  it("is a button asking for everything the harness has", () => {
    const shown = render("/home/u/.claude");
    expect(shown).toMatch(/<button[^>]*>Claude Code<\/button>/);
    expect(shown).toContain(
      `aria-label="${showEverythingLabel(harnessName("claude"))}"`,
    );
  });

  // One phrase for one affordance: the project card announces its name
  // button with the same helper, and a harness row drifting to its own
  // wording would make the same control read as two different ones.
  it("announces itself with the project card's label", () => {
    expect(showEverythingLabel(harnessName("claude"))).toBe(
      "Show everything in Claude Code",
    );
  });

  it("offers nothing to show for a harness that is not installed", () => {
    const shown = render(null);
    expect(shown).not.toContain("Show everything");
    expect(shown).not.toMatch(/<button[^>]*>Claude Code<\/button>/);
  });
});
