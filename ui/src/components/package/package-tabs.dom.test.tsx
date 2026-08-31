// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, ItemSafety, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { vendorHelp } from "@/lib/copy";
import { PROJECTS_TAB } from "@/lib/copy-projects";
import {
  SAFETY_NOT_READ,
  SAFETY_RETRY_LABEL,
  SAFETY_TAB,
  SAFETY_TAB_FAILED,
  SAFETY_TAB_STALE,
  SAFETY_VENDOR,
} from "@/lib/copy-safety";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { mount, settle } from "@/test/dom";
import { PackageTabs } from "./package-tabs";

vi.mock("@/bindings", () => ({
  commands: { auditAll: vi.fn(), scanMachine: vi.fn() },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const GLOBAL: Scope = { scope: "global" };

const deploy: ItemSafety = {
  kind: "command",
  name: "deploy",
  harness: "claude",
  scope: GLOBAL,
  location: "",
  findings: [
    {
      rule: "dangerous-commands",
      severity: "high",
      location: "deploy.md",
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

const OVERVIEW_MARKER = "what this package is";

const strip = ({ vendor = null }: { vendor?: string | null } = {}) =>
  mount(
    <PackageTabs
      kind="command"
      name="deploy"
      scope={GLOBAL}
      scopes={[GLOBAL]}
      harnesses={["claude"]}
      vendor={vendor}
      busy={false}
      onDelete={() => {}}
      body={<p>{OVERVIEW_MARKER}</p>}
    />,
  );

const tab = (host: HTMLElement, label: string) => {
  const found = [...host.querySelectorAll('[data-slot="tabs-trigger"]')].find(
    (trigger) => trigger.textContent?.startsWith(label),
  );
  if (!found) throw new Error(`no ${label} tab`);
  return found as HTMLElement;
};

beforeEach(() => {
  vi.clearAllMocks();
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
});

// The safety block used to open the Overview page, above the file the page
// is actually about. It is a tab of its own now, so Overview starts at what
// a person came to read and the score is one click away rather than in the
// way of it.
describe("a package's tab strip", () => {
  it("names the score after the words, and keeps it out of Overview", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([deploy])],
    });

    const host = strip();
    await settle();

    // The circle follows the text, so the tab reads as a score of
    // something rather than as a bare number.
    expect(tab(host, SAFETY_TAB).textContent).toBe(`${SAFETY_TAB}58`);

    const overview = [
      ...host.querySelectorAll('[data-slot="tabs-content"]'),
    ].find((panel) => panel.textContent?.includes(OVERVIEW_MARKER));
    if (!overview) throw new Error("no overview panel");
    expect(overview.textContent).not.toContain("58/100");

    await act(async () => {
      tab(host, SAFETY_TAB).click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain("deploy.md:20");
  });

  // Customize is the only tab a kind can lack. A kind without it still has
  // bytes the check reads, so the score keeps its place on the strip.
  it("carries the score for a kind with nothing to customize", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([deploy])],
    });

    const host = strip();
    await settle();

    const labels = [...host.querySelectorAll('[data-slot="tabs-trigger"]')].map(
      (trigger) => trigger.textContent,
    );
    expect(labels).toEqual(["Overview", PROJECTS_TAB, `${SAFETY_TAB}58`]);
  });
});

