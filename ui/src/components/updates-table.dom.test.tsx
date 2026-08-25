// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  EDITED_TAG_HELP,
  FOLLOW_SOURCE_HELP,
  INSTALL_AS_NEW_LABEL,
  OWN_COPY_NAME_LABEL,
  SHOW_VERSION_LABEL,
  TABLE_OPTIONS_LABEL,
} from "@/lib/copy-updates";
import { UpdatesPage } from "@/pages/updates";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";
import { mount, settle } from "@/test/dom";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

vi.mock("@/bindings", () => ({
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
    loaded: true,
    checking: false,
    overviewInFlight: false,
    error: null,
  });
  useUpdatesView.setState({ showVersion: false });
  vi.clearAllMocks();
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: [], warnings: [] },
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
        heldBack: [],
        queued: [],
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

describe("a page with only muted updates", () => {
  it("still carries the `…` menu, on the muted table", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row("two", null, { ignored: true })], warnings: [] },
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

describe("the explanations on the header and the tag", () => {
  it("open their words on focus, not only on hover", () => {
    mount(<UpdatesTable rows={[edited]} onIgnore={() => {}} />);
    const [help, tag] = [
      ...document.querySelectorAll<HTMLElement>(
        '[data-slot="tooltip-trigger"]',
      ),
    ];
    if (!help || !tag) throw new Error("expected two tooltip triggers");
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
