import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackageDependencies } from "@/bindings";
import {
  DEPENDENCY_INSTALLED_NOTE,
  DEPENDENCY_NOT_OFFERED_NOTE,
} from "@/lib/copy-marketplaces";
import { DependencyChoice, DependencyFacts } from "./package-dependencies";

const deps = (
  extra: Partial<PackageDependencies> = {},
): PackageDependencies => ({
  required: [],
  optional: [],
  ...extra,
});

describe("the package page's dependency facts", () => {
  it("names what comes with the package and what it offers", () => {
    const html = renderToStaticMarkup(
      <DependencyFacts
        dependencies={deps({
          required: [{ name: "code-quality", state: "available" }],
          optional: [{ name: "linear", state: "available" }],
        })}
      />,
    );
    expect(html).toContain("Requires");
    expect(html).toContain("code-quality");
    expect(html).toContain("Optional");
    expect(html).toContain("linear");
  });

  it("says a dependency is already here rather than about to arrive", () => {
    const html = renderToStaticMarkup(
      <DependencyFacts
        dependencies={deps({
          required: [{ name: "code-quality", state: "installed" }],
        })}
      />,
    );
    expect(html).toContain(DEPENDENCY_INSTALLED_NOTE);
  });

  it("says nothing at all for a package that declares nothing", () => {
    expect(
      renderToStaticMarkup(<DependencyFacts dependencies={deps()} />),
    ).toBe("");
  });
});

describe("the install picker's dependency choice", () => {
  const choice = (dependencies: PackageDependencies, chosen: string[] = []) =>
    renderToStaticMarkup(
      <DependencyChoice
        dependencies={dependencies}
        chosen={chosen}
        onChange={() => {}}
      />,
    );

  it("leaves every optional extra unticked until someone ticks it", () => {
    const html = choice(
      deps({ optional: [{ name: "linear", state: "available" }] }),
    );
    expect(html).toContain("linear");
    expect(html).not.toContain('data-checked=""');
    expect(html).not.toContain('data-disabled=""');
  });

  it("shows a ticked extra as ticked", () => {
    const html = choice(
      deps({ optional: [{ name: "linear", state: "available" }] }),
      ["linear"],
    );
    expect(html).toContain('data-checked=""');
  });

  it("cannot ask for an extra the catalog no longer offers", () => {
    const html = choice(
      deps({ optional: [{ name: "gone", state: "not-offered" }] }),
    );
    expect(html).toContain(DEPENDENCY_NOT_OFFERED_NOTE);
    expect(html).toContain('data-disabled=""');
  });
});
