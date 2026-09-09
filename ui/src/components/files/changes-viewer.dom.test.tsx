// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import type { FileDiff, PackageDiff } from "@/bindings";
import { NO_CHANGES_NOTE } from "@/lib/copy-files";
import { mount, settle } from "@/test/dom";
import { ChangesViewer } from "./changes-viewer";

const file = (path: string, text: string): FileDiff => ({
  path,
  status: "modified",
  additions: 1,
  deletions: 0,
  lossy: false,
  hunks: [
    {
      header: `@@ ${path} @@`,
      lines: [{ kind: "add", text, oldNo: null, newNo: 1 }],
    },
  ],
});

const diff = (files: FileDiff[]): PackageDiff => ({
  files,
  totalAdditions: files.length,
  totalDeletions: 0,
  truncated: false,
});

const two = diff([
  file("src/one.md", "FIRST-FILE-LINE"),
  file("src/two.md", "SECOND-FILE-LINE"),
]);

/** A tree row by the path it names — its text also carries the file's
 *  counts, which is what the row is for. */
const rowFor = (host: HTMLElement, path: string) =>
  [...host.querySelectorAll("button")].find(
    (one) => one.title === path,
  ) as HTMLElement;

describe("the changes viewer", () => {
  // The pattern: a tree of what changed on the left, one file's diff on
  // the right — the same split reading a package's files draws.
  it("opens on the first changed file and moves to the one picked", async () => {
    const host = mount(<ChangesViewer diff={two} />);
    expect(host.textContent).toContain("FIRST-FILE-LINE");
    expect(host.textContent).not.toContain("SECOND-FILE-LINE");

    await userEvent.click(rowFor(host, "src/two.md"));
    await settle();
    expect(host.textContent).toContain("SECOND-FILE-LINE");
    expect(host.textContent).not.toContain("FIRST-FILE-LINE");
  });

  it("counts the whole comparison, not only the file on screen", () => {
    const host = mount(<ChangesViewer diff={two} />);
    expect(host.textContent).toContain("+2");
  });

  // The control: a comparison that found nothing says so, rather than
  // drawing an empty tree beside an empty pane.
  it("says two sides are identical when nothing changed", () => {
    const host = mount(<ChangesViewer diff={diff([])} />);
    expect(host.textContent).toBe(NO_CHANGES_NOTE);
  });
});
