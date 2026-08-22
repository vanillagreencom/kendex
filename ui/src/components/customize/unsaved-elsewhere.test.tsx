import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { UNSAVED_ELSEWHERE_TITLE } from "@/lib/copy-customize";
import { emptyDraft } from "@/lib/editor-draft";
import { UnsavedElsewhere } from "./unsaved-elsewhere";

const A: Scope = { scope: "project", root: "/work/a" };
const B: Scope = { scope: "project", root: "/work/b" };

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what is waiting.
const stub = vi.hoisted(() => ({
  held: {} as Record<string, unknown>,
  saving: false,
  went: [] as unknown[],
  pointed: [] as unknown[],
}));

vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useNavStore.getState(),
      goTo: (page: unknown) => stub.went.push(page),
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useEditorStore.getState(),
      held: stub.held,
      saving: stub.saving,
      setScope: async (scope: unknown) => {
        stub.pointed.push(scope);
      },
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

const waiting = (scope: Scope) => ({ scope, draft: emptyDraft(), base: null });

/** Press the one way back the note renders, wherever it sits in the tree. */
function press(node: unknown): void {
  const element = node as ReactElement<{
    onClick?: () => void;
    children?: unknown;
  }> | null;
  if (!element || typeof element !== "object") return;
  if (element.props?.onClick) {
    element.props.onClick();
    return;
  }
  const children = element.props?.children;
  if (Array.isArray(children)) children.forEach(press);
  else if (children) press(children);
}

beforeEach(() => {
  stub.held = {};
  stub.saving = false;
  stub.went = [];
  stub.pointed = [];
});

// Typing survives a move between places, and a draft nobody can see is the
// same loss one step later — this note is the whole reason carrying beats
// asking, so it has to be on screen and it has to lead back.
describe("typing left at another place", () => {
  it("says nothing when nothing is waiting", () => {
    expect(renderToStaticMarkup(<UnsavedElsewhere />)).toBe("");
  });

  it("names every place holding typing, by its full path", () => {
    stub.held = { "/work/a": waiting(A), "/work/b": waiting(B) };
    const html = renderToStaticMarkup(<UnsavedElsewhere />);
    expect(html).toContain(UNSAVED_ELSEWHERE_TITLE);
    expect(html).toContain("/work/a");
    expect(html).toContain("/work/b");
    // One way back per place, or the note names work it cannot reach.
    expect(html.split("<button").length - 1).toBe(2);
  });

  it("leads to the page that can show a whole manifest", () => {
    stub.held = { "/work/a": waiting(A) };
    // Static markup drops handlers, so the press is taken off the element
    // tree the component builds.
    press(UnsavedElsewhere({}));
    // A package page can only show the slice of a manifest that names its
    // own package, which for a package not installed there is nothing.
    expect(stub.went).toEqual(["customize"]);
    expect(stub.pointed).toEqual([A]);
  });

  it("shuts the ways back while a save is in flight", () => {
    stub.held = { "/work/a": waiting(A) };
    stub.saving = true;
    expect(renderToStaticMarkup(<UnsavedElsewhere />)).toContain(
      ' disabled=""',
    );
  });
});
