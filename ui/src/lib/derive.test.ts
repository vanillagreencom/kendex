import { describe, expect, it } from "vitest";
import type { ObservedItem } from "@/bindings";
import { KINDS } from "@/lib/labels";
import type { PackageOf } from "@/lib/package-identity";
import {
  filterItems,
  groupFor,
  groupItems,
  groupScopes,
  groupsOfKind,
  groupVendor,
  installationAt,
  installedCount,
  installedCountByKind,
  recentItems,
  scopeMatches,
} from "./derive";

/** Nothing recorded who wrote these: the honest answer where no fixture
 *  says otherwise, and the state every observation starts in. */
const unrecorded: PackageOf = () => null;

function item(overrides: Partial<ObservedItem>): ObservedItem {
  return {
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    path: "/h/.claude/skills/deploy",
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    description: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
    ...overrides,
  };
}

describe("scopeMatches", () => {
  it("matches all, global, and specific projects", () => {
    const global = item({});
    const project = item({ scope: { scope: "project", root: "/p" } });
    expect(scopeMatches(global, "all")).toBe(true);
    expect(scopeMatches(global, "global")).toBe(true);
    expect(scopeMatches(global, { project: "/p" })).toBe(false);
    expect(scopeMatches(project, "global")).toBe(false);
    expect(scopeMatches(project, { project: "/p" })).toBe(true);
    expect(scopeMatches(project, { project: "/other" })).toBe(false);
  });
});

describe("filterItems", () => {
  const items = [
    item({ name: "deploy" }),
    item({ name: "review", kind: "agent", harness: "pi" }),
    item({ name: "gh", description: "github helper" }),
  ];

  it("filters by harness and search over name+description", () => {
    const rows = [
      {
        name: "harness",
        filter: { scope: "all", harness: "pi" },
        expected: ["review"],
      },
      {
        name: "description",
        filter: { scope: "all", search: "GITHUB" },
        expected: ["gh"],
      },
      {
        name: "unfiltered",
        filter: { scope: "all" },
        expected: ["deploy", "review", "gh"],
      },
    ] as const;
    expect(rows.length, "library item filter table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(
        filterItems(items, row.filter).map((one) => one.name),
        row.name,
      ).toEqual(row.expected);
  });
});

describe("filterItems by where it lives", () => {
  const items = [
    item({ name: "a", scope: { scope: "project", root: "/a" } }),
    item({ name: "b", scope: { scope: "project", root: "/b" } }),
    item({ name: "g", scope: { scope: "global" } }),
  ];

  it("narrows to one project, to personal, or to everything", () => {
    const rows = [
      { name: "one project", scope: { project: "/a" }, expected: ["a"] },
      { name: "personal", scope: "global", expected: ["g"] },
      { name: "everything", scope: "all", expected: ["a", "b", "g"] },
    ] as const;
    expect(
      rows.length,
      "library location filter table is empty",
    ).toBeGreaterThan(0);
    for (const row of rows)
      expect(
        filterItems(items, { scope: row.scope }).map((one) => one.name),
        row.name,
      ).toEqual(row.expected);
  });

  it("combines where it lives with the other filters", () => {
    expect(
      filterItems(items, { scope: { project: "/a" }, search: "b" }),
    ).toHaveLength(0);
    expect(
      filterItems(items, { scope: { project: "/a" }, search: "a" }),
    ).toHaveLength(1);
  });
});

// The table applies no sort of its own, so the order groupItems hands back
// is the order on screen: its type column, then its name. Whether a row is a
// package the records account for is identity, not an order a reader can
// see.
describe("groupItems order", () => {
  it("orders by the columns shown, not by the identity behind them", () => {
    const rows = groupItems(
      [
        item({ kind: "skill", name: "alpha" }),
        item({ kind: "agent", name: "bravo" }),
        item({ kind: "agent", name: "alpha" }),
      ],
      // The one row the records account for sorts FIRST by the columns on
      // screen and LAST under a key-ordered sort, so the two orders cannot
      // both pass.
      (one) =>
        one.kind === "agent" && one.name === "alpha"
          ? { kind: "agent", name: "alpha" }
          : null,
    );
    expect(rows.map((row) => `${row.kind}:${row.name}`)).toEqual([
      "agent:alpha",
      "agent:bravo",
      "skill:alpha",
    ]);
  });
});

