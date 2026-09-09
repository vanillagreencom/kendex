// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { mount } from "@/test/dom";
import { FileTree } from "./file-tree";

const paths = ["SKILL.md", "references/deep/a.md", "references/b.md"];

const render = (onSelect: (path: string) => void = () => {}) =>
  mount(
    <FileTree
      entries={paths.map((path) => ({ path }))}
      selected={null}
      onSelect={onSelect}
      label="Files"
    />,
  );

/** Every row's own text, in the order the tree draws them. */
const rows = (host: HTMLElement) =>
  [...host.querySelectorAll("button")].map((one) => one.textContent);

const named = (host: HTMLElement, text: string) =>
  [...host.querySelectorAll("button")].find(
    (one) => one.textContent === text,
  ) as HTMLElement;

describe("the file tree", () => {
  it("draws a folder for every directory in the paths, open, in order", () => {
    expect(rows(render())).toEqual([
      "references",
      "deep",
      "a.md",
      "b.md",
      "SKILL.md",
    ]);
  });

  // Indentation is the nesting itself: a row inside a folder sits in a
  // list inside that folder's row, so closing the folder takes the whole
  // subtree with it.
  it("closes a folder and everything under it, and opens it again", async () => {
    const host = render();
    await userEvent.click(named(host, "references"));
    expect(rows(host)).toEqual(["references", "SKILL.md"]);
    await userEvent.click(named(host, "references"));
    expect(rows(host)).toEqual([
      "references",
      "deep",
      "a.md",
      "b.md",
      "SKILL.md",
    ]);
  });

  // The control: a folder is not a file. Clicking one opens it and reports
  // nothing, or a reader could never expand a folder without the pane
  // beside it changing to something they did not ask for.
  it("reports the file a person picks, and never a folder", async () => {
    const picked = vi.fn();
    const host = render(picked);
    await userEvent.click(named(host, "references"));
    expect(picked).not.toHaveBeenCalled();
    await userEvent.click(named(host, "SKILL.md"));
    expect(picked.mock.calls).toEqual([["SKILL.md"]]);
  });

  it("names the whole path of every row, however deeply it sits", () => {
    const host = render();
    expect(named(host, "a.md").title).toBe("references/deep/a.md");
    expect(named(host, "deep").title).toBe("references/deep");
  });
});
