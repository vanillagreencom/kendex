// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { HELD_BY_OWNER_NOTE, heldByParentNote } from "@/lib/copy-updates";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { PlaceCells } from "./update-place-cells";

/** Every title the row draws, so a note landing on the wrong control is
 *  not read as the one under test. The Follow switch and the withheld
 *  Update both say why the hold is not this row's to move. */
const titles = (): string[] =>
  [...document.querySelectorAll("[title]")].map(
    (one) => one.getAttribute("title") ?? "",
  );

const render = (extra: Partial<UpdateRow>): string[] => {
  mount(<PlaceCells row={updateRow("gh", null, extra)} among={[]} />, {
    host: "table",
  });
  return titles();
};

beforeEach(() => {
  useUpdatesStore.setState({ busy: false, checking: false });
});

/** The Follow switch says why it is not this row's to flip. The two arms
 *  sit beside each other: a hold a requirement propagated names the
 *  package that propagated it, and a bundle-propagated one does not — the
 *  bundle is where that hold is released. */
describe("the held notes on a derived row", () => {
  it("names the package whose requirement holds the row, on every control", () => {
    const shown = render({
      derived: true,
      pinned: true,
      requiredBy: ["dev"],
      holdOwner: { kind: "parent", name: "dev" },
    });
    expect(shown).toContain(heldByParentNote("dev"));
    expect(shown).not.toContain(HELD_BY_OWNER_NOTE);
  });

  it("names nobody for a bundle-propagated hold", () => {
    const shown = render({
      derived: true,
      pinned: true,
      requiredBy: ["dev"],
      holdOwner: { kind: "parent", name: null },
    });
    expect(shown).toContain(HELD_BY_OWNER_NOTE);
    expect(shown.join(" ")).not.toContain("dev");
  });
});
