import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackageDependencies } from "@/bindings";
import {
  DEPENDENCY_AMBIGUOUS_NOTE,
  DEPENDENCY_INSTALLED_NOTE,
  DEPENDENCY_NOT_OFFERED_NOTE,
  DEPENDENCY_REMOVED_NOTE,
  DEPENDENCY_UNKNOWN_NOTE,
} from "@/lib/copy-marketplaces";
import { DependencyChoice, DependencyFacts } from "./package-dependencies";

const declared: PackageDependencies = {
  required: [
    { name: "code-quality", shown: "code-quality", state: "installed" },
    { name: "dup", shown: "dup", state: "offered-more-than-once" },
  ],
  optional: [
    { name: "linear", shown: "linear", state: "available" },
    { name: "removed", shown: "removed", state: "removed-by-you" },
  ],
};

const empty: PackageDependencies = { required: [], optional: [] };

/** Static markup escapes an apostrophe, so copy carrying one is compared
 *  in the form it renders as. */
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

const facts = (dependencies: PackageDependencies) =>
  renderToStaticMarkup(<DependencyFacts dependencies={dependencies} />);

const picker = (dependencies: PackageDependencies) =>
  renderToStaticMarkup(
    <DependencyChoice
      dependencies={dependencies}
      chosen={[]}
      onChange={() => {}}
    />,
  );

/** Both surfaces the issue names draw this one component — the package
 *  page's facts column and the install picker — so what a state says, and
 *  whether an extra can be ticked, is settled once for both. */
describe("a package's declared dependencies on both surfaces", () => {
  it("names each list, says what each state means, and ticks nothing by default", () => {
    for (const html of [facts(declared), picker(declared)]) {
      expect(html).toContain("Requires");
      expect(html).toContain("code-quality");
      expect(html).toContain(DEPENDENCY_INSTALLED_NOTE);
      // Carried twice under different plugins: the catalog does offer it,
      // so saying it is not offered would be the opposite of true.
      expect(html).toContain(DEPENDENCY_AMBIGUOUS_NOTE);
      expect(html).toContain("Optional");
      expect(html).toContain("linear");
      // The person's own removal, not a broken catalog line.
      expect(html).toContain(DEPENDENCY_REMOVED_NOTE);
    }
    // Every optional box starts off, and the two the engine will not take
    // cannot be asked for at all.
    const html = picker(declared);
    expect(html).not.toContain('data-checked=""');
    expect(html.match(/data-disabled=""/g)).toHaveLength(1);
  });

  it("says nothing on either surface for a package that declares none", () => {
    expect(facts(empty)).toBe("");
    expect(picker(empty)).not.toContain("Optional");
  });
});

// The landing scope is the destination a redirected install picks, and its
// lock may be one this build refuses while the browsed scope reads fine. A
// dependency there is not missing and not present — nothing read the record
// that would say — and an install asked for it meets that same record.
describe("a dependency landing where the records cannot be read", () => {
  const unknown: PackageDependencies = {
    required: [
      { name: "code-quality", shown: "code-quality", state: "unknown" },
    ],
    optional: [{ name: "linear", shown: "linear", state: "unknown" }],
  };

  it("says why on both surfaces, rather than calling it not offered", () => {
    for (const html of [facts(unknown), picker(unknown)]) {
      expect(html).toContain(esc(DEPENDENCY_UNKNOWN_NOTE));
      expect(html).not.toContain(DEPENDENCY_NOT_OFFERED_NOTE);
    }
  });

  it("does not let the optional one be asked for", () => {
    const html = picker(unknown);
    expect(html).not.toContain('data-checked=""');
    expect(html.match(/data-disabled=""/g)).toHaveLength(1);
  });
});