// Which kind a package is belongs to the package, not to the file a tool
// happens to keep it in — so the narrowing is taken of the grouped row.
describe("groupsOfKind", () => {
  it("keeps the rows whose package is that kind", () => {
    const groups = groupItems(
      [item({ name: "deploy" }), item({ name: "review", kind: "agent" })],
      unrecorded,
    );
    expect(groupsOfKind(groups, "agent").map((g) => g.name)).toEqual([
      "review",
    ]);
    expect(groupsOfKind(groups, "hook")).toEqual([]);
  });

  it("keeps a package a tool stores as another kind under its own kind", () => {
    const rule = item({
      kind: "agent",
      name: "safety-block-bare-cd",
      harness: "cursor",
      path: "/p/.cursor/rules/safety-block-bare-cd.mdc",
    });
    const groups = groupItems([rule], () => ({
      kind: "hook",
      name: "block-bare-cd",
    }));
    expect(groupsOfKind(groups, "hook").map((g) => g.name)).toEqual([
      "block-bare-cd",
    ]);
    expect(groupsOfKind(groups, "agent")).toEqual([]);
  });
});

// The reported defect: one hook installed for several tools showed a row
// per tool, because each tool stores it under a spelling of its own.
describe("groupItems by package identity", () => {
  const native = item({
    kind: "hook",
    name: "PreToolUse:Bash:block-bare-cd",
    harness: "claude",
    path: "/p/.claude/settings.json",
    fileState: { state: "config-entry" },
  });
  const rule = item({
    kind: "agent",
    name: "safety-block-bare-cd",
    harness: "cursor",
    path: "/p/.cursor/rules/safety-block-bare-cd.mdc",
  });
  const instruction = item({
    kind: "hook",
    name: "kendex-hook-block-bare-cd",
    harness: "opencode",
    path: "/p/.opencode/instructions/kendex-hook-block-bare-cd.md",
  });
  const hook = { kind: "hook" as const, name: "block-bare-cd" };

  it("puts every tool's rendering of one package on one row", () => {
    const groups = groupItems([native, rule, instruction], () => hook);
    expect(groups).toHaveLength(1);
    expect(groups[0].package).toEqual(hook);
    expect(groups[0].kind).toBe("hook");
    expect(groups[0].name).toBe("block-bare-cd");
    expect(groups[0].harnesses).toEqual(["claude", "cursor", "opencode"]);
    // The registrations and the files stay reachable: an execution detail
    // is what an audit reads, and collapsing the row must not lose it.
    expect(groups[0].installations.map((i) => i.name)).toEqual([
      native.name,
      rule.name,
      instruction.name,
    ]);
  });

  it("keeps installations nothing accounts for apart", () => {
    const mine = item({
      kind: "agent",
      name: "safety-block-bare-cd",
      harness: "cursor",
      path: "/other/.cursor/rules/safety-block-bare-cd.mdc",
      scope: { scope: "project", root: "/other" },
    });
    const groups = groupItems([rule, mine], (one) =>
      one.path === rule.path ? hook : null,
    );
    expect(groups.map((g) => [g.kind, g.name, g.package])).toEqual([
      ["agent", "safety-block-bare-cd", null],
      ["hook", "block-bare-cd", hook],
    ]);
  });

  it("keeps two packages that only read alike apart", () => {
    const one = item({ kind: "hook", name: "PreToolUse:Bash:guard" });
    const two = item({
      kind: "hook",
      name: "PostToolUse:Write:guard",
      harness: "codex",
    });
    const groups = groupItems([one, two], (item) =>
      item.harness === "claude"
        ? { kind: "hook", name: "guard" }
        : { kind: "hook", name: "audit" },
    );
    expect(groups.map((g) => g.name)).toEqual(["audit", "guard"]);
  });

  it("counts one package once however many tools hold it", () => {
    expect(
      installedCount(groupItems([native, rule, instruction], () => hook)),
    ).toBe(1);
    expect(
      installedCountByKind([native, rule, instruction], {}, () => hook).get(
        "hook",
      ),
    ).toBe(1);
  });
});

