// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import {
  BROWSE_MARKETPLACES_LABEL,
  CHECK_FOR_UPDATES_LABEL,
  UPDATE_ALL_LABEL,
  UPDATES_ATTENTION_TITLE,
  UPDATES_EMPTY,
  UPDATES_NOTHING_INSTALLED,
} from "@/lib/copy";
import {
  NEVER_CHECKED,
  UPDATE_MENU_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_CHECKING,
  UPDATES_UNCONFIRMED_TITLE,
} from "@/lib/copy-updates";
import { observedSkill, scanFound } from "@/test/observed";
import { UpdatesPage } from "./updates";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

/** Read the named control from the rendered page. */
const renderedButton = (html: string, label: string) => {
  const page = document.createElement("div");
  page.innerHTML = html;
  return [...page.querySelectorAll("button")].find(
    (button) => button.textContent?.trim() === label,
  );
};

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  read: { status: "landed", error: null } as {
    status: "pending" | "landed" | "failed";
    error: string | null;
  },
  lastFetched: null as number | null,
  busy: false,
  unreadable: [] as unknown[],
  /** What the machine scan found, where the page reads what is installed. */
  scan: null as unknown,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows as UpdateRow[],
      warnings: [],
      busy: stub.busy,
      checking: false,
      read: stub.read,
      lastFetched: stub.lastFetched,
      unreadable: stub.unreadable,
      reload: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useScanStore.getState(), result: stub.scan };
    return selector ? selector(state) : state;
  };
  return { ...mod, useScanStore: Object.assign(hook, mod.useScanStore) };
});

// A join that recognises nothing; which scans may be counted from at all is
// pinned in `lib/updates-read-state.test.ts`.
vi.mock("@/lib/package-identity", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/lib/package-identity")>();
  return { ...mod, usePackageIndex: () => () => null };
});

beforeEach(() => {
  stub.rows = [];
  stub.read = { status: "landed", error: null };
  stub.lastFetched = null;
  stub.busy = false;
  stub.unreadable = [];
  // The ordinary machine: a scan that found something.
  stub.scan = scanFound([observedSkill("deploy")]);
});

/** The row core emits for something installed and current. */
const currentRow = (name: string) =>
  updateRow(name, null, { updateAvailable: false, latest: null });

/** Unix seconds `ago` seconds before now — the shape the overview reports,
 *  read against the same clock the page renders against. */
const secondsAgo = (ago: number) => Math.floor(Date.now() / 1000) - ago;

// Empty rows and no error read as good news, so before the first read
// answers — and after one that failed — "Everything is up to date" would
// assert the very thing kendex just said it could not verify.
describe("the Updates page across its read states", () => {
  it("renders the controls and notices for the current reading", () => {
    const failed = { status: "failed", error: "no network" } as const;
    const landed = { status: "landed", error: null } as const;
    const rows = [
      {
        name: "says it is checking before the first read answers",
        read: { status: "pending", error: null },
        updates: [],
        busy: false,
        present: [UPDATES_CHECKING],
        absent: [UPDATES_EMPTY],
        disabled: [],
      },
      {
        name: "says the check failed and offers the retry, not up-to-dateness",
        read: failed,
        updates: [],
        busy: false,
        present: [
          esc(UPDATES_ATTENTION_TITLE),
          "no network",
          "Check for updates",
        ],
        absent: [UPDATES_EMPTY],
        disabled: [],
      },
      {
        name: "heads rows kept from a better read with the stale note",
        read: failed,
        updates: [updateRow("gh", null)],
        busy: false,
        present: [UPDATES_UNCONFIRMED_TITLE, "no network", "gh"],
        absent: [],
        disabled: [],
      },
      {
        name: "carries no stale note over rows from a current read",
        read: landed,
        updates: [updateRow("gh", null)],
        busy: false,
        present: [],
        absent: [UPDATES_UNCONFIRMED_TITLE],
        disabled: [],
      },
      {
        name: "keeps the retry reachable when only hidden rows remain",
        read: failed,
        updates: [updateRow("gh", null, { ignored: true })],
        busy: false,
        present: [UPDATES_UNCONFIRMED_TITLE, CHECK_FOR_UPDATES_LABEL],
        absent: [],
        disabled: [],
      },
      {
        name: "holds Check while a write is out",
        read: landed,
        updates: [updateRow("gh", null)],
        busy: true,
        present: [],
        absent: [],
        disabled: [CHECK_FOR_UPDATES_LABEL],
      },
      {
        name: "holds the empty state's retry while a write is out",
        read: landed,
        updates: [currentRow("gh")],
        busy: true,
        present: [],
        absent: [],
        disabled: [CHECK_FOR_UPDATES_LABEL],
      },
      {
        name: "offers no header check button on a clean page with nothing visible",
        read: landed,
        updates: [updateRow("gh", null, { ignored: true })],
        busy: false,
        present: [],
        absent: [CHECK_FOR_UPDATES_LABEL],
        disabled: [],
      },
      {
        name: "holds Update all over rows a failed check left behind",
        read: failed,
        updates: [updateRow("one", null), updateRow("two", null)],
        busy: false,
        present: [`title="${UPDATE_NEEDS_CHECK_NOTE}"`],
        absent: [],
        disabled: [UPDATE_ALL_LABEL],
      },
    ] satisfies {
      name: string;
      read: typeof stub.read;
      updates: UpdateRow[];
      busy: boolean;
      present: string[];
      absent: string[];
      disabled: string[];
    }[];
    expect(rows).toHaveLength(9);
    for (const row of rows) {
      stub.read = row.read;
      stub.rows = row.updates;
      stub.busy = row.busy;
      const html = renderToStaticMarkup(<UpdatesPage />);
      expect(
        {
          present: row.present.filter((value) => html.includes(value)),
          absent: row.absent.filter((value) => html.includes(value)),
          disabled: row.disabled.map((label) => ({
            label,
            disabled: renderedButton(html, label)?.disabled,
          })),
        },
        row.name,
      ).toEqual({
        present: row.present,
        absent: [],
        disabled: row.disabled.map((label) => ({ label, disabled: true })),
      });
    }
  });
});

