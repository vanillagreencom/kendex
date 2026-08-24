import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ScanResult } from "@/bindings";
import {
  MARKETPLACES_UNCHECKED_DETAIL,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
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
    updates: { error: null as string | null },
    market: { rowsCurrent: true, error: null as string | null },
    audit: { auditedAt: null as number | null },
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
  return wrap(mod, "useAuditStore", () => stub.audit);
});

const scanned: ScanResult = {
  harnesses: [],
  items: [],
  missingProjects: [],
  warnings: [],
};

beforeEach(() => {
  stub.scan = { result: null, error: null, scanning: false };
  stub.updates = { error: null };
  stub.market = { rowsCurrent: true, error: null };
  stub.audit = { auditedAt: null };
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
});

// Home derives its attention list from the updates store's rows; a failed
// update check used to contribute silence, which reads as kendex having
// looked and found nothing.
describe("Home when the update check fails", () => {
  it("says updates couldn't be checked in the attention list", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now() };
    stub.updates = { error: "no network" };
    expect(renderToStaticMarkup(<OverviewPage />)).toContain(
      esc(UPDATES_ATTENTION_TITLE),
    );
  });

  it("claims nothing when the check answered", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now() };
    expect(renderToStaticMarkup(<OverviewPage />)).not.toContain(
      esc(UPDATES_ATTENTION_TITLE),
    );
  });
});

// `marketplaceCount` used to read `rows.length` with no regard for how the
// read went, presenting a failed read as a definite zero.
describe("the Marketplaces tile when its read is not current", () => {
  it("shows a dash and the failure note instead of a definite zero", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.market = { rowsCurrent: false, error: "offline" };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(">—<");
    expect(html).toContain(esc(MARKETPLACES_UNCHECKED_DETAIL));
    expect(html).not.toContain("browse and subscribe");
  });

  it("counts a current read, zero included", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain("browse and subscribe");
    expect(html).not.toContain(esc(MARKETPLACES_UNCHECKED_DETAIL));
  });
});
