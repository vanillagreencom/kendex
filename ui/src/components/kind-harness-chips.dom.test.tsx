// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it } from "vitest";
import { KindHarnessChips } from "@/components/kind-harness-chips";
import { NO_FILTERS, useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";

const chip = (host: HTMLElement, label: string) => {
  const found = [...host.querySelectorAll("button")].find(
    (button) => button.getAttribute("aria-label") === label,
  );
  if (!found) throw new Error(`no chip for ${label}`);
  return found;
};

beforeEach(() => {
  useLibraryViewStore.setState({ ...NO_FILTERS });
  useNavStore.setState({ page: "unmanaged", libraryFilter: null });
});

// These chips ride on rows that name things with no page of their own — an
// unmanaged file, a declaration nothing has installed. The harness a chip
// names always has one, and it is the chip that names it.
describe("the harness chips on an unmanaged or blocked row", () => {
  it("open the harness the chip names", async () => {
    const host = mount(
      <KindHarnessChips kind="skill" harnesses={["claude", "codex"]} />,
    );
    await userEvent.click(chip(host, "Codex"));
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter).toEqual({ harness: "codex" });
  });

  // The control: the kind beside them is a label, not a way anywhere — it
  // names what the thing is, and this row's thing has no page.
  it("leaves the kind chip a label", () => {
    const host = mount(
      <KindHarnessChips kind="skill" harnesses={["claude"]} />,
    );
    const kind = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Skill",
    );
    expect(kind).toBeUndefined();
    expect(host.textContent).toContain("Skill");
  });
});
