// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Checkbox } from "@/components/ui/checkbox";
import { opensOnActivate } from "@/lib/opens-on-activate";
import { mount } from "@/test/dom";

afterEach(() => {
  vi.restoreAllMocks();
});

// One contract behind every row, card and line in the app that opens what
// it names. What a click means is settled by `clickAsksToOpen`; what this
// adds is the keyboard, and the surface's place in the tab order.
describe("a surface that opens what it names", () => {
  const mountSurface = () => {
    const onOpen = vi.fn();
    const inside = vi.fn();
    const ticked = vi.fn();
    const host = mount(
      <div {...opensOnActivate(onOpen, "Open gh")} data-testid="surface">
        <span data-testid="text">gh</span>
        <Checkbox aria-label="Select gh" onCheckedChange={ticked} />
        <button type="button" onClick={inside}>
          Update
        </button>
        <button type="button" disabled data-testid="off" onClick={inside}>
          Update
        </button>
      </div>,
    );
    const at = (id: string) => {
      const found = host.querySelector<HTMLElement>(`[data-testid="${id}"]`);
      if (!found) throw new Error(`no ${id}`);
      return found;
    };
    const control = host.querySelector("button");
    if (!control) throw new Error("no control inside the surface");
    const box = host.querySelector<HTMLElement>('[aria-label="Select gh"]');
    if (!box) throw new Error("no tick box inside the surface");
    // jsdom lays nothing out, so every box is zero-sized at the origin —
    // where a click carrying no coordinates also lands. Give the
    // switched-off button a place of its own, so a press over it and a
    // press anywhere else are two different points.
    vi.spyOn(at("off"), "getBoundingClientRect").mockReturnValue({
      left: 40,
      right: 90,
      top: 10,
      bottom: 34,
    } as DOMRect);
    return { host, onOpen, inside, ticked, at, control, box };
  };

  it("takes focus, opens on Enter, and leaves its own controls alone", async () => {
    const cases = [
      // A keyboard reaches the surface and Enter opens it.
      {
        name: "Enter on the surface",
        act: "enter-surface",
        opens: 1,
        ran: 0,
        ticks: 0,
      },
      // Enter on a button inside runs that button, and only that button —
      // otherwise every keyboard press on a row's Update would leave the
      // page as well.
      {
        name: "Enter on a control",
        act: "enter-control",
        opens: 0,
        ran: 1,
        ticks: 0,
      },
      // A click anywhere the controls do not answer opens.
      {
        name: "click on the text",
        act: "click-text",
        opens: 1,
        ran: 0,
        ticks: 0,
      },
      // A completed click on a control is that control's.
      {
        name: "click on a control",
        act: "click-control",
        opens: 0,
        ran: 1,
        ticks: 0,
      },
      // A tick box is drawn as a span rather than a button, and pressing it
      // selects the row without leaving the page.
      {
        name: "click on a tick box",
        act: "click-box",
        opens: 0,
        ran: 0,
        ticks: 1,
      },
      // A switched-off control takes no pointer events, so the click lands
      // on the surface behind it. Pressing a greyed-out Update asked for
      // nothing and must open nothing.
      {
        name: "press over a switched-off control",
        act: "press-off",
        opens: 0,
        ran: 0,
        ticks: 0,
      },
      // The inverse: a press on the same row clear of that control's box
      // still opens, so the refusal covers the button and not the row.
      {
        name: "press clear of the switched-off control",
        act: "press-clear",
        opens: 1,
        ran: 0,
        ticks: 0,
      },
      // A click ending a drag across the surface's text was someone keeping
      // the text, not asking to leave the page.
      {
        name: "click ending a drag",
        act: "drag-text",
        opens: 0,
        ran: 0,
        ticks: 0,
      },
    ];
    expect(cases).toHaveLength(8);
    for (const entry of cases) {
      const { onOpen, inside, ticked, at, control, box } = mountSurface();
      expect(at("surface").getAttribute("tabindex"), entry.name).toBe("0");
      // The extra focus stop says what it is and what opens it: a stop
      // that announced only the cells it holds would tell a reader
      // nothing about where Enter goes.
      expect(at("surface").getAttribute("aria-label"), entry.name).toBe(
        "Open gh",
      );
      expect(at("surface").getAttribute("aria-keyshortcuts"), entry.name).toBe(
        "Enter",
      );
      if (entry.act === "drag-text")
        vi.spyOn(window, "getSelection").mockReturnValue({
          isCollapsed: false,
        } as Selection);
      if (entry.act === "enter-surface") {
        act(() => at("surface").focus());
        await userEvent.keyboard("{Enter}");
      } else if (entry.act === "enter-control") {
        act(() => control.focus());
        await userEvent.keyboard("{Enter}");
      } else if (entry.act === "click-control") {
        await userEvent.click(control);
      } else if (entry.act === "press-off" || entry.act === "press-clear") {
        // 50 lies inside the switched-off button's stubbed box, 120 beyond
        // its right edge; both are presses on the surface, since a
        // switched-off control never becomes the target.
        await userEvent.pointer({
          target: at("surface"),
          coords: {
            clientX: entry.act === "press-off" ? 50 : 120,
            clientY: 20,
          },
          keys: "[MouseLeft]",
        });
      } else if (entry.act === "click-box") {
        await userEvent.click(box);
      } else {
        await userEvent.click(at("text"));
      }
      expect(onOpen, entry.name).toHaveBeenCalledTimes(entry.opens);
      expect(inside, entry.name).toHaveBeenCalledTimes(entry.ran);
      expect(ticked, entry.name).toHaveBeenCalledTimes(entry.ticks);
      vi.restoreAllMocks();
    }
  });

  // The control: a surface that does not take the contract stays out of the
  // tab order and answers nothing, so the assertions above are about what
  // `opensOnActivate` adds rather than about the browser's own behaviour.
  it("leaves a surface without it closed to both", async () => {
    const onOpen = vi.fn();
    const host = mount(
      <div data-testid="plain">
        <span data-testid="plain-text">gh</span>
      </div>,
    );
    const surface = host.querySelector<HTMLElement>('[data-testid="plain"]');
    const text = host.querySelector<HTMLElement>('[data-testid="plain-text"]');
    if (!surface || !text) throw new Error("no plain surface");
    expect(surface.getAttribute("tabindex")).toBeNull();
    expect(surface.getAttribute("aria-label")).toBeNull();
    act(() => surface.focus());
    await userEvent.keyboard("{Enter}");
    await userEvent.click(text);
    expect(onOpen).not.toHaveBeenCalled();
  });
});
