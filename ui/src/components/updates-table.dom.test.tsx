// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { IGNORE_CONFIRM_LABEL, IGNORE_UPDATES_LABEL } from "@/lib/copy";
import {
  EDITED_TAG_HELP,
  INSTALL_AS_NEW_LABEL,
  OWN_COPY_NAME_LABEL,
  SHOW_VERSION_LABEL,
  TABLE_OPTIONS_LABEL,
  UPDATE_REVIEW_CONFIRM,
  UPDATE_REVIEW_LABEL,
  UPDATE_REVIEW_NOTHING_LEFT,
  UPDATES_ONE_AT_A_TIME_NOTE,
  updateReviewOneTitle,
} from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { groupUpdates } from "@/lib/update-groups";
import { UpdatesPage } from "@/pages/updates";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { PackageRows, UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    updatesOverview: vi.fn(),
    packageForkBeside: vi.fn(),
    packageDiff: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const edited = row("gh", null, {
  blockedByLocalEdit: true,
  editedHarnesses: ["claude"],
  forkableHarness: "claude",
});

const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (b) => b.textContent === label || b.getAttribute("aria-label") === label,
  );
  if (!found) throw new Error(`no button "${label}"`);
  return found;
};

const dialog = () => document.querySelector('[role="dialog"]');

beforeEach(() => {
  useUpdatesStore.setState({
    rows: [],
    busy: false,
    read: READ_LANDED,
    checking: false,
  });
  useUpdatesView.setState({ showVersion: false });
  vi.clearAllMocks();
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.packageDiff).mockResolvedValue({
    status: "ok",
    data: {
      files: [],
      totalAdditions: 0,
      totalDeletions: 0,
      truncated: false,
    },
  });
});

// Whether a click lands where the store expects is a question about a
// mounted tree; static markup cannot answer it.
describe("installing beside an edited place, from the row", () => {
  it("asks for the copy's name, proposes one, and sends the engine both names", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        adoptable: ADOPTABLE,
        exits: [],
      },
    });
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    expect(dialog()).toBeNull();

    await userEvent.click(button(INSTALL_AS_NEW_LABEL));
    const open = dialog();
    if (!open) throw new Error("no dialog opened");
    expect(open.textContent).toContain("Install gh as a new package");
    expect(open.textContent).toContain(OWN_COPY_NAME_LABEL);
    const field = open.querySelector<HTMLInputElement>("input");
    if (!field) throw new Error("no name field");
    expect(field.value).toBe("gh-edited");

    await userEvent.clear(field);
    await userEvent.type(field, "  gh-mine  ");
    await userEvent.click(
      [...open.querySelectorAll("button")].find(
        (b) => b.textContent === INSTALL_AS_NEW_LABEL,
      ) ?? open,
    );
    await settle();

    expect(commands.packageForkBeside).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "claude",
      "gh-mine",
      null,
    );
    expect(dialog()).toBeNull();
  });

  it("shows the engine's refusal under the field and keeps the dialog open", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: {
        phase: "refused",
        message: "'gh-edited' already installed from this scope's manifest",
      },
    });
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    await userEvent.click(button(INSTALL_AS_NEW_LABEL));
    const open = dialog();
    if (!open) throw new Error("no dialog opened");

    await userEvent.click(
      [...open.querySelectorAll("button")].find(
        (b) => b.textContent === INSTALL_AS_NEW_LABEL,
      ) ?? open,
    );
    await settle();

    expect(open.querySelector('[role="alert"]')?.textContent).toBe(
      "'gh-edited' already installed from this scope's manifest",
    );
    expect(dialog()).not.toBeNull();
    // Typing a different name clears the refusal, which was about the
    // name refused.
    const field = open.querySelector<HTMLInputElement>("input");
    if (!field) throw new Error("no name field");
    await userEvent.type(field, "2");
    expect(open.querySelector('[role="alert"]')).toBeNull();
  });

  // Once the fork is recorded, the name field has nothing left to fix:
  // the dialog closes and the toast says what landed.
  it("closes on a failure after the fork was recorded, rather than asking for another name", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: { phase: "recorded", message: "render refused" },
    });
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    await userEvent.click(button(INSTALL_AS_NEW_LABEL));
    const open = dialog();
    if (!open) throw new Error("no dialog opened");
    await userEvent.click(
      [...open.querySelectorAll("button")].find(
        (b) => b.textContent === INSTALL_AS_NEW_LABEL,
      ) ?? open,
    );
    await settle();
    expect(dialog()).toBeNull();
    expect(toast.info).toHaveBeenCalledWith(
      expect.stringContaining("render refused"),
    );
  });

  it("holds the button while nothing can be kept but keeps an empty name out", async () => {
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    await userEvent.click(button(INSTALL_AS_NEW_LABEL));
    const open = dialog();
    if (!open) throw new Error("no dialog opened");
    const field = open.querySelector<HTMLInputElement>("input");
    if (!field) throw new Error("no name field");
    await userEvent.clear(field);
    const submit = [...open.querySelectorAll("button")].find(
      (b) => b.textContent === INSTALL_AS_NEW_LABEL,
    );
    expect(submit?.disabled).toBe(true);
    await userEvent.click(submit ?? open);
    expect(commands.packageForkBeside).not.toHaveBeenCalled();
  });
});

