import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, ScanResult } from "@/bindings";
import {
  AUDIT_ATTENTION_TITLE,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
  TRY_AGAIN_LABEL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
import { MARKETPLACES_UNCHECKED_DETAIL } from "@/lib/copy-marketplaces";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { OverviewPage } from "./overview";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so each store is wrapped to let a test stage what the last reads
// left behind. Both live in vi.hoisted: the mock factories run before any
// top-level statement of this file.
const { stub, wrap } = vi.hoisted(() => {
  const stub = {
    scan: {
      result: null as unknown,
      error: null as string | null,
      scanning: false,
    },
    updates: { read: { status: "landed", error: null } as ReadState },
    market: { read: { status: "landed", error: null } as ReadState },
    audit: {
      auditedAt: null as number | null,
      read: { status: "landed", error: null } as ReadState,
      error: null as string | null,
    },
  };
  const wrap = <M extends object>(
    mod: M,
    key: keyof M,
    over: () => Record<string, unknown>,
  ): M => {
    const store = mod[key] as { getState: () => object };
    const hook = (selector?: (state: unknown) => unknown) => {
      const state = { ...store.getState(), ...over() };
      return selector ? selector(state) : state;
    };
    return { ...mod, [key]: Object.assign(hook, store) };
  };
  return { stub, wrap };
});

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  return wrap(mod, "useScanStore", () => ({
    ...stub.scan,
    refresh: async () => {},
  }));
});
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  return wrap(mod, "useUpdatesStore", () => stub.updates);
});
vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  return wrap(mod, "useMarketplacesStore", () => ({
    ...stub.market,
    load: async () => {},
  }));
});
vi.mock("@/stores/audit", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/audit")>();
  return wrap(mod, "useAuditStore", () => ({
    ...stub.audit,
    refresh: async () => {},
  }));
});

const scanned: ScanResult = {
  harnesses: [],
  items: [],
  missingProjects: [],
  warnings: [],
};

const installed = (overrides: Partial<ObservedItem>): ObservedItem => ({
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
});

beforeEach(() => {
  stub.scan = { result: null, error: null, scanning: false };
  stub.updates = { read: READ_LANDED };
  stub.market = { read: READ_LANDED };
  stub.audit = { auditedAt: null, read: READ_LANDED, error: null };
});

// `result` starting null and staying null used to leave every section on
// its loading skeleton for the rest of the session: a read that came back
// unable to answer is not a read still on its way.
describe("Home when the first scan fails", () => {
  it("shows skeletons while the scan is genuinely still running", () => {
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain('data-slot="skeleton"');
    expect(html).not.toContain(esc(SCAN_FAILED_TITLE));
  });

  it("says the scan failed and offers the retry, with no skeletons", () => {
    stub.scan.error = "config unreadable";
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(esc(SCAN_FAILED_TITLE));
    expect(html).toContain("config unreadable");
    expect(html).toContain(SCAN_AGAIN_LABEL);
    expect(html).not.toContain('data-slot="skeleton"');
  });

  // An empty message is still a failure — testing it by truthiness would
  // read "" as no error and hold the skeletons for the session.
  it("treats a failure with an empty message as a failure, not a wait", () => {
    stub.scan.error = "";
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(esc(SCAN_FAILED_TITLE));
    expect(html).not.toContain('data-slot="skeleton"');
  });
});

// The store keeps the last good result so the page does not blank — right —
// but drawing it with nothing said presents counts and activity as current
// when kendex knows they are not.
describe("Home when a later scan fails", () => {
  it("still draws the last result and says the figures are last-known", () => {
    stub.scan = { result: scanned, error: "no disk", scanning: false };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(SCAN_STALE_TITLE);
    expect(html).toContain("no disk");
    expect(html).toContain(SCAN_AGAIN_LABEL);
    // The figures themselves are still on the page.
    expect(html).toContain("Harnesses");
  });

  it("carries no stale note while the result is current", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    expect(renderToStaticMarkup(<OverviewPage />)).not.toContain(
      SCAN_STALE_TITLE,
    );
  });

  it("marks retained figures stale on a failure with an empty message", () => {
    stub.scan = { result: scanned, error: "", scanning: false };
    expect(renderToStaticMarkup(<OverviewPage />)).toContain(SCAN_STALE_TITLE);
  });
});

