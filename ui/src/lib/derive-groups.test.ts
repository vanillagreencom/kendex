import { describe, expect, it } from "vitest";
import { observedItem as item } from "@/lib/observed-test-item";
import { groupItems, groupScopes, groupVendor, installationIn } from "./derive";

// One package, several installations: which places it lives in, which
// installation a page about one place is about, and whose bundle it is.

describe("groupItems", () => {
  it("groups installations under the logical item and flags shared artifacts", () => {
    const shared = "/p/.agents/skills/deploy";
    const groups = groupItems([
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
    ]);
    expect(groups).toHaveLength(2);
    const deploy = groups.find((g) => g.name === "deploy");
    expect(deploy?.installations).toHaveLength(2);
    expect(deploy?.harnesses.sort()).toEqual(["codex", "pi"]);
    expect(deploy?.shared).toBe(true);
    expect(groups.find((g) => g.name === "solo")?.shared).toBe(false);
  });

  it("takes the most recent modifiedAt across installations, or null when none have one", () => {
    const withTimes = groupItems([
      item({ name: "deploy", harness: "claude", modifiedAt: 100 }),
      item({ name: "deploy", harness: "codex", modifiedAt: 300 }),
    ]);
    expect(withTimes.find((g) => g.name === "deploy")?.modifiedAt).toBe(300);

    const withoutTimes = groupItems([item({ name: "solo" })]);
    expect(withoutTimes.find((g) => g.name === "solo")?.modifiedAt).toBeNull();
  });
});

describe("groupScopes", () => {
  it("lists each distinct scope an item is installed in, once", () => {
    const groups = groupItems([
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
    ]);
    const scopes = groupScopes(groups[0]);
    expect(scopes).toHaveLength(2);
    expect(
      scopes.map((s) => (s.scope === "project" ? s.root : s.scope)),
    ).toEqual(["/acme", "/api"]);
  });
});

// A package page is about one installation — its path, its open actions,
// its broken-link state. Before the customized mark, every route into the
// page arrived at the first one, so which it was never mattered.

describe("installationIn", () => {
  const group = () =>
    groupItems([
      item({
        name: "github",
        harness: "claude",
        scope: { scope: "global" },
        path: "/home/me/.claude/skills/github",
      }),
      item({
        name: "github",
        harness: "claude",
        scope: { scope: "project", root: "/api" },
        path: "/api/.claude/skills/github",
      }),
    ])[0];

  it("is the installation in the place the page was opened at", () => {
    expect(
      installationIn(group(), { scope: "project", root: "/api" })?.path,
    ).toBe("/api/.claude/skills/github");
  });

  it("is the first install only when no place was named", () => {
    expect(installationIn(group(), null)?.path).toBe(
      "/home/me/.claude/skills/github",
    );
  });

  it("is nothing where the named place has no install", () => {
    // Substituting another place's would let the page describe a location
    // nobody asked about — reachable whenever nav state outlives a scope.
    expect(
      installationIn(group(), { scope: "project", root: "/nowhere" }),
    ).toBe(null);
  });
});

describe("groupVendor", () => {
  it("names the vendor only when every installation agrees it is theirs", () => {
    const bundled = groupItems([
      item({ kind: "plugin", name: "chrome@openai-bundled", vendor: "OpenAI" }),
      item({
        kind: "plugin",
        name: "chrome@openai-bundled",
        harness: "codex",
        vendor: "OpenAI",
      }),
    ]);
    expect(groupVendor(bundled[0])).toBe("OpenAI");

    const mixed = groupItems([
      item({ kind: "plugin", name: "gh", vendor: "OpenAI" }),
      item({ kind: "plugin", name: "gh", harness: "codex", vendor: null }),
    ]);
    expect(groupVendor(mixed[0])).toBeNull();
  });
});