describe("the table's own menu", () => {
  // The page owns the choice: its main table carries the menu, and the
  // muted table under "hidden updates" follows with no menu of its own.
  it("shows the Version column from the `…` menu, for every table on the page", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row("one", null), row("two", null, { ignored: true })],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    const host = mount(<UpdatesPage />);
    await settle();
    await userEvent.click(button("1 hidden update"));
    expect(host.textContent).not.toContain("Version");
    expect(host.querySelectorAll("th")).toHaveLength(8);
    expect(host.querySelectorAll('[aria-label="Table options"]')).toHaveLength(
      1,
    );

    // The keyboard path: a pointer click on a base-ui menu trigger does
    // not open it under jsdom, and Enter is a path a person takes too.
    const trigger = button(TABLE_OPTIONS_LABEL);
    act(() => trigger.focus());
    await userEvent.keyboard("{Enter}");
    const item = [
      ...document.querySelectorAll('[role="menuitemcheckbox"]'),
    ].find((el) => el.textContent?.includes(SHOW_VERSION_LABEL));
    if (!(item instanceof HTMLElement)) throw new Error("no Show version item");
    expect(item.getAttribute("aria-checked")).toBe("false");
    await userEvent.click(item);

    expect(useUpdatesView.getState().showVersion).toBe(true);
    expect(host.querySelectorAll("th")).toHaveLength(10);
    expect(host.textContent).toContain("1111111 → v2");
  });
});

// Ignoring a package is the one action the row's own staleness does not
// bar, so its surfaces take the pair the store refuses on. The item only
// exists once the menu is open, which is why it is held here.
describe("the row's Ignore item", () => {
  it("is held while a check is out", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row("one", null)],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    mount(<UpdatesPage />);
    await settle();

    const open = async () => {
      const trigger = button("More actions");
      act(() => trigger.focus());
      await userEvent.keyboard("{Enter}");
      const item = [...document.querySelectorAll('[role="menuitem"]')].find(
        (el) => el.textContent?.includes(IGNORE_UPDATES_LABEL),
      );
      if (!(item instanceof HTMLElement))
        throw new Error("no Ignore updates item");
      return item;
    };

    expect((await open()).getAttribute("data-disabled")).toBeNull();
    await userEvent.keyboard("{Escape}");

    await act(async () => {
      useUpdatesStore.setState({ checking: true });
    });
    expect((await open()).getAttribute("data-disabled")).toBe("");
    useUpdatesStore.setState({ checking: false });
  });

  // The dialog it opens outlives the click: a check or a write can begin
  // while it is up, and the store refuses the mute on either. The confirm
  // says so rather than closing over an error.
  it("holds the confirm it opens for either half of the pair", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row("one", null)],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    mount(<UpdatesPage />);
    await settle();

    const trigger = button("More actions");
    act(() => trigger.focus());
    await userEvent.keyboard("{Enter}");
    const item = [...document.querySelectorAll('[role="menuitem"]')].find(
      (el) => el.textContent?.includes(IGNORE_UPDATES_LABEL),
    );
    if (!(item instanceof HTMLElement)) throw new Error("no Ignore item");
    await userEvent.click(item);

    const confirm = () => button(IGNORE_CONFIRM_LABEL);
    expect(confirm().disabled).toBe(false);

    const flags = ["checking", "busy"] as const;
    expect(flags).toHaveLength(2);
    for (const flag of flags) {
      await act(async () => {
        useUpdatesStore.setState({ [flag]: true });
      });
      expect(confirm().disabled).toBe(true);
      expect(confirm().title).toBe(UPDATES_ONE_AT_A_TIME_NOTE);
      await act(async () => {
        useUpdatesStore.setState({ [flag]: false });
      });
    }
  });
});

