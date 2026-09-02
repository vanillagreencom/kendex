// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, ItemSafety, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { vendorHelp } from "@/lib/copy";
import {
  SAFETY_CHECK_FAILED,
  SAFETY_NOT_READ,
  SAFETY_NOT_READ_BODY,
  SAFETY_RETRY_LABEL,
  SAFETY_TAB_FAILED,
  SAFETY_TAB_STALE,
  SAFETY_VENDOR,
  staleSafetyNote,
} from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "@/stores/audit";
import type { PackageRef } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";
import {
  PackageSafety,
  SafetyScoreLabel,
  usePackageSafety,
} from "./package-safety";

vi.mock("@/bindings", () => ({
  commands: { auditAll: vi.fn(), scanMachine: vi.fn() },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const GLOBAL: Scope = { scope: "global" };

/** The tab exactly as the page wires it: one reading behind the label and
 *  the panel, so a test can never see the two disagree. */
function SafetyTab({
  reference,
  vendor = null,
}: {
  reference: PackageRef;
  vendor?: string | null;
}) {
  const reading = usePackageSafety(
    reference.kind,
    reference.name,
    reference.scope,
  );
  return (
    <>
      <SafetyScoreLabel reading={reading} vendor={vendor} />
      <PackageSafety reading={reading} vendor={vendor} />
    </>
  );
}

const gh: ItemSafety = {
  kind: "skill",
  name: "gh",
  targets: [{ harness: "claude", location: "" }],
  scope: GLOBAL,
  findings: [
    {
      rule: "dangerous-commands",
      severity: "high",
      location: "SKILL.md",
      line: 20,
      message: "runs a shell command that deletes files without asking",
      remediation: "scope the command to a specific path, or drop it",
    },
  ],
  skipped: [],
  safety: { score: 58, deductions: [] },
  quality: null,
  ruleset: 3,
};

const view = (safety: ItemSafety[]): AuditView => ({
  scope: GLOBAL,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety,
  adoptable: ADOPTABLE,
  exits: [],
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      items: [],
      harnesses: [],
      warnings: [],
      missingProjects: [],
    } as never,
  });
  useScanStore.setState({ scanning: false, result: null, error: null });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
});

// An install writes the very bytes a score answers for. The audit that ran
// a moment earlier knows nothing about the new package, so a page opened on
// it has no row — and a block that renders nothing there reads as a package
// the check found nothing in, which is the one claim it has not made.
describe("a package installed just now", () => {
  it("shows its score, with the audit's freshness window already open", async () => {
    // The state right after any earlier visit: a clean audit, well inside
    // the window that would otherwise answer for this one.
    act(() => {
      useAuditStore.setState({ views: [view([])], auditedAt: Date.now() });
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([gh])],
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();
    expect(host.textContent).not.toContain("58/100");

    // What marketplaces.install ends with.
    await act(async () => {
      await rescanEverything();
    });

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain(SEVERITY_LABELS.high);
    expect(host.textContent).toContain("SKILL.md:20");
  });
});

// A failed check is an outcome, not a wait. Rendering nothing for it leaves
// the page silent about a package it has never read, and the toast that
// announced the failure is gone by the time anybody looks.
describe("when the check could not run", () => {
  it("says so, with the way to ask again, instead of rendering nothing", async () => {
    act(() => {
      useAuditStore.setState({
        auditedAt: null,
        read: readFailed("audit crashed"),
        backgroundFailureAnnounced: true,
      });
    });
    // The mount asks for a fresh audit, and it fails the same way. Only the
    // person pressing the button gets a different answer.
    vi.mocked(commands.auditAll)
      .mockResolvedValueOnce({ status: "error", error: "audit crashed" })
      .mockResolvedValue({ status: "ok", data: [view([gh])] });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.textContent).toContain(SAFETY_CHECK_FAILED);
    expect(host.textContent).toContain("audit crashed");

    const retry = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === SAFETY_RETRY_LABEL,
    );
    if (!retry) throw new Error("expected a retry button");
    await act(async () => {
      retry.click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
  });

  // Without the age a reader cannot tell a number from a minute ago from one
  // from last week, and both were only ever "before it".
  it("dates the kept reading rather than only calling it an earlier one", async () => {
    const checkedAt = Date.now() - 3 * 60 * 60 * 1000;
    // Three hours is well past the freshness window, so the mount asks for a
    // new audit — and it is that ask which fails, leaving the old reading on
    // screen. Exactly the state the words have to be honest about.
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "audit crashed",
    });
    act(() => {
      useAuditStore.setState({
        views: [view([gh])],
        auditedAt: checkedAt,
        backgroundFailureAnnounced: true,
      });
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain("3h ago");
    expect(host.textContent).toContain(staleSafetyNote(checkedAt));
    expect(host.textContent).toContain(SAFETY_RETRY_LABEL);
  });
});

// The audit answered for the machine, but not for this place: a corrupt
// lock, a manifest from a newer kendex. Core answers for such a scope with
// the error and nothing else — `AuditView::failed` sends an empty `safety`
// — so there is no score to show, and a blank panel would read as a place
// the check found nothing wrong in.
describe("when only this package's place could not be read", () => {
  it("says the check failed there and offers the retry", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [
        {
          ...view([]),
          error: { kind: "lock-corrupt", message: "lock is not JSON" },
        },
      ],
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.textContent).toContain(SAFETY_CHECK_FAILED);
    expect(host.textContent).toContain("lock is not JSON");
    expect(host.textContent).toContain(SAFETY_RETRY_LABEL);
    // Not "nothing found here", which is the one claim the audit did not
    // make about this place.
    expect(host.textContent).not.toContain(SAFETY_NOT_READ);
  });

  it("says nothing about staleness for a place that answered", async () => {
    act(() => {
      useAuditStore.setState({
        views: [view([gh])],
        auditedAt: Date.now(),
        read: READ_LANDED,
      });
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).not.toContain("couldn't run");
  });
});

