// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { FORKED_BADGE_LABEL } from "@/lib/copy";
import { groupItems } from "@/lib/derive";
import type { PlaceMark } from "@/lib/place-marks";
import { InstalledRow } from "./installed-row";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const item = (scope: Scope) => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
  fileState: "file",
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
});

const group = groupItems([item(VG), item(HYPR)] as never)[0];

const render = (mark: PlaceMark | null, forkedIn: Scope[] = []) =>
  renderToStaticMarkup(
    <InstalledRow
      group={group}
      origin={null}
      mark={mark}
      forkedIn={forkedIn}
      onOpen={() => {}}
    />,
  );

describe("the row's customized mark", () => {
  it("is a way into the place it names", () => {
    const shown = render({
      label: "Customized in vg · 1 of 2 places",
      goTo: VG,
      why: "settings",
    });
    expect(shown).toContain("Customized in vg · 1 of 2 places");
    expect(shown).toMatch(/<button[^>]*>Customized in vg/);
  });

  // Naming two places and opening a third — the row's primary, which may
  // hold nothing of the reader's — sends them somewhere the label never
  // mentioned.
  it("offers no destination when it names more than one place", () => {
    const shown = render({
      label: "Customized in vg and hyprtrade · 2 of 2 places",
      goTo: null,
      why: null,
    });
    expect(shown).toContain("Customized in vg and hyprtrade");
    expect(shown).not.toMatch(/<button[^>]*>Customized/);
  });

  it("names the place each fork belongs to", () => {
    const shown = render(null, [VG]);
    expect(shown).toContain("in vg");
  });
});

// Whether a click reaches the row, and what a keypress lands on, are
// questions about a live DOM that static markup cannot answer.
const mounted: Root[] = [];
afterEach(() => {
  act(() => {
    for (const root of mounted) root.unmount();
  });
  mounted.length = 0;
  document.body.replaceChildren();
  vi.restoreAllMocks();
});

const mount = (forkedIn: Scope[] = [], mark: PlaceMark | null = null) => {
  const onOpen = vi.fn();
  // A tr needs a table around it for the DOM to keep the row a row.
  const host = document.body.appendChild(document.createElement("table"));
  const root = createRoot(host);
  mounted.push(root);
  act(() =>
    root.render(
      <tbody>
        <InstalledRow
          group={group}
          origin={null}
          mark={mark}
          forkedIn={forkedIn}
          onOpen={onOpen}
        />
      </tbody>,
    ),
  );
  return { host, onOpen };
};

const nameButton = (host: HTMLElement) => {
  const name = Array.from(host.querySelectorAll("button")).find(
    (b) => b.textContent === "gh",
  );
  if (!name) throw new Error("the package name is not a button");
  return name;
};

describe("opening a package from its Library row", () => {
  it("reaches the keyboard: the name is a button and Enter opens it", async () => {
    const { host, onOpen } = mount();
    nameButton(host).focus();
    await userEvent.keyboard("{Enter}");
    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith();
  });

  it("opens once from the name, not a second time from the row under it", async () => {
    const { host, onOpen } = mount();
    await userEvent.click(nameButton(host));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("keeps the whole row as the mouse shortcut", async () => {
    const { host, onOpen } = mount();
    const typeCell = host.querySelectorAll("td")[1];
    await userEvent.click(typeCell);
    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith();
  });

  it("keeps Enter working while a selection stands elsewhere", async () => {
    const { host, onOpen } = mount();
    // Keyboard activation arrives as a click with detail 0 and leaves the
    // document's selection standing — it is always asking to open.
    vi.spyOn(window, "getSelection").mockReturnValue({
      isCollapsed: false,
    } as Selection);
    nameButton(host).focus();
    await userEvent.keyboard("{Enter}");
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("opens from the name while a selection stands elsewhere", async () => {
    const { host, onOpen } = mount();
    // A completed click on the button is intent to open even while text
    // stands selected somewhere — on WebKit a button click leaves the
    // selection be, and a guard here made this a dead click.
    vi.spyOn(window, "getSelection").mockReturnValue({
      isCollapsed: false,
    } as Selection);
    await userEvent.click(nameButton(host));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("lets a drag across the row keep its selection", async () => {
    const { host, onOpen } = mount();
    // What a copy-drag leaves behind at mouse-up: an uncollapsed selection.
    vi.spyOn(window, "getSelection").mockReturnValue({
      isCollapsed: false,
    } as Selection);
    await userEvent.click(host.querySelectorAll("td")[1]);
    expect(onOpen).not.toHaveBeenCalled();
  });

  it("opens the mark's own place from its button, and only that", async () => {
    const { host, onOpen } = mount([], {
      label: "Customized in vg · 1 of 2 places",
      goTo: VG,
      why: "settings",
    });
    const markButton = Array.from(host.querySelectorAll("button")).find((b) =>
      b.textContent?.startsWith("Customized"),
    );
    if (!markButton) throw new Error("no mark button rendered");
    await userEvent.click(markButton);
    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith(VG);
  });

  it("opens the fork's own place from its badge, and only that", async () => {
    const { host, onOpen } = mount([VG]);
    const badge = Array.from(host.querySelectorAll("button")).find((b) =>
      b.textContent?.startsWith(FORKED_BADGE_LABEL),
    );
    if (!badge) throw new Error("no forked badge rendered");
    await userEvent.click(badge);
    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith(VG);
  });
});
