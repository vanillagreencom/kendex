// @vitest-environment jsdom
// The one guided install: what it asks, what it sends per place, what it
// says afterwards, and the way it offers to the place that now has the
// package.
//
// The install is held unresolved in the cases that read a running state —
// a loading indicator asserted after the work has already finished passes
// against a component that never draws one.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import type { AppSettings, Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  ALL_PROJECTS_LABEL,
  INSTALL_ACTION,
  INSTALL_NO_PLACE,
  INSTALLING_LABEL,
  installedIn,
  installedPartlyIn,
  installFailedIn,
  installsWhereItLives,
  justThisLabel,
  openPlaceLabel,
  refusalLine,
  TOOLS_PER_PLACE,
  unreadLine,
} from "@/lib/copy-install";
import { harnessName } from "@/lib/labels";
import {
  type InstallAsk,
  type InstallSubject,
  useInstallFlow,
} from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import type { InstallResult } from "@/stores/marketplaces-install";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { InstallDialog } from "./install-dialog";

vi.mock("@/bindings", () => ({
  commands: { installTargets: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const HOME: Scope = { scope: "global" };
const ACME: Scope = { scope: "project", root: "/work/acme" };
const BETA: Scope = { scope: "project", root: "/work/beta" };

const gh: InstallSubject = {
  id: "one",
  label: justThisLabel("gh"),
  what: "gh",
  count: 1,
  groups: [
    {
      source: "kit",
      browsing: HOME,
      items: [{ kind: "skill", name: "gh" }],
      bundle: null,
    },
  ],
  kinds: ["skill"],
};

const askFor = (subject: InstallSubject = gh): InstallAsk => ({
  subjects: [subject],
});

/** The store action the flow lands on. Typed as the store declares it, so
 *  a case cannot hand the flow a shape the real action never takes. */
type Install = (request: {
  scope: Scope;
  source: string;
  destination?: Scope | null;
  delivery?: unknown;
  quiet?: boolean;
}) => Promise<InstallResult>;
let install: Mock<Install>;

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.installTargets).mockResolvedValue({
    status: "ok",
    data: [
      { harness: "claude", detected: true, sharesTheUniversalTree: true },
      { harness: "codex", detected: true, sharesTheUniversalTree: true },
    ],
  });
  install = vi.fn<Install>(async () => ({ ok: true, unread: null }));
  useMarketplacesStore.setState({ busy: false, install });
  useSettingsStore.setState({
    settings: { projects: [ACME.root, BETA.root] } as AppSettings,
  });
  useNavStore.setState({ installInto: null, page: "marketplaces" });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
});

const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  );
  if (!found) throw new Error(`no ${label} button`);
  return found;
};

const box = (label: string): HTMLElement => {
  const found = document.querySelector(`[aria-label="${label}"]`);
  if (!(found instanceof HTMLElement)) throw new Error(`no ${label} box`);
  return found;
};

/** Open the flow and draw it. */
async function open(ask: InstallAsk = askFor()): Promise<void> {
  mount(<InstallDialog />);
  act(() => useInstallFlow.getState().open(ask));
  await settle();
}