// The audit came back and had no row for this package. Nothing found and
// nothing read are different claims, and a blank tab would make the first
// one on the strength of the second.
describe("when the audit answered with no reading for this package", () => {
  it("says it has not been scored, and the retry gets a reading", async () => {
    vi.mocked(commands.auditAll)
      .mockResolvedValueOnce({ status: "ok", data: [view([])] })
      .mockResolvedValue({ status: "ok", data: [view([gh])] });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.textContent).toContain(SAFETY_NOT_READ);
    expect(host.textContent).toContain(SAFETY_NOT_READ_BODY);
    expect(host.textContent).not.toContain(SAFETY_CHECK_FAILED);
    // The label has nothing to show either, and a dash is not a score.
    expect(host.textContent).toContain("—");

    const retry = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === SAFETY_RETRY_LABEL,
    );
    if (!retry) throw new Error("expected a retry button");
    await act(async () => {
      retry.click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
  });
});

// A reading that outlived the check meant to replace it is the last thing
// anything knows, not what the files say now. The panel heads it that way;
// the label is what somebody standing on another tab sees, and a kept
// figure drawn as a current one there is a claim nothing supports.
describe("the label when the check could not run again", () => {
  it("marks a kept reading, in words and not colour alone", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "audit crashed",
    });
    act(() => {
      useAuditStore.setState({
        views: [view([gh])],
        auditedAt: Date.now() - 3 * 60 * 60 * 1000,
        backgroundFailureAnnounced: true,
      });
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.querySelector(".sr-only")?.textContent).toBe(SAFETY_TAB_STALE);
  });

  // A dash is also what a pending check and an unscored answer show, so a
  // first check that failed has to say so rather than show one.
  it("marks a first check that failed", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "audit crashed",
    });
    act(() => {
      useAuditStore.setState({ backgroundFailureAnnounced: true });
    });

    const host = mount(
      <SafetyTab reference={{ kind: "skill", name: "gh", scope: GLOBAL }} />,
    );
    await settle();

    expect(host.querySelector(".sr-only")?.textContent).toBe(SAFETY_TAB_FAILED);
  });
});

// Content a tool ships itself is skipped by observed_rows, so no audit will
// ever score it. Left to the unscored state it would sit on a permanent
// dash behind a Try again that asks for a check that is not coming.
describe("a package the harness ships itself", () => {
  it("says who ships it, and offers no check it cannot run", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([])],
    });

    const host = mount(
      <SafetyTab
        reference={{ kind: "skill", name: "gh", scope: GLOBAL }}
        vendor="OpenAI"
      />,
    );
    await settle();

    // No disc: a dash reads as a figure still on its way.
    expect(host.textContent).not.toContain("—");
    expect(host.textContent).toContain(SAFETY_VENDOR);
    expect(host.textContent).toContain(vendorHelp("OpenAI"));
    expect(host.textContent).not.toContain(SAFETY_NOT_READ);
    expect(
      [...host.querySelectorAll("button")].find(
        (button) => button.textContent === SAFETY_RETRY_LABEL,
      ),
    ).toBeUndefined();
  });
});
