import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackageView } from "@/bindings";
import { SAFETY_CAVEAT } from "@/lib/copy-safety";
import { AvailableAside } from "./available-aside";

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
      marketplace="kendex"
      repo={null}
      view={view}
      selectedFile={null}
      onSelectFile={() => {}}
    />,
  );

describe("the available package's facts column", () => {
  it("names its source and leaves the safety reading to the main column", () => {
    const html = render(checked);
    expect(html).toContain("kendex");
    expect(html).not.toContain("100/100");
    expect(html).not.toContain(SAFETY_CAVEAT);
  });
});
