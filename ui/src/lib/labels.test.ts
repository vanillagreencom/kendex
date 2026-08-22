import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { findingHeadline } from "@/lib/finding-headlines";
import {
  breadcrumbLabel,
  describesItself,
  driftDetail,
  HARNESS_NAMES,
  harnessName,
  hookDisplayName,
  kindLabel,
  packageDisplayName,
  SEVERITY_BADGES,
  STATE_BADGES,
  STATE_LABELS,
  scopeName,
  scopePath,
  skipReasonShort,
  VERDICT_BADGES,
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

  it("tells two projects sharing a folder name apart", () => {
    const work = { scope: "project", root: "/work/api" } as const;
    const client = { scope: "project", root: "/clients/api" } as const;
    expect(scopeName(work)).toBe("api");
    expect(scopeName(work, [work, client])).toBe("work/api");
    expect(scopeName(client, [work, client])).toBe("clients/api");
  });

  it("keeps human copy free of internal jargon", () => {
    const copy = [
      ...Object.values(STATE_LABELS),
      ...Object.values(HARNESS_NAMES),
    ]
      .join(" ")
      .toLowerCase();
    for (const banned of ["drift", "unmanaged", "orphan", "harness", "scope"]) {
      expect(copy).not.toContain(banned);
    }
    expect(harnessName("claude")).toBe("Claude Code");
  });

  it("maps drift states to the badge tone that matches their urgency", () => {
    expect(STATE_BADGES.conflict).toBe("warning");
    expect(STATE_BADGES.stale).toBe("info");
    expect(STATE_BADGES.missing).toBe("info");
    expect(STATE_BADGES.orphaned).toBe("outline");
    expect(STATE_BADGES.unmanaged).toBe("secondary");
  });

  it("maps severity to the badge tone that matches how serious it is", () => {
    expect(SEVERITY_BADGES.critical).toBe("critical");
    expect(SEVERITY_BADGES.high).toBe("warning");
    expect(SEVERITY_BADGES.medium).toBe("info");
    expect(SEVERITY_BADGES.low).toBe("secondary");
  });

  it("maps a safety verdict to the badge tone that matches its outcome", () => {
    expect(VERDICT_BADGES.block).toBe("critical");
    expect(VERDICT_BADGES.warn).toBe("warning");
    expect(VERDICT_BADGES.clean).toBe("good");
  });

  it("shows a hook's trailing name and falls back to the whole id", () => {
    expect(hookDisplayName("Notification:permission_prompt:tmux-bell")).toBe(
      "tmux-bell",
    );
    expect(hookDisplayName("PreToolUse:*:claude-hook")).toBe("claude-hook");
    expect(hookDisplayName("guard")).toBe("guard");
  });

  it("drops drift detail that only restates the state pill", () => {
    const row = (over: Partial<DriftRow>): DriftRow => ({
      kind: "skill",
      name: "x",
      harness: "claude",
      scope: { scope: "global" },
      state: "stale",
      subject: "package",
      detail: "",
      ...over,
    });
    expect(
      driftDetail(
        row({ state: "stale", detail: "newer content is available" }),
      ),
    ).toBeNull();
    expect(
      driftDetail(row({ state: "missing", detail: "not installed yet" })),
    ).toBeNull();
    expect(driftDetail(row({ detail: "" }))).toBeNull();
    expect(
      driftDetail(
        row({ state: "conflict", detail: "both a symlink and a real file" }),
      ),
    ).toBe("both a symlink and a real file");
  });

  it("maps a known rule to its plain-English headline and falls back to the message", () => {
    expect(findingHeadline("dangerous-commands", "the engine's message")).toBe(
      "Contains a command that could do real damage",
    );
    expect(findingHeadline("some-future-rule", "the engine's message")).toBe(
      "The engine's message",
    );
  });

  it("shortens a known skip reason and falls back for unknown ones", () => {
    expect(
      skipReasonShort(
        "the plugin's own files are not readable here — a declared plugin is one switch in a settings file until it is installed",
      ),
    ).toBe("not installed yet");
    expect(skipReasonShort("some new engine sentence")).toBe(
      "nothing here could be read",
    );
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
