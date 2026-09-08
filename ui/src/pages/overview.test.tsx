// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, ScanResult, UnreadableScope } from "@/bindings";
import {
  AUDIT_ATTENTION_TITLE,
  SCAN_AGAIN_LABEL,
  SCAN_FAILED_TITLE,
  SCAN_STALE_TITLE,
  TRY_AGAIN_LABEL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
import { MARKETPLACES_UNCHECKED_DETAIL } from "@/lib/copy-marketplaces";
import { UPDATES_UNREADABLE_TITLE } from "@/lib/copy-updates";
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
    updates: {
      read: { status: "landed", error: null } as ReadState,
      unreadable: [] as UnreadableScope[],
    },
    market: { read: { status: "landed", error: null } as ReadState },
    audit: {
      auditedAt: null as number | null,
      read: { status: "landed", error: null } as ReadState,
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

/** Read the count from the named tile, so another tile cannot supply it. */
const tileValue = (html: string, label: string): string | null | undefined => {
  const page = document.createElement("div");
  page.innerHTML = html;
  return [...page.querySelectorAll("button")]
    .find((button) =>
      [...button.querySelectorAll("p")].some(
        (line) => line.textContent === label,
      ),
    )
    ?.querySelector("p")?.textContent;
};

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
  stub.updates = { read: READ_LANDED, unreadable: [] };
  stub.market = { read: READ_LANDED };
  stub.audit = { auditedAt: null, read: READ_LANDED };
});

// `result` starting null and staying null must not leave every section on
// its loading skeleton for the rest of the session: a read that came back
// unable to answer is not a read still on its way.
describe("Home when the first scan fails", () => {
  it("renders the initial scan outcome", () => {
    const rows = [
      {
        name: "shows skeletons while the scan is genuinely still running",
        error: null,
        present: ['data-slot="skeleton"'],
        absent: [esc(SCAN_FAILED_TITLE)],
      },
      {
        name: "says the scan failed and offers the retry, with no skeletons",
        error: "config unreadable",
        present: [
          esc(SCAN_FAILED_TITLE),
          "config unreadable",
          SCAN_AGAIN_LABEL,
        ],
        absent: ['data-slot="skeleton"'],
      },
      {
        name: "treats a failure with an empty message as a failure, not a wait",
        error: "",
        present: [esc(SCAN_FAILED_TITLE)],
        absent: ['data-slot="skeleton"'],
      },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      stub.scan.error = row.error;
      const html = renderToStaticMarkup(<OverviewPage />);
      expect(
        {
          present: row.present.filter((value) => html.includes(value)),
          absent: row.absent.filter((value) => html.includes(value)),
        },
        row.name,
      ).toEqual({ present: row.present, absent: [] });
    }
  });
});

// The store keeps the last good result so the page does not blank — right —
// but drawing it with nothing said presents counts and activity as current
// when kendex knows they are not.
describe("Home when a later scan fails", () => {
  it("marks retained scan results by the read outcome", () => {
    const rows = [
      {
        name: "still draws the last result and says the figures are last-known",
        error: "no disk",
        present: [SCAN_STALE_TITLE, "no disk", SCAN_AGAIN_LABEL, "Harnesses"],
        absent: [],
      },
      {
        name: "carries no stale note while the result is current",
        error: null,
        present: [],
        absent: [SCAN_STALE_TITLE],
      },
      {
        name: "marks retained figures stale on a failure with an empty message",
        error: "",
        present: [SCAN_STALE_TITLE],
        absent: [],
      },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      stub.scan = { result: scanned, error: row.error, scanning: false };
      const html = renderToStaticMarkup(<OverviewPage />);
      expect(
        {
          present: row.present.filter((value) => html.includes(value)),
          absent: row.absent.filter((value) => html.includes(value)),
        },
        row.name,
      ).toEqual({ present: row.present, absent: [] });
    }
  });
});

// Home derives its attention list from the updates store's rows; a failed
// update check contributing silence would read as kendex having looked
// and found nothing.
describe("Home when the update check fails", () => {
  it("renders update attention only for a failed check", () => {
    const rows = [
      {
        name: "says updates couldn't be checked in the attention list",
        read: readFailed("no network"),
        shown: true,
      },
      {
        name: "claims nothing when the check answered",
        read: READ_LANDED,
        shown: false,
      },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      stub.scan = { result: scanned, error: null, scanning: false };
      stub.audit = { auditedAt: Date.now(), read: READ_LANDED };
      stub.updates = { read: row.read, unreadable: [] };
      expect(
        renderToStaticMarkup(<OverviewPage />).includes(
          esc(UPDATES_ATTENTION_TITLE),
        ),
        row.name,
      ).toBe(row.shown);
    }
  });
});

