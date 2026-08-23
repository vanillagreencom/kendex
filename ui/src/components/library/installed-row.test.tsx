import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { groupItems } from "@/lib/derive";
import type { PlaceMark } from "@/lib/place-marks";
import { InstalledRow } from "./installed-row";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const item = (scope: Scope) => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
  fileState: "file",
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
});

const group = groupItems([item(VG), item(HYPR)] as never)[0];

const render = (mark: PlaceMark | null, forkedIn: Scope[] = []) =>
  renderToStaticMarkup(
    <InstalledRow
      group={group}
      origin={null}
      mark={mark}
      forkedIn={forkedIn}
      onOpen={() => {}}
    />,
  );

describe("the row's customized mark", () => {
  it("is a way into the place it names", () => {
    const shown = render({
      label: "Customized in vg · 1 of 2 places",
      goTo: VG,
      why: "settings",
    });
    expect(shown).toContain("Customized in vg · 1 of 2 places");
    expect(shown).toMatch(/<button[^>]*>Customized in vg/);
  });

  // Naming two places and opening a third — the row's primary, which may
  // hold nothing — is the wrong-place fault this change exists to remove.
  it("offers no destination when it names more than one place", () => {
    const shown = render({
      label: "Customized in vg and hyprtrade · 2 of 2 places",
      goTo: null,
      why: null,
    });
    expect(shown).toContain("Customized in vg and hyprtrade");
    expect(shown).not.toMatch(/<button[^>]*>Customized/);
  });

  it("names the place each fork belongs to", () => {
    const shown = render(null, [VG]);
    expect(shown).toContain("in vg");
  });
});
