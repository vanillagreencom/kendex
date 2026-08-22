import { describe, expect, it } from "vitest";
import type { RecordedDecision } from "@/bindings";
import {
  decisionDetail,
  decisionHome,
  describeDecision,
  revokeLabel,
  sortDecisions,
} from "./decisions";

const NOW = Date.parse("2026-08-16T12:00:00Z");

function accepted(overrides: Partial<RecordedDecision> = {}): RecordedDecision {
  return {
    scope: { scope: "project", root: "/home/dana/acme" },
    key: "skill:scraper:claude",
    kind: "skill",
    name: "scraper",
    harness: "claude",
    record: {
      kind: "accepted",
      findings: 3,
      grantedAt: "2026-08-14T12:00:00Z",
    },
    state: { state: "active" },
    ...overrides,
  };
}

function dismissed(
  overrides: Partial<RecordedDecision> = {},
): RecordedDecision {
  return {
    scope: { scope: "global" },
    key: "hook:PreToolUse:Bash:guard:claude",
    kind: "hook",
    name: "PreToolUse:Bash:guard",
    harness: "claude",
    record: {
      kind: "dismissed",
      fingerprint: "3fa9c2d1e0b4a7c8",
      reason: "wrong-call",
      dismissedAt: "2026-08-15T12:00:00Z",
      finding: null,
    },
    state: { state: "active" },
    ...overrides,
  };
}

describe("describeDecision", () => {
  it("says what was decided, when, and whose file it lives in", () => {
    expect(describeDecision(accepted(), NOW)).toBe(
      "Accepted 3 findings · 2d ago · in acme's kendex.toml, shared",
    );
    expect(describeDecision(dismissed(), NOW)).toBe(
      "Ignored — not actually a problem · 1d ago · yours, on this machine",
    );
  });

  it("names the shared file so an inherited decision is never invisible", () => {
    expect(decisionHome({ scope: "global" })).toBe("yours, on this machine");
    expect(decisionHome({ scope: "project", root: "/x/acme" })).toContain(
      "shared",
    );
  });

  it("tells two projects sharing a folder name apart", () => {
    // The list spans every project, and a decision is about one of their
    // files — "api's kendex.toml" twice over names neither.
    const work = { scope: "project", root: "/work/api" } as const;
    const client = { scope: "project", root: "/clients/api" } as const;
    expect(decisionHome(work, [work, client])).toContain("work/api's");
    expect(decisionHome(client, [work, client])).toContain("clients/api's");
  });
});

describe("sortDecisions", () => {
  it("puts live decisions before stale ones and obsolete ones last", () => {
    const rows = [
      dismissed({ key: "c", state: { state: "obsolete" } }),
      dismissed({
        key: "b",
        state: { state: "stale", why: "the content changed" },
      }),
      accepted({ key: "a" }),
    ];
    expect(sortDecisions(rows).map((r) => r.key)).toEqual(["a", "b", "c"]);
  });
});

describe("revokeLabel", () => {
  it("withdraws an acceptance, takes back a dismissal, forgets a dead record", () => {
    expect(revokeLabel(accepted())).toBe("Withdraw");
    expect(revokeLabel(dismissed())).toBe("Take back");
    expect(revokeLabel(dismissed({ state: { state: "obsolete" } }))).toBe(
      "Forget",
    );
    expect(revokeLabel(accepted({ state: { state: "stale", why: "x" } }))).toBe(
      "Forget",
    );
  });

  it("quotes the finding a dismissal was about, and nothing once it is gone", () => {
    const finding = {
      rule: "r",
      severity: "medium" as const,
      location: "SKILL.md:1",
      message: "makes files writable by every account",
      remediation: "narrow it",
    };
    const live = dismissed();
    if (live.record.kind === "dismissed") live.record.finding = finding;
    expect(decisionDetail(live)).toBe("makes files writable by every account");
    expect(decisionDetail(dismissed())).toBeNull();
    expect(decisionDetail(accepted())).toBeNull();
  });
});