// A place whose lock this build refuses contributes no rows at all, so the
// counts on this page answer for less than the machine. The page has to feed
// the store's list to the derivation for the row to exist: a `unreadable: []`
// in the page's source would drop the place with nothing else reddening.
describe("Home when a place cannot be read at all", () => {
  it("names the place with no update standing in the attention list", () => {
    stub.scan = { result: scanned, error: null, scanning: false };
    stub.audit = { auditedAt: Date.now(), read: READ_LANDED };
    stub.updates = {
      read: READ_LANDED,
      unreadable: [
        {
          scope: { scope: "project", root: "/home/dev/hyprtrade" },
          message: "written by a newer kendex",
        },
      ],
    };
    const html = renderToStaticMarkup(<OverviewPage />);
    expect(html).toContain(esc(UPDATES_UNREADABLE_TITLE));
    expect(html).toContain("hyprtrade");
  });
});

// auditedAt stays null forever after a failed startup audit; gating the
// skeleton on it alone would hold the section in "still looking" for the
// session and swallow every other attention row.
describe("Home when the audit fails", () => {
  it("keeps scan readiness and audit attention separate", () => {
    const rows = [
      {
        name: "shows the section as soon as the scan answers, audit or no audit",
        result: scanned,
        audit: { auditedAt: null, read: READ_LANDED },
        updates: readFailed("no network"),
        present: [esc(UPDATES_ATTENTION_TITLE)],
        absent: ['data-slot="skeleton"', esc(AUDIT_ATTENTION_TITLE)],
      },
      {
        name: "holds the skeleton until the scan answers",
        result: null,
        audit: { auditedAt: null, read: READ_LANDED },
        updates: READ_LANDED,
        present: ['data-slot="skeleton"'],
        absent: [],
      },
      {
        name: "drops the skeleton and says the audit failed, with the retry",
        result: scanned,
        audit: { auditedAt: null, read: readFailed("audit crashed") },
        updates: READ_LANDED,
        present: [esc(AUDIT_ATTENTION_TITLE), TRY_AGAIN_LABEL],
        absent: ['data-slot="skeleton"'],
      },
      {
        name: "no longer suppresses the other failure rows",
        result: scanned,
        audit: { auditedAt: null, read: readFailed("audit crashed") },
        updates: readFailed("no network"),
        present: [esc(UPDATES_ATTENTION_TITLE)],
        absent: [],
      },
      {
        name: "claims nothing when the audit answered clean",
        result: scanned,
        audit: { auditedAt: Date.now(), read: READ_LANDED },
        updates: READ_LANDED,
        present: [],
        absent: [esc(AUDIT_ATTENTION_TITLE)],
      },
    ];
    expect(rows).toHaveLength(5);
    for (const row of rows) {
      stub.scan = {
        result: row.result,
        error: null,
        scanning: row.result === null,
      };
      stub.audit = row.audit;
      stub.updates = { read: row.updates, unreadable: [] };
      const html = renderToStaticMarkup(<OverviewPage />);
      expect(
        {
          present: row.present.filter((value) => html.includes(value)),
          absent: row.absent.filter((value) => html.includes(value)),
        },
        row.name,
      ).toEqual({ present: row.present, absent: [] });
    }
  });
});

// The tile opens the Library, whose table shows one row per package however
// many harnesses carry it; counting installations here would make the
// tile's number exceed the total on the page it lands on.
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
    expect(tileValue(html, "Installed")).toBe("1");
  });
});

// `marketplaceCount` reading `rows.length` with no regard for how the read
// went would present a failed read as a definite zero.
describe("the Marketplaces tile when its read is not current", () => {
  it("renders the count and detail for the marketplace read state", () => {
    const rows = [
      {
        name: "shows a dash and the failure note instead of a definite zero",
        read: readFailed("the overview could not be read"),
        value: "—",
        present: [esc(MARKETPLACES_UNCHECKED_DETAIL)],
        absent: ["browse and subscribe"],
      },
      {
        name: "shows the dash alone while the first read is still on its way",
        read: READ_PENDING,
        value: "—",
        present: [],
        absent: [esc(MARKETPLACES_UNCHECKED_DETAIL)],
      },
      {
        name: "counts a current read, zero included",
        read: READ_LANDED,
        value: "0",
        present: ["browse and subscribe"],
        absent: [esc(MARKETPLACES_UNCHECKED_DETAIL)],
      },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      stub.scan = { result: scanned, error: null, scanning: false };
      stub.market = { read: row.read };
      const html = renderToStaticMarkup(<OverviewPage />);
      expect(
        {
          value: tileValue(html, "Marketplaces"),
          present: row.present.filter((value) => html.includes(value)),
          absent: row.absent.filter((value) => html.includes(value)),
        },
        row.name,
      ).toEqual({ value: row.value, present: row.present, absent: [] });
    }
  });
});
