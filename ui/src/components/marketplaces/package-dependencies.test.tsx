// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { Children, isValidElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { PackageDependencies } from "@/bindings";
import {
  DEPENDENCY_AMBIGUOUS_NOTE,
  DEPENDENCY_INSTALLED_NOTE,
  DEPENDENCY_NOT_OFFERED_NOTE,
  DEPENDENCY_REMOVED_NOTE,
  DEPENDENCY_UNKNOWN_NOTE,
} from "@/lib/copy-marketplaces";
import { mount } from "@/test/dom";
import { DependencyChoice, DependencyFacts } from "./package-dependencies";

const declared: PackageDependencies = {
  required: [
    {
      kind: "skill",
      name: "code-quality",
      shown: "code-quality",
      state: "installed",
    },
    {
      kind: "skill",
      name: "dup",
      shown: "dup",
      state: "offered-more-than-once",
    },
  ],
  optional: [
    { kind: "skill", name: "linear", shown: "linear", state: "available" },
    {
      kind: "skill",
      name: "removed",
      shown: "removed",
      state: "removed-by-you",
    },
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

const rowKeys = (node: ReactNode): (string | null)[] => {
  const keys: (string | null)[] = [];
  const visit = (children: ReactNode) => {
    Children.forEach(children, (child) => {
      if (!isValidElement<{ children?: ReactNode }>(child)) return;
      if (child.type === "li") keys.push(child.key);
      else visit(child.props.children);
    });
  };
  visit(node);
  return keys;
};

/** Both surfaces draw this one component — the package page's facts
 *  column and the install picker — so what a state says, and whether an
 *  extra can be ticked, is settled once for both. */
describe("a package's declared dependencies on both surfaces", () => {
  it("names each list, says what each state means, and ticks nothing by default", () => {
    const surfaces = [facts(declared), picker(declared)];
    expect(surfaces).toHaveLength(2);
    for (const html of surfaces) {
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
      {
        kind: "skill",
        name: "code-quality",
        shown: "code-quality",
        state: "unknown",
      },
    ],
    optional: [
      { kind: "skill", name: "linear", shown: "linear", state: "unknown" },
    ],
  };

  it("says why on both surfaces, rather than calling it not offered", () => {
    const surfaces = [facts(unknown), picker(unknown)];
    expect(surfaces).toHaveLength(2);
    for (const html of surfaces) {
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

// The catalog can require a skill and an agent with the same declared name.
// Each must keep its own kind and install state on both dependency surfaces.
describe("required dependencies with the same name across kinds", () => {
  const dependencies: PackageDependencies = {
    required: [
      { kind: "skill", name: "review", shown: "review", state: "installed" },
      { kind: "agent", name: "review", shown: "review", state: "available" },
    ],
    optional: [
      { kind: "skill", name: "linear", shown: "linear", state: "available" },
    ],
  };

  it.each(["facts", "choice"] as const)(
    "keeps each required kind and state distinct in %s",
    (surface) => {
      const errors = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        const rendered =
          surface === "facts"
            ? DependencyFacts({ dependencies })
            : DependencyChoice({
                dependencies,
                chosen: [],
                onChange: () => {},
              });
        expect(
          rowKeys(rendered).slice(0, dependencies.required.length),
        ).toEqual(["skill:review", "agent:review"]);
        const host = mount(
          surface === "facts" ? (
            <DependencyFacts dependencies={dependencies} />
          ) : (
            <DependencyChoice
              dependencies={dependencies}
              chosen={[]}
              onChange={() => {}}
            />
          ),
        );
        const required = host.querySelector("ul");
        const rows = required?.querySelectorAll("li");
        expect(rows).toHaveLength(dependencies.required.length);
        const labels: (string | undefined)[] = [];
        for (const [index, dependency] of dependencies.required.entries()) {
          const row = rows?.[index];
          expect(row?.firstChild?.textContent).toBe(dependency.shown);
          const label = row?.querySelector("span")?.textContent?.trim();
          expect(label).toMatch(/\S/);
          labels.push(label);
          expect(row?.querySelector("span")?.hidden).toBe(false);
          expect(row?.querySelectorAll("span")).toHaveLength(
            dependency.state === "installed" ? 2 : 1,
          );
        }
        expect(new Set(labels).size).toBe(dependencies.required.length);
        expect(required?.querySelector("input, button")).toBeNull();
        expect(errors).not.toHaveBeenCalled();
      } finally {
        errors.mockRestore();
      }
    },
  );

  it("chooses only the optional skill by declared name", async () => {
    const onChange = vi.fn();
    const host = mount(
      <DependencyChoice
        dependencies={dependencies}
        chosen={[]}
        onChange={onChange}
      />,
    );
    const checkbox = host.querySelector<HTMLElement>('[role="checkbox"]');
    expect(checkbox).not.toBeNull();
    await userEvent.click(checkbox!);
    expect(onChange).toHaveBeenCalledWith(["linear"]);
  });
});
