import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SAFETY_SECTION_EXPLAINER } from "@/lib/copy-safety";
import { SettingsPage } from "./settings";

const html = () => renderToStaticMarkup(<SettingsPage />);

describe("the Safety check settings section", () => {
  it("says what the check is before offering the dial that tunes it", () => {
    const page = html();
    expect(page).toContain(SAFETY_SECTION_EXPLAINER);
    expect(page.indexOf("Safety check")).toBeLessThan(
      page.indexOf(SAFETY_SECTION_EXPLAINER),
    );
    expect(page.indexOf(SAFETY_SECTION_EXPLAINER)).toBeLessThan(
      page.indexOf("How cautious"),
    );
  });
});
