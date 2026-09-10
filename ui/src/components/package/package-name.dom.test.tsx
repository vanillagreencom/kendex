// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { describe, expect, it, vi } from "vitest";
import { MORE_ABOUT_PACKAGE_LABEL } from "@/lib/copy";
import { PREVIEW_SUMMARY_CHARS } from "@/lib/package-summary";
import { mount } from "@/test/dom";
import { PackageName } from "./package-name";

const LONG = `${"kendex ".repeat(Math.ceil(PREVIEW_SUMMARY_CHARS / 7) + 8)}end.`;

/** Base UI holds a preview back for a moment after the pointer or the
 *  focus arrives, so a pass over a table does not flash a card per row.
 *  Longer than that hold, so what is asserted is what stays on screen. */
const AFTER_THE_HOLD = 1000;

/** Reach the name the way a keyboard user does — the reachability the card
 *  exists for — and let the hold pass. */
const focusName = async (host: HTMLElement) => {
  if (!host.querySelector("button")) {
    throw new Error("the package name is not a control");
  }
  await act(async () => {
    await userEvent.tab();
  });
  await act(async () => {
    await new Promise((settle) => setTimeout(settle, AFTER_THE_HOLD));
  });
};

const preview = () =>
  document.body.querySelector("[data-slot=preview-card-content]");

// The preview has to be reachable without a pointer, has to appear only
// where there is something to read, and has to offer the rest of the text
// when it left any out.
describe("the preview on a package name", () => {
  it("opens on focus and shows the author's words whole when they fit", async () => {
    const host = mount(
      <PackageName name="guard" summary="Stops a bare cd." onOpen={() => {}} />,
    );
    expect(preview(), "nothing before the name is reached").toBe(null);
    await focusName(host);
    expect(preview()?.textContent).toContain("Stops a bare cd.");
    expect(preview()?.textContent).not.toContain(MORE_ABOUT_PACKAGE_LABEL);
  });

  it("offers no preview for a package whose author wrote nothing", async () => {
    const host = mount(
      <PackageName name="guard" summary={null} onOpen={() => {}} />,
    );
    await focusName(host);
    expect(preview()).toBe(null);
  });

  it("offers the package page for the text it could not fit", async () => {
    const onOpen = vi.fn();
    const host = mount(
      <PackageName name="guard" summary={LONG} onOpen={onOpen} />,
    );
    await focusName(host);
    const shown = preview()?.textContent ?? "";
    expect(shown).toContain(MORE_ABOUT_PACKAGE_LABEL);
    expect(shown, "the card is bounded, not the whole paragraph").not.toContain(
      "end.",
    );
    const more = [
      ...document.body.querySelectorAll<HTMLButtonElement>("button"),
    ].find((button) => button.textContent === MORE_ABOUT_PACKAGE_LABEL);
    expect(more, "More is a real control inside the card").toBeTruthy();
    act(() => more?.click());
    expect(onOpen).toHaveBeenCalledTimes(1);
  });
});
