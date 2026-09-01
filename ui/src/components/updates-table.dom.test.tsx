// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  IGNORE_CONFIRM_LABEL,
  IGNORE_UPDATES_LABEL,
  UPDATE_LABEL,
} from "@/lib/copy";
import { SAFETY_CAVEAT } from "@/lib/copy-safety";
import {
  EDITED_TAG_HELP,
  FOLLOW_SOURCE_HELP,
  INSTALL_AS_NEW_LABEL,
  OWN_COPY_NAME_LABEL,
  SHOW_VERSION_LABEL,
  TABLE_OPTIONS_LABEL,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { UpdatesPage } from "@/pages/updates";
import { useAuditStore } from "@/stores/audit";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    packageForkBeside: vi.fn(),
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
    data: { rows: [], warnings: [], lastFetched: null },
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
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
    // Typing a new name clears the refusal, which was about the old one.
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
        lastFetched: null,
      },
    });
    const host = mount(<UpdatesPage />);
    await settle();
    await userEvent.click(button("1 hidden update"));
    expect(host.textContent).not.toContain("Version");
    expect(host.querySelectorAll("th")).toHaveLength(10);
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
    expect(host.querySelectorAll("th")).toHaveLength(12);
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
      data: { rows: [row("one", null)], warnings: [], lastFetched: null },
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
      data: { rows: [row("one", null)], warnings: [], lastFetched: null },
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

    for (const flag of ["checking", "busy"] as const) {
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

// A number with a severity and a count behind it and no way to the findings
// is a claim the row cannot back up: the tooltip carries the score and the
// caveat, never a file or a line.
describe("the findings behind a row's score", () => {
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
        harness: "claude",
        scope: { scope: "global" },
        location: "",
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

  const score = (): HTMLElement => {
    const found = document.querySelector<HTMLElement>(
      '[data-slot="tooltip-trigger"][aria-expanded]',
    );
    if (!found) throw new Error("expected the score to open something");
    return found;
  };

  it("opens them from the score, and keeps them out of the row until asked", async () => {
    act(() => {
      useAuditStore.setState({
        views: [scoredGh()],
        auditedAt: Date.now(),
        read: READ_LANDED,
      });
    });
    const host = mount(<UpdatesTable rows={[row("gh", null)]} />);

    expect(host.textContent).not.toContain("SKILL.md:20");
    expect(score().getAttribute("aria-expanded")).toBe("false");

    await userEvent.click(score());

    expect(host.textContent).toContain("SKILL.md:20");
    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain(SAFETY_CAVEAT);
    expect(score().getAttribute("aria-expanded")).toBe("true");
  });

  // Nothing behind the number is nothing to open: a control that expands
  // onto an empty row is a promise the row cannot keep.
  it("offers no way in for a clean reading", () => {
    act(() => {
      useAuditStore.setState({
        views: [{ ...scoredGh(), safety: [] }],
        auditedAt: Date.now(),
        read: READ_LANDED,
      });
    });
    mount(<UpdatesTable rows={[row("gh", null)]} />);

    expect(
      document.querySelector('[data-slot="tooltip-trigger"][aria-expanded]'),
    ).toBeNull();
  });
});

describe("the explanations on the header and the tag", () => {
  it("open their words on focus, not only on hover", () => {
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    // Three triggers in document order: the header's Follow source note,
    // then the row's score and its Edited tag.
    const [help, , tag] = [
      ...document.querySelectorAll<HTMLElement>(
        '[data-slot="tooltip-trigger"]',
      ),
    ];
    if (!help || !tag) throw new Error("expected three tooltip triggers");
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();

    act(() => help.focus());
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toBe(FOLLOW_SOURCE_HELP);

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
        lastFetched: null,
      },
    });
    mount(<UpdatesPage />);
    await settle();

    const updates = [...document.querySelectorAll("button")].filter(
      (b) => b.textContent === UPDATE_LABEL,
    );
    expect(updates).toHaveLength(2);
    const [pi, skill] = updates;
    expect(pi?.disabled).toBe(true);
    expect(pi?.getAttribute("title")).toBe(refusal);
    // The control: a row core sends no refusal for is still offered.
    expect(skill?.disabled).toBe(false);
  });
});