describe("a page with only muted updates", () => {
  it("still carries the `…` menu, on the muted table", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row("two", null, { ignored: true })],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    const host = mount(<UpdatesPage />);
    await settle();
    expect(host.querySelector('[aria-label="Table options"]')).toBeNull();
    await userEvent.click(button("1 hidden update"));
    expect(host.querySelectorAll('[aria-label="Table options"]')).toHaveLength(
      1,
    );
  });
});

// A score names a reading, and the reading lives on the package page's
// Safety tab: the score is the way there, and the row shows no findings of
// its own. The tooltip carries the score and the caveat, never a file or a
// line.
describe("the reading behind a row's score", () => {
  const scoredGh = (): AuditView => ({
    scope: { scope: "global" },
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    adoptable: ADOPTABLE,
    exits: [],
    safety: [
      {
        kind: "skill",
        name: "gh",
        targets: [{ harness: "claude", location: "" }],
        scope: { scope: "global" },
        source: null,
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
      },
    ],
  });

  // The score is the row's own trigger; anything the header carries is
  // outside the body.
  const score = (host: HTMLElement): HTMLElement => {
    const found = host.querySelector<HTMLElement>(
      'tbody [data-slot="tooltip-trigger"]',
    );
    if (!found) throw new Error("expected a score on the row");
    return found;
  };

  beforeEach(() => {
    useNavStore.setState({
      page: "updates",
      packageRef: null,
      packageView: null,
    });
    act(() => {
      useAuditStore.setState({
        views: [scoredGh()],
        auditedAt: Date.now(),
        read: READ_LANDED,
      });
    });
  });

  it("opens the package page on its Safety tab, and shows no findings in the row", async () => {
    const host = mount(<UpdatesTable rows={[row("gh", null)]} />);

    expect(host.textContent).not.toContain("SKILL.md:20");
    await userEvent.click(score(host));

    const nav = useNavStore.getState();
    expect(nav.page).toBe("package");
    expect(nav.packageRef).toEqual({
      kind: "skill",
      name: "gh",
      scope: { scope: "global" },
    });
    expect(nav.packageView).toEqual({ mode: "safety" });
    // The findings never came into the row: the page carries them.
    expect(host.textContent).not.toContain("SKILL.md:20");
  });

  // A grouped row's disc is the worst of its places' readings, so it opens
  // the place that earned it. Opening the row's first place would send a
  // reader who clicked a warning to a different copy, scoring higher and
  // carrying none of the findings the number stood for.
  it("opens the place whose copy earned the reading, not the row's first", async () => {
    const worst = scoredGh();
    act(() => {
      useAuditStore.setState({
        views: [
          // Personal is listed first and reads clean; the project's copy is
          // the one the disc is showing.
          {
            ...worst,
            safety: [
              {
                ...worst.safety[0],
                findings: [],
                safety: { score: 96, deductions: [] },
              },
            ],
          },
          {
            ...worst,
            scope: { scope: "project", root: "/work/vg" },
            safety: [
              {
                ...worst.safety[0],
                scope: { scope: "project", root: "/work/vg" },
              },
            ],
          },
        ],
        auditedAt: Date.now(),
        read: READ_LANDED,
      });
    });
    const host = mount(
      <UpdatesTable rows={[row("gh", null), row("gh", "/work/vg")]} />,
    );
    // One grouped row, so the disc is the merged reading rather than either
    // place's own row.
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
    await userEvent.click(score());

    const nav = useNavStore.getState();
    expect(nav.packageRef).toEqual({
      kind: "skill",
      name: "gh",
      scope: { scope: "project", root: "/work/vg" },
    });
    expect(nav.packageView).toEqual({ mode: "safety" });
  });

  // The control: the same row's name opens the same page, on no tab in
  // particular. Without it "opens the Safety tab" could be nothing more
  // than "opens the package".
  it("opens the package on no particular tab from the name", async () => {
    const host = mount(<UpdatesTable rows={[row("gh", null)]} />);
    const name = [...host.querySelectorAll("button")].find(
      (each) => each.textContent === "gh",
    );
    if (!name) throw new Error("the package name is not a button");
    await userEvent.click(name);

    const nav = useNavStore.getState();
    expect(nav.page).toBe("package");
    expect(nav.packageView).toBeNull();
  });
});