describe("the guided install", () => {
  // What and where in one place, and one action at the end of it. The
  // reader picks the places; the flow sends one install per place, because
  // the command writes into exactly one scope.
  it("installs into every place picked, one call each", async () => {
    await open();

    await userEvent.click(box("acme"));
    await userEvent.click(box("beta"));
    await settle();
    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(install).toHaveBeenCalledTimes(3);
    expect(install.mock.calls.map((call) => call[0].destination)).toEqual([
      null,
      ACME,
      BETA,
    ]);
  });

  // "All projects" is an answer a reader can see the state of, not a
  // shortcut that ticks boxes and forgets: it is ticked exactly when every
  // project is.
  it("reaches every project from one box", async () => {
    await open();

    await userEvent.click(box(ALL_PROJECTS_LABEL));
    await settle();
    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(install.mock.calls.map((call) => call[0].destination)).toEqual([
      null,
      ACME,
      BETA,
    ]);
  });

  // The indicator is read while the install is still out. Asserted after
  // it lands, it would pass against a dialog that never drew one.
  it("says it is installing while the install is still out", async () => {
    let land: (result: InstallResult) => void = () => {};
    install.mockImplementation(
      () =>
        new Promise<InstallResult>((resolve) => {
          land = resolve;
        }),
    );
    await open();

    await userEvent.click(button(INSTALL_ACTION));
    await settle();
    expect(document.body.textContent).toContain(INSTALLING_LABEL);
    expect(button(INSTALLING_LABEL).disabled).toBe(true);

    await act(async () => land({ ok: true, unread: null }));
    await settle();
    expect(document.body.textContent).toContain(
      installedIn("gh", ["Personal"]),
    );
  });

  // What happened, where — and the way to the place that has it. A count
  // would not say which places the files are actually in.
  it("names every place that landed and offers the way to one", async () => {
    await open();

    await userEvent.click(box("acme"));
    await settle();
    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(document.body.textContent).toContain(
      installedIn("gh", ["Personal", "acme"]),
    );
    await userEvent.click(button(openPlaceLabel("Personal")));
    await settle();
    expect(useNavStore.getState().page).toBe("library");
    expect(useNavStore.getState().libraryFilter).toEqual({ scope: "global" });
  });

  // A run into two places that lands in one is neither a success nor a
  // failure. Both halves are said, so the reader knows which place has the
  // files.
  it("names the places that refused beside the ones that landed", async () => {
    install.mockImplementation(async (request) =>
      request.destination === null
        ? { ok: true, unread: null }
        : { ok: false, reason: "no lock there" },
    );
    await open();

    await userEvent.click(box("acme"));
    await settle();
    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(document.body.textContent).toContain(
      installedIn("gh", ["Personal"]),
    );
    expect(document.body.textContent).toContain(
      installFailedIn("gh", ["acme"]),
    );
    // The engine's own reason, beside the place that gave it — the toast
    // that used to carry it is suppressed for a caller that reports for
    // itself.
    expect(document.body.textContent).toContain(
      refusalLine("acme", "no lock there"),
    );
  });

  // The command reads the place back once the plan is committed, and that
  // read can fail over files that are on disk. Reported as a refusal it
  // becomes the one account the reader cannot act on: told the install
  // failed, with the packages installed.
  it("reports a place whose read behind the write failed as installed", async () => {
    install.mockImplementation(async () => ({
      ok: true,
      unread: "the catalogue would not read",
    }));
    await open();

    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(document.body.textContent).toContain(
      installedIn("gh", ["Personal"]),
    );
    expect(document.body.textContent).not.toContain(
      installFailedIn("gh", ["Personal"]),
    );
    expect(document.body.textContent).toContain(
      unreadLine("Personal", "the catalogue would not read"),
    );
  });

  // A place two marketplaces reach can take one package and refuse the
  // other. Reporting only the refusal denies the files that are in;
  // reporting only the landing claims the ones that are not.
  it("says a place took only some of it", async () => {
    install.mockImplementation(async (request) =>
      request.source === "kit"
        ? { ok: true, unread: null }
        : { ok: false, reason: "no lock there" },
    );
    await open(
      askFor({
        ...gh,
        what: "2 packages",
        count: 2,
        groups: [
          gh.groups[0],
          {
            source: "other",
            browsing: HOME,
            items: [{ kind: "skill", name: "lint" }],
            bundle: null,
          },
        ],
      }),
    );

    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(document.body.textContent).toContain(
      installedPartlyIn("2 packages", ["Personal"]),
    );
    expect(document.body.textContent).not.toContain(
      installedIn("2 packages", ["Personal"]),
    );
    expect(document.body.textContent).not.toContain(
      installFailedIn("2 packages", ["Personal"]),
    );
    // A place holding some of it is still a place worth opening.
    expect(button(openPlaceLabel("Personal"))).toBeTruthy();
  });

  // The reader already said which project they were browsing for. Asking
  // again is the step that made "add a project, then add packages to it"
  // two paths instead of one.
  it("opens on the project the reader came from", async () => {
    useNavStore.setState({ installInto: BETA });
    await open();

    await userEvent.click(button(INSTALL_ACTION));
    await settle();
    expect(install).toHaveBeenCalledTimes(1);
    expect(install.mock.calls[0][0].destination).toEqual(BETA);
  });

  // Nowhere to install is not an install: the button is off and says why
  // rather than reporting success over a plan that wrote nothing.
  it("holds the action back with no place picked", async () => {
    await open();

    await userEvent.click(box("Personal"));
    await settle();

    expect(button(INSTALL_ACTION).disabled).toBe(true);
    expect(document.body.textContent).toContain(INSTALL_NO_PLACE);
  });

  // Which tools take an install is a fact about one place. Across several
  // there is no one answer, so the question is not asked and what happens
  // instead is said.
  it("asks about tools for one place and says what several do", async () => {
    await open();
    expect(document.body.textContent).toContain("Install for");
    expect(document.body.textContent).not.toContain(TOOLS_PER_PLACE);

    await userEvent.click(box("acme"));
    await settle();

    expect(document.body.textContent).not.toContain("Install for");
    expect(document.body.textContent).toContain(TOOLS_PER_PLACE);
    await userEvent.click(button(INSTALL_ACTION));
    await settle();
    // Nothing decided about tools, so each place's own defaults do.
    expect(install.mock.calls[0][0].delivery).toBeUndefined();
  });

  // An empty tool list is a choice to install nowhere, which would report
  // success over a plan that wrote nothing.
  it("holds the action back on a tool picker emptied by hand", async () => {
    await open();
    const trigger = [...document.querySelectorAll("button")].find((one) =>
      one.textContent?.includes("Install for"),
    );
    if (!trigger) throw new Error("no tool picker rendered");
    act(() => trigger.focus());
    await userEvent.keyboard("{Enter}");
    await settle();

    for (const tool of ["claude", "codex"] as const) {
      const row = [
        ...document.querySelectorAll(
          '[data-slot="dropdown-menu-content"] label',
        ),
      ].find((label) => label.textContent?.includes(harnessName(tool)));
      const check = row?.querySelector<HTMLElement>('[data-slot="checkbox"]');
      if (!check) throw new Error(`no ${tool} row rendered`);
      await userEvent.click(check);
      await settle();
    }
    await userEvent.keyboard("{Escape}");
    await settle();

    expect(button(INSTALL_ACTION).disabled).toBe(true);
  });

  // A selection can span marketplaces, and the Packages tab lists a
  // project's own subscriptions beside personal ones. With the where
  // question settled by the marketplaces rather than by the reader, each
  // group installs where it lives — sweeping the personal packages into
  // the project would write files into a checkout nobody chose, and the
  // dialog's own sentence says they install where their marketplace does.
  it("keeps a mixed selection in each marketplace's own place", async () => {
    await open(
      askFor({
        ...gh,
        what: "2 packages",
        count: 2,
        groups: [
          gh.groups[0],
          {
            source: "acme-kit",
            browsing: ACME,
            items: [{ kind: "skill", name: "lint" }],
            bundle: null,
          },
        ],
      }),
    );

    expect(document.body.textContent).toContain(
      installsWhereItLives(["Personal", "acme"]),
    );

    await userEvent.click(button(INSTALL_ACTION));
    await settle();

    expect(install).toHaveBeenCalledTimes(2);
    expect(
      install.mock.calls.map((call) => [call[0].scope, call[0].destination]),
    ).toEqual([
      [HOME, null],
      [ACME, null],
    ]);
    expect(document.body.textContent).toContain(
      installedIn("2 packages", ["Personal", "acme"]),
    );
  });

  // Only a personal subscription may be redirected into a project, so a
  // marketplace a project owns has no choice of place — and says so rather
  // than drawing a picker with nothing to pick.
  it("states the place when the marketplace belongs to one", async () => {
    await open(
      askFor({
        ...gh,
        groups: [{ ...gh.groups[0], browsing: ACME }],
      }),
    );

    expect(document.body.textContent).toContain(installsWhereItLives(["acme"]));
    expect(document.querySelector('[aria-label="Personal"]')).toBeNull();

    await userEvent.click(button(INSTALL_ACTION));
    await settle();
    expect(install.mock.calls[0][0]).toMatchObject({
      scope: ACME,
      destination: null,
    });
  });
});
