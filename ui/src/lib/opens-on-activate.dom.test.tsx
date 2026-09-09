// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
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
    const host = mount(
      <div {...opensOnActivate(onOpen)} data-testid="surface">
        <span data-testid="text">gh</span>
        <button type="button" onClick={inside}>
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
    return { host, onOpen, inside, at, control };
  };

  it("takes focus, opens on Enter, and leaves its own controls alone", async () => {
    const cases = [
      // A keyboard reaches the surface and Enter opens it.
      { name: "Enter on the surface", act: "enter-surface", opens: 1, ran: 0 },
      // Enter on a button inside runs that button, and only that button —
      // otherwise every keyboard press on a row's Update would leave the
      // page as well.
      { name: "Enter on a control", act: "enter-control", opens: 0, ran: 1 },
      // A click anywhere the controls do not answer opens.
      { name: "click on the text", act: "click-text", opens: 1, ran: 0 },
      // A completed click on a control is that control's.
      { name: "click on a control", act: "click-control", opens: 0, ran: 1 },
      // A click ending a drag across the surface's text was someone keeping
      // the text, not asking to leave the page.
      { name: "click ending a drag", act: "drag-text", opens: 0, ran: 0 },
    ];
    expect(cases).toHaveLength(5);
    for (const entry of cases) {
      const { onOpen, inside, at, control } = mountSurface();
      expect(at("surface").getAttribute("tabindex"), entry.name).toBe("0");
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
      } else {
        await userEvent.click(at("text"));
      }
      expect(onOpen, entry.name).toHaveBeenCalledTimes(entry.opens);
      expect(inside, entry.name).toHaveBeenCalledTimes(entry.ran);
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
    act(() => surface.focus());
    await userEvent.keyboard("{Enter}");
    await userEvent.click(text);
    expect(onOpen).not.toHaveBeenCalled();
  });
});
