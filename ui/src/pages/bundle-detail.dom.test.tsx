// @vitest-environment jsdom
// The set page's read is wiring, not a prop: it has to ask for the set
// against the place the install would land in, and gate Install all on what
// that place's record says. A prop-driven test of the member rows cannot
// see either.
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings, BundleDetail, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { unreadableRecordsLine } from "@/lib/copy-marketplaces";
import { harnessName } from "@/lib/labels";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { BundleDetailPage } from "./bundle-detail";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceBundle: vi.fn(),
    installTargets: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

const HOME: Scope = { scope: "global" };
const catalog = subscription(HOME, "kit");
const ACME: Extract<Scope, { scope: "project" }> = {
  scope: "project",
  root: "/work/acme",
};

/** Pick a place in the destination select. A pointer click does not open a
 *  base-ui trigger under jsdom, so the keyboard path opens it. */
async function chooseDestination(host: HTMLElement, label: string) {
  const trigger = [...host.querySelectorAll("button")].find((button) =>
    button.textContent?.includes("Install to"),
  );
  if (!trigger) throw new Error("no destination select rendered");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  const option = [...document.querySelectorAll('[role="option"]')].find(
    (el) => el.textContent === label,
  );
  if (!(option instanceof HTMLElement)) throw new Error(`no ${label} option`);
  await userEvent.click(option);
  await settle();
}

/** The tool picker's row for one tool, opened. Same keyboard path as the
 *  destination select: a pointer click does not open a base-ui trigger
 *  under jsdom. The popup is portalled, so it is read off the document. */
async function toolBox(host: HTMLElement, tool: string) {
  const trigger = [...host.querySelectorAll("button")].find((button) =>
    button.textContent?.includes("Install for"),
  );
  if (!trigger) throw new Error("no tool picker rendered");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  await settle();
  const row = [
    ...document.querySelectorAll('[data-slot="dropdown-menu-content"] label'),
  ].find((label) => label.textContent?.includes(tool));
  return row?.querySelector<HTMLInputElement>('input[type="checkbox"]');
}

/** The tool picker's trigger, whose label is the choice as the page reads
 *  it: the same value both Install buttons are gated on. */
function toolTrigger(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find((button) =>
    button.textContent?.includes("Install for"),
  );
}

/** Tick a tool row and close the picker over it, so the next click lands
 *  on the page rather than on the open menu. */
async function tickTool(host: HTMLElement, tool: string) {
  const box = await toolBox(host, tool);
  if (!box) throw new Error(`no ${tool} row rendered`);
  await userEvent.click(box);
  await settle();
  await userEvent.keyboard("{Escape}");
  await settle();
}

const starter: BundleDetail = {
  name: "starter",
  description: "the six things to begin with",
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state: "available" }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable: false,
};

/** Install all, whatever it currently reads. */
function installAll(host: HTMLElement): HTMLButtonElement | undefined {
  return [...host.querySelectorAll("button")].find(
    (button) => button.textContent === "Install all",
  );
}

