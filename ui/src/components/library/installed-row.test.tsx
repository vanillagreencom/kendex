// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { FORKED_BADGE_LABEL } from "@/lib/copy";
import { groupItems } from "@/lib/derive";
import { mount as mountTree } from "@/test/dom";
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

const render = (forkedIn: Scope[] = []) =>
  renderToStaticMarkup(
    <InstalledRow
      group={group}
      origin={null}
      forkedIn={forkedIn}
      onOpen={() => {}}
    />,
  );

describe("the row's fork badge", () => {
  it("names the place each fork belongs to", () => {
    expect(render([VG])).toContain("in vg");
  });
});

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
    // selection be, so a guard on the selection would make this a dead
    // click.
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

// Whether a click reaches the row, and what a keypress lands on, are
// questions about a live DOM that static markup cannot answer.
afterEach(() => {
  vi.restoreAllMocks();
});

const mount = (forkedIn: Scope[] = []) => {
  const onOpen = vi.fn();
  // A table host, so the row is mounted inside the structure it renders
  // for rather than under a div.
  const host = mountTree(
    <tbody>
      <InstalledRow
        group={group}
        origin={null}
        forkedIn={forkedIn}
        onOpen={onOpen}
      />
    </tbody>,
    { host: "table" },
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
