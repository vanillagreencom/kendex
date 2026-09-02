import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackageView } from "@/bindings";
import { SAFETY_CAVEAT } from "@/lib/copy-safety";
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
    dependencies: { required: [], optional: [] },
    state: "available",
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

describe("the available package's facts column", () => {
  it("says where the package comes from", () => {
    expect(render(checked)).toContain("kendex");
  });

  // The score and the findings that produced it are one block, in the main
  // column. A number here and its findings elsewhere would be two claims
  // about one reading, and the caveat would end up under only one of them.
  it("leaves the whole safety reading to the main column", () => {
    const html = render(checked);
    expect(html).not.toContain("100/100");
    expect(html).not.toContain(SAFETY_CAVEAT);
  });
});