// A reading that outlived the check meant to replace it is the last thing
// anything knows, not what the files say now. The panel already heads it
// that way; the tab is what somebody standing on Overview or Projects sees,
// and a kept figure drawn as a current one there is a claim nothing on the
// machine supports.
describe("the tab's figure when the check could not run again", () => {
  const disc = (host: HTMLElement) => {
    const found = tab(host, SAFETY_TAB).querySelector("span[aria-hidden]");
    if (!found) throw new Error("no score disc on the tab");
    return found;
  };

  it("marks a kept reading and drops its severity tone", async () => {
    // Three hours is well past the freshness window, so the mount asks for
    // a new audit — and it is that ask which fails, leaving the earlier
    // reading on the tab.
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "audit crashed",
    });
    useAuditStore.setState({
      views: [view([deploy])],
      auditedAt: Date.now() - 3 * 60 * 60 * 1000,
      backgroundFailureAnnounced: true,
    });

    const host = strip();
    await settle();

    // The number stays, because it is the last reading there is.
    expect(tab(host, SAFETY_TAB).textContent).toBe(
      `${SAFETY_TAB}58${SAFETY_TAB_STALE}`,
    );
    // The words carry it, so the mark is never colour alone.
    expect(tab(host, SAFETY_TAB).querySelector(".sr-only")?.textContent).toBe(
      SAFETY_TAB_STALE,
    );
    // 58 with one high finding is the warning tone when it is current.
    expect(disc(host).className).toContain("text-muted-foreground");
    expect(disc(host).className).not.toContain("text-warning");
  });

  it("leaves a current reading unmarked, in the tone it earned", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([deploy])],
    });

    const host = strip();
    await settle();

    expect(tab(host, SAFETY_TAB).textContent).toBe(`${SAFETY_TAB}58`);
    expect(tab(host, SAFETY_TAB).querySelector(".sr-only")).toBeNull();
    expect(disc(host).className).toContain("text-warning");
  });
});

// Content a tool ships itself is skipped by observed_rows, so no audit will
// ever score it. Left to the unscored state it would sit on a permanent
// dash behind a Try again that asks for a check that is not coming.
describe("a package the harness ships itself", () => {
  const VENDOR = "OpenAI";

  const openSafety = async (vendor: string | null) => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([])],
    });
    const host = strip({ vendor });
    await settle();
    await act(async () => {
      tab(host, SAFETY_TAB).click();
    });
    await settle();
    return host;
  };

  const retryButton = (host: HTMLElement) =>
    [...host.querySelectorAll("button")].find(
      (button) => button.textContent === SAFETY_RETRY_LABEL,
    );

  it("says who ships it, and offers no check it cannot run", async () => {
    const host = await openSafety(VENDOR);

    // No disc: a dash reads as a figure still on its way.
    expect(tab(host, SAFETY_TAB).textContent).toBe(SAFETY_TAB);
    expect(host.textContent).toContain(SAFETY_VENDOR);
    expect(host.textContent).toContain(vendorHelp(VENDOR));
    expect(host.textContent).not.toContain(SAFETY_NOT_READ);
    expect(retryButton(host)).toBeUndefined();
  });

  // The contrast that makes the case above mean anything: a package kendex
  // does read, which the audit simply has no row for yet, still asks again.
  it("leaves a genuinely unscored package its retry", async () => {
    const host = await openSafety(null);

    expect(tab(host, SAFETY_TAB).textContent).toBe(`${SAFETY_TAB}—`);
    expect(host.textContent).toContain(SAFETY_NOT_READ);
    expect(host.textContent).not.toContain(SAFETY_VENDOR);
    expect(retryButton(host)).toBeDefined();
  });
});

// Overview is the tab a page opens on, so the label is the only thing most
// readers see. Before the check moved off Overview a failed audit said so
// there; the label has to carry that now, and a dash cannot, because a dash
// is also what a pending check and an unscored answer show.
describe("the tab's label when no reading arrived at all", () => {
  const label = async () => {
    const host = strip();
    await settle();
    return tab(host, SAFETY_TAB);
  };

  it("marks a first check that failed", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "audit crashed",
    });

    expect((await label()).textContent).toBe(
      `${SAFETY_TAB}—${SAFETY_TAB_FAILED}`,
    );
  });

  it("leaves a check still running unmarked", async () => {
    // Never resolves, so nothing has answered and nothing has failed.
    vi.mocked(commands.auditAll).mockReturnValue(new Promise(() => {}));

    expect((await label()).textContent).toBe(`${SAFETY_TAB}—`);
  });

  it("leaves an answer with no row for this package unmarked", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([])],
    });

    expect((await label()).textContent).toBe(`${SAFETY_TAB}—`);
  });
});
