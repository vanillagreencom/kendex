// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AuditView,
  Finding,
  ItemSafety,
  Scope,
  Severity,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { SAFETY_CAVEAT, SAFETY_CHECK_FAILED } from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { mount } from "@/test/dom";
import { InstalledScore, useInstalledReading } from "./installed-score";

vi.mock("@/bindings", () => ({ commands: { auditAll: vi.fn() } }));

const GLOBAL: Scope = { scope: "global" };
const ACME: Scope = { scope: "project", root: "/work/acme" };

const finding = (severity: Severity, location = "SKILL.md"): Finding => ({
  rule: "dangerous-commands",
  severity,
  location,
  line: 20,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

const scored = (
  score: number,
  findings: Finding[],
  over: Partial<ItemSafety> = {},
): ItemSafety => ({
  kind: "skill",
  name: "gh",
  harness: "claude",
  scope: GLOBAL,
  location: "",
  findings,
  skipped: [],
  safety: { score, deductions: [] },
  quality: null,
  ruleset: 3,
  ...over,
});

const view = (safety: ItemSafety[], scope: Scope = GLOBAL): AuditView => ({
  scope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety,
  adoptable: ADOPTABLE,
  exits: [],
});

const stage = (
  views: AuditView[],
  over: { auditedAt?: number | null; failure?: string | null } = {},
) =>
  act(() => {
    useAuditStore.setState({
      views,
      auditedAt: over.auditedAt === undefined ? 1 : over.auditedAt,
      read: over.failure == null ? READ_LANDED : readFailed(over.failure),
    });
  });

/** The component reads through the hook, the way every caller does. */
function Row({ scopes = [GLOBAL] }: { scopes?: Scope[] }) {
  return (
    <InstalledScore reading={useInstalledReading("skill", "gh", scopes)} />
  );
}

const words = () =>
  document.querySelector('[data-slot="tooltip-trigger"]')?.textContent ?? "";

beforeEach(() => {
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
});

describe("a package's installed score in a table row", () => {
  it("names the number as the copy on disk, not the one an update would earn", () => {
    stage([view([scored(62, [finding("high")])])]);
    mount(<Row />);

    expect(words()).toContain("installed now");
    expect(words()).toContain("62/100");
    expect(words()).toContain(SEVERITY_LABELS.high);
    expect(words()).toContain(SAFETY_CAVEAT);
  });

  it("says no check has answered rather than showing a score it does not have", () => {
    mount(<Row />);

    expect(words()).toContain("Not checked yet");
    expect(words()).not.toMatch(/\d+\/100/);
  });

  // The files can change under the app — an editor saves a skill, another
  // tool rewrites a hook — and the next audit is the only thing that knows.
  // A row still quoting the old number would be a claim about bytes nobody
  // has read since.
  it("follows the audit when the content changes outside the app", () => {
    stage([view([scored(100, [])])]);
    mount(<Row />);
    expect(words()).toContain("100/100");

    stage([view([scored(30, [finding("critical")])])], { auditedAt: 2 });

    expect(words()).toContain("30/100");
    expect(words()).toContain(SEVERITY_LABELS.critical);
    expect(words()).not.toContain("100/100");
  });
});

// A row on the Updates page is about the places that row lists. Another
// project's copy of a same-named package from an unrelated catalog is a
// different package, and scoring the row from it puts a number and a file
// path on screen that belong to something the row never mentions.
describe("which copies a row's score is of", () => {
  it("ignores a same-named package at a place the row is not about", () => {
    stage([
      view([scored(100, [])], GLOBAL),
      view([scored(30, [finding("critical")], { scope: ACME })], ACME),
    ]);
    mount(<Row scopes={[GLOBAL]} />);

    expect(words()).toContain("100/100");
    expect(words()).not.toContain("30/100");
  });

  it("reads every place the row does list", () => {
    stage([
      view([scored(100, [])], GLOBAL),
      view([scored(45, [finding("high")], { scope: ACME })], ACME),
    ]);
    mount(<Row scopes={[GLOBAL, ACME]} />);

    expect(words()).toContain("45/100");
  });

  // kendex renders one skill's bytes at every tool's place, so five tools
  // are five rows of one reading. Where two readings genuinely differ the
  // worse one is shown whole: a score from one reading over findings from
  // another is a number nothing on screen accounts for.
  it("shows one whole reading, never a score from one and findings from another", () => {
    stage([
      view([
        scored(100, [finding("low", "clean.md:1")], { harness: "claude" }),
        scored(45, [finding("high")], { harness: "codex" }),
        scored(45, [finding("high")], { harness: "pi" }),
      ]),
    ]);
    mount(<Row />);

    expect(words()).toContain("45/100");
    expect(words()).toContain(SEVERITY_LABELS.high);
    expect(words()).not.toContain("100/100");
  });
});

// A retained number presented as the current check is a claim nothing has
// made. The words carry the difference, because the disc cannot.
describe("when the check itself fails", () => {
  it("says a kept reading is the one before the failure, and how old it is", () => {
    const checkedAt = Date.now() - 3 * 60 * 60 * 1000;
    stage([view([scored(62, [finding("high")])])], {
      auditedAt: checkedAt,
      failure: "audit crashed",
    });
    mount(<Row />);

    expect(words()).toContain("couldn't run");
    // Without the age, a number from a minute ago and one from last week
    // read exactly alike.
    expect(words()).toContain("3h ago");
    expect(words()).toContain("62/100");
    expect(words()).not.toContain("installed now");
  });

  it("says the check failed rather than falling back to not checked yet", () => {
    stage([], { auditedAt: null, failure: "audit crashed" });
    mount(<Row />);

    expect(words()).toContain(SAFETY_CHECK_FAILED);
    expect(words()).not.toContain("Not checked yet");
  });
});
