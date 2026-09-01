import { describe, expect, it } from "vitest";
import {
  breadcrumbLabel,
  describesItself,
  HARNESS_NAMES,
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

  it("keeps human copy free of internal jargon", () => {
    const copy = Object.values(HARNESS_NAMES).join(" ").toLowerCase();
    for (const banned of ["drift", "unmanaged", "orphan", "harness", "scope"]) {
      expect(copy).not.toContain(banned);
    }
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
    for (const kind of ["skill", "agent", "command", "pi-extension"] as const) {
      expect(describesItself(kind)).toBe(true);
    }
    // Nowhere to write a description, so the command stands in for one.
    expect(describesItself("hook")).toBe(false);
    expect(describesItself("mcp-server")).toBe(false);
  });
});