// Two things can wear one kind and name: a package the records account for,
// and an installation nothing recorded. Their files, tools and comparison
// come from one and their versions, update note and Delete from the other,
// so a link that opened the wrong one would describe one and act on the
// other.
describe("groupFor", () => {
  const managed = item({
    kind: "skill",
    name: "gh",
    harness: "claude",
    path: "/p/.claude/skills/gh",
    scope: { scope: "project", root: "/p" },
  });
  const mine = item({
    kind: "skill",
    name: "gh",
    harness: "cursor",
    path: "/p/.cursor/skills/gh",
    scope: { scope: "project", root: "/p" },
  });
  const elsewhere = item({
    kind: "skill",
    name: "gh",
    harness: "cursor",
    path: "/other/.cursor/skills/gh",
    scope: { scope: "project", root: "/other" },
  });
  const recordedOnly: PackageOf = (one) =>
    one.harness === "claude" ? { kind: "skill", name: "gh" } : null;
  const gh = { kind: "skill" as const, name: "gh" };

  it("opens the one the link named, in the same place and in another", () => {
    const rows = [
      { name: "same place", items: [managed, mine] },
      { name: "different places", items: [managed, elsewhere] },
    ] as const;
    expect(rows.length, "same-name identity table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      const groups = groupItems([...row.items], recordedOnly);
      expect(
        groupFor(groups, { ...gh, identity: "recorded" })?.installations.map(
          (one) => one.harness,
        ),
        row.name,
      ).toEqual(["claude"]);
      expect(
        groupFor(groups, { ...gh, identity: "observed" })?.installations.map(
          (one) => one.harness,
        ),
        row.name,
      ).toEqual(["cursor"]);
    }
  });

  it("opens the only thing wearing that name whichever it is", () => {
    const only = groupItems([mine], recordedOnly);
    expect(groupFor(only, { ...gh, identity: "recorded" })).toBe(only[0]);
    const one = groupItems([managed], recordedOnly);
    expect(groupFor(one, { ...gh, identity: "observed" })).toBe(one[0]);
  });

  it("opens nothing it was not asked for", () => {
    const groups = groupItems([managed, mine], recordedOnly);
    expect(
      groupFor(groups, { kind: "agent", name: "gh", identity: "recorded" }),
    ).toBeNull();
    expect(groupFor(groups, { ...gh, identity: "recorded" })?.package).toEqual(
      gh,
    );
  });
});

describe("groupItems", () => {
  it("groups installations under the logical item and flags shared artifacts", () => {
    const shared = "/p/.agents/skills/deploy";
    const groups = groupItems(
      [
        item({
          harness: "codex",
          path: shared,
          scope: { scope: "project", root: "/p" },
        }),
        item({
          harness: "pi",
          path: shared,
          scope: { scope: "project", root: "/p" },
        }),
        item({ name: "solo", harness: "claude" }),
      ],
      unrecorded,
    );
    expect(groups).toHaveLength(2);
    const deploy = groups.find((g) => g.name === "deploy");
    expect(deploy?.installations).toHaveLength(2);
    expect(deploy?.harnesses.sort()).toEqual(["codex", "pi"]);
    expect(deploy?.shared).toBe(true);
    expect(groups.find((g) => g.name === "solo")?.shared).toBe(false);
  });

  it("takes the most recent modifiedAt across installations, or null when none have one", () => {
    const withTimes = groupItems(
      [
        item({ name: "deploy", harness: "claude", modifiedAt: 100 }),
        item({ name: "deploy", harness: "codex", modifiedAt: 300 }),
      ],
      unrecorded,
    );
    expect(withTimes.find((g) => g.name === "deploy")?.modifiedAt).toBe(300);

    const withoutTimes = groupItems([item({ name: "solo" })], unrecorded);
    expect(withoutTimes.find((g) => g.name === "solo")?.modifiedAt).toBeNull();
  });
});

describe("installedCount", () => {
  it("counts packages, not installations", () => {
    expect(
      installedCount(
        groupItems(
          [
            item({ harness: "claude" }),
            item({ harness: "codex" }),
            item({ name: "solo" }),
          ],
          unrecorded,
        ),
      ),
    ).toBe(2);
  });

  it("keeps same-named items of different kinds apart", () => {
    expect(
      installedCount(
        groupItems([item({}), item({ kind: "agent" })], unrecorded),
      ),
    ).toBe(2);
  });
});

describe("groupScopes", () => {
  it("lists each distinct scope an item is installed in, once", () => {
    const groups = groupItems(
      [
        item({
          name: "github",
          harness: "claude",
          scope: { scope: "project", root: "/acme" },
        }),
        item({
          name: "github",
          harness: "codex",
          scope: { scope: "project", root: "/acme" },
        }),
        item({
          name: "github",
          harness: "claude",
          scope: { scope: "project", root: "/api" },
        }),
      ],
      unrecorded,
    );
    const scopes = groupScopes(groups[0]);
    expect(scopes).toHaveLength(2);
    expect(
      scopes.map((s) => (s.scope === "project" ? s.root : s.scope)),
    ).toEqual(["/acme", "/api"]);
  });
});

