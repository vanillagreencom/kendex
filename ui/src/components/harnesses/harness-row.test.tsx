// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { harnessName } from "@/lib/labels";
import { showEverythingLabel } from "@/lib/show-everything-label";
import { useNavStore } from "@/stores/nav";
import { HarnessRow } from "./harness-row";

// The nav store is the real one — whether a click lands the Library on the
// right view is exactly what these tests ask — so each test starts from a
// page that is not the Library and no pending filter.
const navHome = { page: "home" as const, libraryFilter: null };

const mounted: Root[] = [];
afterEach(() => {
  act(() => {
    for (const root of mounted) root.unmount();
  });
  mounted.length = 0;
  document.body.replaceChildren();
});

const mount = (detectedRoot: string | null) => {
  useNavStore.setState(navHome);
  const host = document.body.appendChild(document.createElement("div"));
  const root = createRoot(host);
  mounted.push(root);
  act(() =>
    root.render(
      <HarnessRow
        id="claude"
        detectedRoot={detectedRoot}
        version={null}
        counts={[["skill", 3]]}
        folder=""
        onFolderChange={() => {}}
      />,
    ),
  );
  return host;
};

const label = showEverythingLabel(harnessName("claude"));

describe("the harness row's name", () => {
  it("opens the Library scoped to this harness, with no kind picked", async () => {
    const host = mount("/home/u/.claude");
    // Queried by accessible name, so the label sitting anywhere but the
    // name button fails here too.
    const name = host.querySelector<HTMLButtonElement>(
      `button[aria-label="${label}"]`,
    );
    if (!name) throw new Error("no show-everything button rendered");
    expect(name.textContent).toBe("Claude Code");

    await userEvent.click(name);
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter?.harness).toBe("claude");
    expect(nav.libraryFilter?.kind).toBeUndefined();
    expect(nav.libraryFilter?.scope).toBeUndefined();
  });

  // One phrase for one affordance: the project card announces its name
  // button with the same helper, and a harness row drifting to its own
  // wording would make the same control read as two different ones.
  it("announces itself with the project card's label", () => {
    expect(label).toBe("Show everything in Claude Code");
  });

  it("offers nothing to show for a harness that is not installed", () => {
    const host = mount(null);
    expect(host.querySelector(`button[aria-label="${label}"]`)).toBeNull();
    const named = Array.from(host.querySelectorAll("button")).filter(
      (b) => b.textContent === "Claude Code",
    );
    expect(named).toEqual([]);
    expect(useNavStore.getState().page).toBe("home");
  });
});