// The Where column names a place, so it opens that place — everything
// installed there, which is a different destination from the package the
// rest of the row opens.
describe("the place on an updates row", () => {
  it("opens that place, not the package", async () => {
    useNavStore.setState({
      page: "updates",
      libraryFilter: null,
      packageRef: null,
    });
    const host = mount(<UpdatesTable rows={[row("gh", null)]} />);
    const where = [...host.querySelectorAll("button")].find(
      (each) => each.textContent === "User level",
    );
    if (!where) throw new Error("the place is not a button");
    await userEvent.click(where);

    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter).toEqual({ scope: "global" });
    expect(nav.packageRef).toBeNull();
  });
});

// A grouped package expands into a row per place. Each names a place, so
// each opens that place — not only its Where cell.
describe("an expanded place row on the updates table", () => {
  it("opens that place from the row, by pointer and by Enter", async () => {
    const methods = ["pointer", "keyboard"] as const;
    expect(methods).toHaveLength(2);
    for (const method of methods) {
      useNavStore.setState({
        page: "updates",
        libraryFilter: null,
        packageRef: null,
      });
      const host = mount(
        <tbody>
          <PackageRows
            group={groupUpdates([row("gh", null), row("gh", "/work/vg")])[0]}
            defaultOpen
          />
        </tbody>,
        { host: "table" },
      );
      // The package's own row, then one row per place: personal, then the
      // project.
      const placeRow = host.querySelectorAll("tr")[2];
      if (!(placeRow instanceof HTMLElement)) throw new Error("no place row");
      expect(placeRow.getAttribute("tabindex")).toBe("0");
      if (method === "pointer") await userEvent.click(placeRow);
      else {
        act(() => placeRow.focus());
        await userEvent.keyboard("{Enter}");
      }
      const nav = useNavStore.getState();
      expect(nav.page, method).toBe("library");
      expect(nav.libraryFilter, method).toEqual({
        scope: { project: "/work/vg" },
      });
      // The place, not the package: those are different destinations.
      expect(nav.packageRef, method).toBeNull();
    }
  });
});

describe("the explanation on the Edited tag", () => {
  it("opens its words on focus, not only on hover", () => {
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    // Two triggers in document order: the row's score, then its Edited tag.
    const [, tag] = [
      ...document.querySelectorAll<HTMLElement>(
        '[data-slot="tooltip-trigger"]',
      ),
    ];
    if (!tag) throw new Error("expected two tooltip triggers");
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();

    act(() => tag.focus());
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toBe(EDITED_TAG_HELP);
  });
});

