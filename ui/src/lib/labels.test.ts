import { describe, expect, it } from "vitest";
import {
  breadcrumbLabel,
  describesItself,
  harnessName,
  hookDisplayName,
  kindLabel,
  packageDisplayName,
  scopeName,
  scopePath,
} from "./labels";

describe("labels", () => {
  it("pluralizes kind labels by count", () => {
    expect(kindLabel("skill")).toBe("Skill");
    expect(kindLabel("skill", 3)).toBe("Skills");
    expect(kindLabel("mcp-server", 0)).toBe("MCP servers");
  });

  it("names scopes by folder, global by name", () => {
    expect(scopeName({ scope: "global" })).toBe("Personal");
    expect(scopeName({ scope: "project", root: "/home/x/acme-web" })).toBe(
      "acme-web",
    );
    expect(scopePath({ scope: "global" })).toBeNull();
    expect(scopePath({ scope: "project", root: "/home/x/acme-web" })).toBe(
      "/home/x/acme-web",
    );
  });

  it("names Claude by its display value", () => {
    expect(harnessName("claude")).toBe("Claude Code");
  });

  it("shows a hook's trailing name and falls back to the whole id", () => {
    expect(hookDisplayName("Notification:permission_prompt:tmux-bell")).toBe(
      "tmux-bell",
    );
    expect(hookDisplayName("PreToolUse:*:claude-hook")).toBe("claude-hook");
    expect(hookDisplayName("guard")).toBe("guard");
  });
});

describe("breadcrumbLabel for nested pages", () => {
  it("reads My Library / <name>, with hooks by display name", () => {
    expect(
      breadcrumbLabel({
        page: "package",
        packageName: packageDisplayName({ kind: "skill", name: "gh" }),
      }),
    ).toBe("My Library / gh");
    expect(packageDisplayName({ kind: "hook", name: "block-rm" })).not.toBe("");
  });

  it("spells the marketplace trail out one level per page", () => {
    expect(
      breadcrumbLabel({ page: "marketplaceDetail", marketplaceName: "kendex" }),
    ).toBe("Marketplaces / kendex");
    expect(
      breadcrumbLabel({
        page: "bundleDetail",
        marketplaceName: "kendex",
        bundleName: "starter",
      }),
    ).toBe("Marketplaces / kendex / starter");
    expect(
      breadcrumbLabel({
        page: "availablePackage",
        marketplaceName: "kendex",
        packageName: "gh",
      }),
    ).toBe("Marketplaces / kendex / gh");
  });
});

describe("describesItself", () => {
  it("separates what an author writes from what a config runs", () => {
    const rows = [
      { kind: "skill", expected: true },
      { kind: "agent", expected: true },
      { kind: "command", expected: true },
      { kind: "pi-extension", expected: true },
      { kind: "hook", expected: false },
      { kind: "mcp-server", expected: false },
    ] as const;
    expect(rows.length, "description source table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(describesItself(row.kind), row.kind).toBe(row.expected);
  });
});