// An empty list carries three different meanings, and only one of them is
// good news. The update read covers declared remote packages alone, so a
// machine of adopted, local or unmanaged content produces no rows at all
// while the Library counts its packages: the scan says whether the machine
// is empty, and the update rows never do. Which scans may be counted from
// is `scannedInstalled`'s, pinned in `lib/updates-read-state.test.ts`; the
// rows here are what each verdict puts on screen.
describe("what an empty Updates page says about this machine", () => {
  it("reads the machine from the scan and up-to-dateness from the check", () => {
    const rows = [
      {
        name: "says nothing is installed, and offers a marketplace rather than a check",
        updates: [],
        scan: scanFound([]),
        age: null,
        present: [UPDATES_NOTHING_INSTALLED, BROWSE_MARKETPLACES_LABEL],
        absent: [UPDATES_EMPTY, NEVER_CHECKED, CHECK_FOR_UPDATES_LABEL],
      },
      {
        name: "keeps the check on a machine the scan sees and the update read lists nothing for",
        updates: [],
        scan: scanFound([observedSkill("adopted")]),
        age: null,
        present: [NEVER_CHECKED, CHECK_FOR_UPDATES_LABEL],
        absent: [
          UPDATES_NOTHING_INSTALLED,
          BROWSE_MARKETPLACES_LABEL,
          UPDATES_EMPTY,
        ],
      },
      {
        name: "says no check has run where something is installed and no fetch reached a source",
        updates: [currentRow("gh")],
        scan: scanFound([observedSkill("deploy")]),
        age: null,
        present: [NEVER_CHECKED, CHECK_FOR_UPDATES_LABEL],
        absent: [UPDATES_EMPTY, UPDATES_NOTHING_INSTALLED],
      },
      {
        name: "calls the machine up to date once a check has reached a source",
        updates: [currentRow("gh")],
        scan: scanFound([observedSkill("deploy")]),
        age: 5 * 86_400,
        present: [UPDATES_EMPTY, CHECK_FOR_UPDATES_LABEL],
        absent: [NEVER_CHECKED, UPDATES_NOTHING_INSTALLED],
      },
    ];
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      stub.rows = row.updates;
      stub.scan = row.scan;
      stub.lastFetched = row.age === null ? null : secondsAgo(row.age);
      const html = renderToStaticMarkup(<UpdatesPage />);
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

// Both the list and the empty state disclose when their answer was checked.
describe("how fresh the page says its answer is", () => {
  it("dates only answers a check produced", () => {
    const rows = [
      {
        name: "dates the list from the last fetch behind it",
        updates: [updateRow("gh", null)],
        age: 3 * 3600,
        present: ["Last checked 3h ago"],
        absent: [],
      },
      {
        name: "dates the up-to-date state, which is the one that hides its age",
        updates: [currentRow("gh")],
        age: 5 * 86_400,
        present: [UPDATES_EMPTY, "Last checked 5d ago"],
        absent: [],
      },
      {
        name: "never dates an answer no check has produced",
        updates: [updateRow("gh", null)],
        age: null,
        present: [NEVER_CHECKED],
        absent: ["Last checked"],
      },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      stub.rows = row.updates;
      stub.lastFetched = row.age === null ? null : secondsAgo(row.age);
      const html = renderToStaticMarkup(<UpdatesPage />);
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

/** The page's own update control, when it is a menu — told from the rows'
 *  buttons by being the one that opens a choice. */
const updateMenu = (html: string) => {
  const page = document.createElement("div");
  page.innerHTML = html;
  return [
    ...page.querySelectorAll<HTMLElement>(
      '[data-slot="dropdown-menu-trigger"]',
    ),
  ].find((el) => el.textContent?.trim() === UPDATE_MENU_LABEL);
};

// One package, one place's worth, everything: three scopes of one flow.
// Which control the page draws follows how many places have news — a menu
// offering one place beside "everything" is the same choice twice.
describe("what the page offers to update", () => {
  it("asks straight out where one place holds every update", () => {
    stub.rows = [
      updateRow("one", "/work/acme"),
      updateRow("two", "/work/acme"),
    ];
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(renderedButton(html, UPDATE_ALL_LABEL)?.disabled).toBe(false);
    expect(updateMenu(html)).toBeUndefined();
  });

  it("offers each place beside everything where several have news", () => {
    stub.rows = [
      updateRow("one", "/work/acme"),
      updateRow("two", "/work/acme"),
      updateRow("three", null),
    ];
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(updateMenu(html)).toBeDefined();
    expect(renderedButton(html, UPDATE_ALL_LABEL)).toBeUndefined();
  });

  // A place whose every row is edited can take nothing, so it is not one
  // of the places the menu offers.
  it("counts only places something could be written in", () => {
    stub.rows = [
      updateRow("one", "/work/acme"),
      updateRow("two", "/work/acme"),
      updateRow("three", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
      }),
    ];
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(renderedButton(html, UPDATE_ALL_LABEL)?.disabled).toBe(false);
    expect(updateMenu(html)).toBeUndefined();
  });
});