describe("installedCountByKind", () => {
  it("tallies per kind", () => {
    const counts = installedCountByKind(
      [item({}), item({ name: "x" }), item({ kind: "agent" })],
      {},
      unrecorded,
    );
    expect(counts.get("skill")).toBe(2);
    expect(counts.get("agent")).toBe(1);
  });

  it("counts packages, not installations", () => {
    const counts = installedCountByKind(
      [
        item({ harness: "claude" }),
        item({ harness: "codex" }),
        item({ scope: { scope: "project", root: "/p" } }),
      ],
      {},
      unrecorded,
    );
    expect(counts.get("skill")).toBe(1);
  });

  it("counts only what the place holds", () => {
    const items = [
      item({}),
      item({ name: "elsewhere", harness: "codex" }),
      item({ name: "over-there", scope: { scope: "project", root: "/p" } }),
    ];
    expect(
      installedCountByKind(items, { harness: "claude" }, unrecorded).get(
        "skill",
      ),
    ).toBe(2);
    expect(
      installedCountByKind(items, { scope: "global" }, unrecorded).get("skill"),
    ).toBe(2);
    expect(
      installedCountByKind(items, { scope: { project: "/p" } }, unrecorded).get(
        "skill",
      ),
    ).toBe(1);
  });

  // The badges sit beside the Library's kind filter, which lists kinds in
  // KINDS order. Grouping sorts on `kind:name`, so tallying straight off the
  // groups hands back the wire order instead.
  it("hands the kinds back in the order the app shows them in", () => {
    const items = KINDS.map((kind) => item({ kind, name: `one-${kind}` }));
    expect([...installedCountByKind(items, {}, unrecorded).keys()]).toEqual(
      KINDS,
    );
  });

  it("leaves out a kind the place holds nothing of", () => {
    const counts = installedCountByKind(
      [item({ kind: "agent" })],
      {},
      unrecorded,
    );
    expect(counts.has("skill")).toBe(false);
  });
});

describe("recentItems", () => {
  it("sorts by modifiedAt descending and drops groups with no timestamp", () => {
    const groups = groupItems(
      [
        item({ name: "old", modifiedAt: 100 }),
        item({ name: "new", modifiedAt: 300 }),
        item({ name: "mid", modifiedAt: 200 }),
        item({ name: "never", modifiedAt: null }),
      ],
      unrecorded,
    );
    expect(recentItems(groups, 10).map((g) => g.name)).toEqual([
      "new",
      "mid",
      "old",
    ]);
  });

  it("caps at the requested limit", () => {
    const groups = groupItems(
      [
        item({ name: "a", modifiedAt: 1 }),
        item({ name: "b", modifiedAt: 2 }),
        item({ name: "c", modifiedAt: 3 }),
      ],
      unrecorded,
    );
    expect(recentItems(groups, 2).map((group) => group.name)).toEqual([
      "c",
      "b",
    ]);
  });
});

describe("groupVendor", () => {
  it("names the vendor only when every installation agrees it is theirs", () => {
    const bundled = groupItems(
      [
        item({
          kind: "plugin",
          name: "chrome@openai-bundled",
          vendor: "OpenAI",
        }),
        item({
          kind: "plugin",
          name: "chrome@openai-bundled",
          harness: "codex",
          vendor: "OpenAI",
        }),
      ],
      unrecorded,
    );
    expect(groupVendor(bundled[0])).toBe("OpenAI");

    const mixed = groupItems(
      [
        item({ kind: "plugin", name: "gh", vendor: "OpenAI" }),
        item({ kind: "plugin", name: "gh", harness: "codex", vendor: null }),
      ],
      unrecorded,
    );
    expect(groupVendor(mixed[0])).toBeNull();
  });
});

describe("installationAt", () => {
  const vg = { scope: "project" as const, root: "/work/vg" };
  const hypr = { scope: "project" as const, root: "/work/hyprtrade" };
  const group = groupItems(
    [
      item({ name: "gh", scope: vg, harness: "claude" }),
      item({ name: "gh", scope: hypr, harness: "codex" }),
    ],
    unrecorded,
  )[0];

  // Everything a page reads about a file — its path, its harness, the
  // rendering a comparison is against — belongs to one place. Another
  // place's is a different tool's path and a different rendering.
  it("answers with the copy belonging to the place asked about", () => {
    expect(installationAt(group, hypr)?.harness).toBe("codex");
    expect(installationAt(group, vg)?.harness).toBe("claude");
  });

  it("has nothing for a place the package is not installed in", () => {
    expect(installationAt(group, { scope: "global" })).toBeUndefined();
  });

  it("has nothing to answer with when there is no group or no place", () => {
    expect(installationAt(null, vg)).toBeUndefined();
    expect(installationAt(group, null)).toBeUndefined();
  });
});
