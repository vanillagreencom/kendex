import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackageView } from "@/bindings";
import { PREINSTALL_SAFETY_CAVEAT } from "@/lib/copy-safety";
import { subscription } from "@/stores/marketplaces-shared";
import { AvailableAside } from "./available-aside";

const catalog = subscription({ scope: "global" }, "kendex");

const checked: PackageView = {
  preview: {
    kind: "skill",
    name: "gh",
    description: null,
    tags: [],
    readme: null,
    files: [],
    bundles: [],
    collision: null,
  },
  safety: {
    kind: "skill",
    name: "gh",
    findings: [],
    safety: { score: 100, deductions: [] },
    quality: null,
    skipped: [],
    notes: [],
    contentHash: "abc",
    ruleset: 1,
    fromCache: false,
  },
};

const render = (view: PackageView | null) =>
  renderToStaticMarkup(
    <AvailableAside
      catalog={catalog}
      repo={null}
      view={view}
      selectedFile={null}
      onSelectFile={() => {}}
    />,
  );

describe("the available package's Safety column", () => {
  it("puts the caveat under the score, on the page that installs it", () => {
    const html = render(checked);
    expect(html).toContain("100/100");
    expect(html).toContain(PREINSTALL_SAFETY_CAVEAT);
    expect(html.indexOf("100/100")).toBeLessThan(
      html.indexOf(PREINSTALL_SAFETY_CAVEAT),
    );
  });

  it("says nothing about a check that has not answered yet", () => {
    expect(render(null)).not.toContain(PREINSTALL_SAFETY_CAVEAT);
  });
});
