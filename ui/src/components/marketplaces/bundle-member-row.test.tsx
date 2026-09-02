import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { BundleMemberRow } from "@/bindings";
import { PACKAGE_STATE_UNKNOWN } from "@/lib/copy-marketplaces";
import { BundleMemberLine } from "./bundle-member-row";

const member: BundleMemberRow = {
  kind: "skill",
  name: "gh",
  state: "available",
};

const render = (state: BundleMemberRow["state"]) =>
  renderToStaticMarkup(
    <BundleMemberLine
      member={{ ...member, state }}
      selectable
      selected={false}
      busy={false}
      onToggle={() => {}}
      onRestore={() => {}}
    />,
  );

// The set page and the packages table read the same record, so a project
// whose lock could not be read says the same thing on both. A member drawn
// as available here would offer a box to install it with.
describe("a set member whose project records could not be read", () => {
  it("says its state is not known", () => {
    const html = render("unknown");
    expect(html).toContain(PACKAGE_STATE_UNKNOWN);
    expect(html).not.toContain('title="Available"');
  });

  it("cannot be picked for install", () => {
    expect(render("unknown")).toContain('disabled=""');
    expect(render("available")).not.toContain('disabled=""');
  });
});