// A kind the planner never brings current one package at a time is core's
// call, and the words are core's too: the row arrives carrying the
// refusal, and the UI shows that and nothing of its own. Every Update
// surface reads it through updateWithheld.
//
// Pass-through is the whole property, so the fixture is a string core
// would never send. Core's real wording here would read as a
// cross-boundary pin and be none: the equality asserted is fixture against
// rendered title, which any string satisfies, and a reworded constant
// would leave it green.
describe("a row of a kind core refuses", () => {
  it("offers no Update, and shows the refusal core sent", async () => {
    const refusal = "REFUSED-BY-CORE: this kind moves another way";
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [
          row("pi-hooks", null, {
            kind: "pi-extension",
            noPerPackageUpdate: refusal,
          }),
          row("gh", null),
        ],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    mount(<UpdatesPage />);
    await settle();

    const updates = [...document.querySelectorAll("button")].filter(
      (b) => b.textContent === UPDATE_REVIEW_LABEL,
    );
    expect(updates).toHaveLength(2);
    const [pi, skill] = updates;
    expect(pi?.disabled).toBe(true);
    expect(pi?.getAttribute("title")).toBe(refusal);
    // The control: a row core sends no refusal for is still offered.
    expect(skill?.disabled).toBe(false);
  });
});

// The review the page opens is a set of PLACES, looked up in the store on
// every render — not the rows the click happened to see. A read landing
// under an open dialog moves `latest`, and the confirm sends a commit read
// off these rows, so a captured array would write against a standing the
// app has already replaced.
describe("a review left open while the standing moves", () => {
  const overview = (rows: unknown[]) => ({
    status: "ok" as const,
    data: { rows, warnings: [], unreadable: [], lastFetched: null },
  });

  it("follows the store rather than the rows the click saw", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue(
      overview([row("gh", null)]) as never,
    );
    mount(<UpdatesPage />);
    await settle();

    await userEvent.click(button(UPDATE_REVIEW_LABEL));
    await settle();
    expect(document.body.textContent).toContain("1111111 → v2");

    // A read lands with a newer version for the same place.
    await act(async () => {
      useUpdatesStore.setState({
        rows: [
          row("gh", null, {
            latest: { commit: "3333333333", label: "v3", date: null },
          }),
        ],
      });
    });
    await settle();

    expect(document.body.textContent).toContain("1111111 → v3");
    expect(document.body.textContent).not.toContain("1111111 → v2");
  });

  // The same lookup is what lets the dialog's own guard fire at all: a
  // frozen array could never lose its targets. Here another window takes
  // the update the dialog was opened on, and the read lands under it.
  it("says so when the news it was opened on is gone", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue(
      overview([row("gh", null), row("dev", null)]) as never,
    );
    mount(<UpdatesPage />);
    await settle();

    const updates = [...document.querySelectorAll("button")].filter(
      (b) => b.textContent === UPDATE_REVIEW_LABEL,
    );
    expect(updates).toHaveLength(2);
    await userEvent.click(updates[0] as HTMLButtonElement);
    await settle();
    expect(button(UPDATE_REVIEW_CONFIRM).disabled).toBe(false);

    await act(async () => {
      useUpdatesStore.setState({
        rows: [
          row("gh", null, { updateAvailable: false, mixed: true }),
          row("dev", null),
        ],
      });
    });
    await settle();

    const update = button(UPDATE_REVIEW_CONFIRM);
    expect(update.disabled).toBe(true);
    expect(update.getAttribute("title")).toBe(UPDATE_REVIEW_NOTHING_LEFT);
  });
});

// The confirm that writes files is the one place a folder name must not be
// ambiguous. The table already tells a package's places apart; the review
// it opens is handed the same siblings and names the place the same way.
describe("the place a review names", () => {
  it("tells same-named folders apart in the confirm, as the row does", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row("gh", "/home/x/work/app"), row("gh", "/home/x/clients/app")],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    } as never);
    const host = mount(<UpdatesPage />);
    await settle();

    // The package folds into one row; open it to reach the place rows.
    await userEvent.click(button("2 places"));
    expect(host.textContent).toContain("work/app");
    expect(host.textContent).toContain("clients/app");

    const updates = [...document.querySelectorAll("button")].filter(
      (b) => b.textContent === UPDATE_REVIEW_LABEL,
    );
    expect(updates).toHaveLength(2);
    await userEvent.click(updates[0] as HTMLButtonElement);
    await settle();

    expect(document.body.textContent).toContain(
      updateReviewOneTitle("gh", "work/app"),
    );
    expect(document.body.textContent).not.toContain("Update gh in app?");
  });
});