// Home derives its attention list from the updates store's rows; a failed
// update check used to contribute silence, which reads as kendex having
// looked and found nothing.
describe("Home when the update check fails", () => {
  it("says updates couldn't be checked in the attention list", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now(), read: READ_LANDED, error: null };
    stub.updates = { read: readFailed("no network") };
    expect(renderToStaticMarkup(<OverviewPage />)).toContain(
      esc(UPDATES_ATTENTION_TITLE),
    );
  });

  it("claims nothing when the check answered", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now(), read: READ_LANDED, error: null };
    expect(renderToStaticMarkup(<OverviewPage />)).not.toContain(
      esc(UPDATES_ATTENTION_TITLE),
    );
  });
});

// auditedAt stays null forever after a failed startup audit; gating the
// skeleton on it alone held the section in "still looking" for the session
// and swallowed every other attention row.
describe("Home when the audit fails", () => {
  // The audit is the slowest read in the app and no longer holds this
  // section: every row bar the audit's own failure comes from the scan or
  // the update check, so waiting on it hid rows that were ready.
  it("shows the section as soon as the scan answers, audit or no audit", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.updates = { read: readFailed("no network") };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).not.toContain('data-slot="skeleton"');
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
    expect(html).not.toContain(esc(AUDIT_ATTENTION_TITLE));
  });

  it("holds the skeleton until the scan answers", () => {
    stub.scan = { result: null, error: null, scanning: true };
    expect(renderToStaticMarkup(<OverviewPage />)).toContain(
      'data-slot="skeleton"',
    );
  });

  it("drops the skeleton and says the audit failed, with the retry", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = {
      auditedAt: null,
      read: readFailed("audit crashed"),
      error: "audit crashed",
    };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(esc(AUDIT_ATTENTION_TITLE));
    expect(html).toContain(TRY_AGAIN_LABEL);
    expect(html).not.toContain('data-slot="skeleton"');
  });

  it("no longer suppresses the other failure rows", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = {
      auditedAt: null,
      read: readFailed("audit crashed"),
      error: "audit crashed",
    };
    stub.updates = { read: readFailed("no network") };
    expect(renderToStaticMarkup(<OverviewPage />)).toContain(
      esc(UPDATES_ATTENTION_TITLE),
    );
  });

  // The inverse control: a healthy Home must carry no audit row, or the
  // row's gate could be anything at all and the suite would not notice.
  it("claims nothing when the audit answered clean", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now(), read: READ_LANDED, error: null };
    expect(renderToStaticMarkup(<OverviewPage />)).not.toContain(
      esc(AUDIT_ATTENTION_TITLE),
    );
  });

  // Item actions write the store's shared `error`; only the read's own
  // error — written by refresh alone — may put the couldn't-check row on
  // Home.
  it("does not blame the audit for a failed item action", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = {
      auditedAt: Date.now(),
      read: READ_LANDED,
      error: "couldn't remove gh",
    };
    expect(renderToStaticMarkup(<OverviewPage />)).not.toContain(
      esc(AUDIT_ATTENTION_TITLE),
    );
  });
});

// The tile opens the Library, whose table shows one row per package however
// many harnesses carry it; counting installations here made the tile's
// number exceed the total on the page it lands on.
describe("the Installed tile", () => {
  it("counts packages the way the Library it opens does, not installations", () => {
    stub.scan = {
      result: {
        ...scanned,
        items: [
          installed({ harness: "claude" }),
          installed({ harness: "codex" }),
        ],
      },
      error: null,
      scanning: false,
    };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(">1<");
    expect(html).not.toContain(">2<");
  });
});

// `marketplaceCount` used to read `rows.length` with no regard for how the
// read went, presenting a failed read as a definite zero.
describe("the Marketplaces tile when its read is not current", () => {
  it("shows a dash and the failure note instead of a definite zero", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.market = { read: readFailed("the overview could not be read") };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(">—<");
    expect(html).toContain(esc(MARKETPLACES_UNCHECKED_DETAIL));
    expect(html).not.toContain("browse and subscribe");
  });

  it("shows the dash alone while the first read is still on its way", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.market = { read: READ_PENDING };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(">—<");
    expect(html).not.toContain(esc(MARKETPLACES_UNCHECKED_DETAIL));
  });

  it("counts a current read, zero included", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain("browse and subscribe");
    expect(html).not.toContain(esc(MARKETPLACES_UNCHECKED_DETAIL));
  });
});
