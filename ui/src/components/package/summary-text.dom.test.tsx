// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { describe, expect, it } from "vitest";
import { SHOW_LESS_LABEL, SHOW_MORE_LABEL } from "@/lib/copy";
import { PREVIEW_SUMMARY_CHARS } from "@/lib/package-summary";
import { mount } from "@/test/dom";
import { SummaryText } from "./summary-text";

/** A summary past the preview bound, whose last words are the ones a
 *  bounded reading leaves out. This is the page a preview's More sends a
 *  reader to, so the rest has to be reachable here and nowhere further
 *  on. */
const LONG = `${"kendex ".repeat(Math.ceil(PREVIEW_SUMMARY_CHARS / 7) + 8)}and the last part.`;

const press = async (host: HTMLElement, label: string) => {
  const button = [...host.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  );
  if (!button) throw new Error(`no ${label} control on screen`);
  await act(async () => {
    await userEvent.click(button);
  });
};

describe("SummaryText", () => {
  it("opens the rest of a long summary in place and puts it back", async () => {
    const host = mount(<SummaryText summary={LONG} />);
    expect(host.textContent).toContain(SHOW_MORE_LABEL);
    expect(host.textContent).not.toContain("and the last part.");

    await press(host, SHOW_MORE_LABEL);
    expect(host.textContent).toContain("and the last part.");
    expect(host.textContent).toContain(SHOW_LESS_LABEL);

    await press(host, SHOW_LESS_LABEL);
    expect(host.textContent).not.toContain("and the last part.");
    expect(host.textContent).toContain(SHOW_MORE_LABEL);
  });

  it("shows a short summary whole, with nothing to open", () => {
    const host = mount(<SummaryText summary="Stops a bare cd." />);
    expect(host.textContent).toBe("Stops a bare cd.");
  });
});
