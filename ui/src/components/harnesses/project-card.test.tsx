// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { PLACE_UNCHECKED_LABEL } from "@/lib/copy";
import { ProjectCard } from "./project-card";

// Static markup escapes apostrophes, so copy carrying one is escaped the
// same way before it is looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

const render = (
  over: {
    unmanaged?: number | null;
    badge?: { text: string; variant: "destructive" | "info"; title?: string };
  } = {},
) =>
  renderToStaticMarkup(
    <ProjectCard
      name="acme"
      subtitle="/work/acme"
      counts={[["skill", 3]]}
      emptyLabel="Nothing from kendex yet."
      onOpen={() => {}}
      onKindClick={() => {}}
      onUnmanaged={() => {}}
      {...over}
    />,
  );

describe("a place's card", () => {
  it("distinguishes unmanaged counts from an unchecked place", () => {
    const rows = [
      {
        name: "unmanaged items",
        value: 4,
        present: ["3 Skills", "4 not managed yet"],
        absent: [],
      },
      {
        name: "nothing unmanaged",
        value: 0,
        present: [],
        absent: ["not managed"],
      },
      {
        name: "no unmanaged answer",
        value: undefined,
        present: [],
        absent: ["not managed"],
      },
      {
        name: "unchecked",
        value: null,
        present: [esc(PLACE_UNCHECKED_LABEL), "3 Skills"],
        absent: ["not managed yet"],
      },
    ];
    expect(rows).toHaveLength(4);
    for (const entry of rows) {
      const html = render({ unmanaged: entry.value });
      expect(
        {
          present: entry.present.filter((text) => html.includes(text)),
          forbidden: entry.absent.filter((text) => html.includes(text)),
        },
        entry.name,
      ).toEqual({ present: entry.present, forbidden: [] });
      if (entry.value === null) {
        const document = new DOMParser().parseFromString(html, "text/html");
        const note = [...document.querySelectorAll("span")].find(
          (node) => node.textContent === PLACE_UNCHECKED_LABEL,
        );
        expect(note).toBeDefined();
        expect(note?.closest("button")).toBeNull();
        expect(note?.querySelector("button")).toBeNull();
      }
    }
  });

  // Files kendex wrote and could not offer to commit are not a fault, so
  // the badge carries its own variant, and the reason rides on hover.
  it("flags uncommitted files quietly, with the reason on hover", () => {
    const html = render({
      badge: {
        text: "12 uncommitted",
        variant: "info",
        title:
          "12 files kendex wrote are not committed. This checkout is on no branch.",
      },
    });
    expect(html).toContain("12 uncommitted");
    expect(html).toContain(
      'title="12 files kendex wrote are not committed. This checkout is on no branch."',
    );
    expect(html).not.toContain("bg-destructive");
  });

  it("still flags a missing folder as a fault", () => {
    const html = render({
      badge: { text: "Folder not found", variant: "destructive" },
    });
    expect(html).toContain("Folder not found");
    expect(html).toContain("bg-destructive");
  });
});