function answer(detail: BundleDetail) {
  vi.mocked(commands.marketplaceBundle).mockResolvedValue({
    status: "ok",
    data: detail,
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  answer(starter);
  // The real command deserializes its payload into `ItemKind`, which has no
  // variant for a blank string, so a call carrying one is refused whole and
  // the picker gets no rows. The mock refuses the same payload, or the
  // picker would draw its rows off an answer the app never gets.
  vi.mocked(commands.installTargets).mockImplementation(
    async (_scope, kinds) =>
      kinds.some((kind) => (kind as string) === "")
        ? { status: "error", error: "unknown variant ``" }
        : {
            status: "ok",
            data: [
              {
                harness: "claude",
                detected: true,
                sharesTheUniversalTree: true,
              },
            ],
          },
  );
  useMarketplacesStore.setState({ bundles: {}, readErrors: {}, busy: false });
  useSettingsStore.setState({
    settings: { projects: [ACME.root] } as AppSettings,
  });
  useNavStore.setState({ bundleRef: { bundle: "starter", catalog } });
});

describe("the curated set page", () => {
  // Everything the destination decides on this page, in one pass. The read
  // is asked again for the project and served from that project's own slot
  // when it comes back to one already read; a tick made against the place
  // before it is not carried into the one chosen next; the record standing
  // is that project's, so Install all withholds on it and the reason names
  // it.
  it("reads, gates and says why for the place the install would land in", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    expect(commands.marketplaceBundle).toHaveBeenCalledWith(
      catalog,
      "starter",
      null,
    );
    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();
    // The control: a readable record leaves the buttons alone, so what
    // follows is the record doing the withholding and not the page.
    expect(host.textContent).toContain("Install 1 selected");
    expect(installAll(host)?.disabled).toBe(false);
    expect(host.textContent).not.toContain("See Problems");

    answer({ ...starter, recordsUnreadable: true, members: [] });
    await chooseDestination(host, "acme");

    expect(commands.marketplaceBundle).toHaveBeenLastCalledWith(
      catalog,
      "starter",
      ACME,
    );
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);
    expect(host.textContent).toContain("Install 0 selected");
    expect(installAll(host)?.disabled).toBe(true);
    expect(host.textContent).toContain(unreadableRecordsLine("acme"));
    expect(host.textContent).not.toContain(unreadableRecordsLine("Personal"));

    // Back to the place being browsed, which is not a redirect, and out to
    // the project again: both answers are already in slots of their own.
    await chooseDestination(host, "Personal");
    await chooseDestination(host, "acme");
    expect(commands.marketplaceBundle).toHaveBeenCalledTimes(2);
  });

  // The tool picker is the one control that decides how Install all lands,
  // and this page opens it before any member is ticked. Nothing ticked
  // names no kind, and no kind has to reach the command as no kinds: joined
  // and split back naively it arrives as one blank kind, which `ItemKind`
  // has no variant for, so the command refuses the call, no row is drawn,
  // and the control is dead until a member is ticked.
  it("asks about every kind while nothing is ticked, and draws the tools", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();

    expect(commands.installTargets).toHaveBeenCalledWith(HOME, []);
    expect(host.textContent).not.toContain("No tools — pick at least one");
    expect(await toolBox(host, harnessName("claude"))).toBeTruthy();

    // The other half of the same answer: ticking narrows the picker to the
    // kinds actually ticked, which is the filter the install of those
    // members is refused by. No kinds means every kind; it does not mean
    // the picker stops asking about the ticked ones.
    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();

    expect(commands.installTargets).toHaveBeenLastCalledWith(HOME, ["skill"]);
  });

  // Install all installs with whatever this picker last answered, so a
  // picker emptied by hand is a choice to install nowhere for it too: a
  // plan that writes nothing and reports success.
  it("holds Install all back on a picker emptied by hand", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();
    expect(installAll(host)?.disabled).toBe(false);

    const claude = await toolBox(host, harnessName("claude"));
    if (!claude) throw new Error("no tool row rendered");
    await userEvent.click(claude);
    await settle();

    expect(installAll(host)?.disabled).toBe(true);
  });

  // Which tools are offered is a fact about the kinds being installed, and
  // ticking a member narrows them. A choice made while the picker was
  // wider can name a tool the narrowed answer no longer offers; it is not
  // an answer here, and neither button may act on it — "Install all"
  // declares every kind, so nothing refuses it and it would report success
  // having written nothing.
  it("holds both buttons back on a choice the narrowed picker dropped", async () => {
    // Cursor takes a skill at project scope only, so this set's one member
    // drops it from the answer the moment that member is ticked.
    vi.mocked(commands.installTargets).mockImplementation(
      async (_scope, kinds) => ({
        status: "ok",
        data: [
          { harness: "claude", detected: true, sharesTheUniversalTree: true },
          ...(kinds.length === 0
            ? [
                {
                  harness: "cursor" as const,
                  detected: false,
                  sharesTheUniversalTree: true,
                },
              ]
            : []),
        ],
      }),
    );
    const host = mount(<BundleDetailPage />);
    await settle();

    // Chosen against every kind, which is what nothing ticked asks about.
    await tickTool(host, harnessName("cursor"));
    await tickTool(host, harnessName("claude"));
    expect(toolTrigger(host)?.textContent).toContain(harnessName("cursor"));
    expect(installAll(host)?.disabled).toBe(false);

    const box = host.querySelector<HTMLInputElement>('input[type="checkbox"]');
    if (!box) throw new Error("no member checkbox rendered");
    await userEvent.click(box);
    await settle();

    expect(commands.installTargets).toHaveBeenLastCalledWith(HOME, ["skill"]);
    expect(toolTrigger(host)?.textContent).toContain(
      "No tools — pick at least one",
    );
    expect(installAll(host)?.disabled).toBe(true);
    expect(
      [...host.querySelectorAll("button")].find(
        (button) => button.textContent === "Install 1 selected",
      )?.disabled,
    ).toBe(true);
  });

  // A destination whose read fails is the one state the picker has to
  // outlive: it is the only way to another place, and a page that hid it
  // would strand the reader on the error with nothing to press.
  it("can be switched away from a destination whose read failed", async () => {
    const host = mount(<BundleDetailPage />);
    await settle();

    vi.mocked(commands.marketplaceBundle).mockResolvedValue({
      status: "error",
      error: "no manifest there",
    });
    await chooseDestination(host, "acme");
    expect(host.textContent).toContain("no manifest there");
    expect(host.textContent).toContain("Install to");

    await chooseDestination(host, "Personal");
    expect(host.textContent).not.toContain("no manifest there");
    expect(host.textContent).toContain("the six things to begin with");
  });
});
