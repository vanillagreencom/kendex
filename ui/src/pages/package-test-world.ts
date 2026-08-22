import { observedItem } from "@/lib/observed-test-item";

/** The world the package page's rendering tests put it in. Two test files
 *  render the same page against it — what the page is about, and when its
 *  Update button is offered — and a second hand-kept copy of these mocks
 *  would let the two disagree about the page they are both pinning. */

export const VG = { scope: "project", root: "/work/vg" } as const;
export const HYPR = { scope: "project", root: "/work/hyprtrade" } as const;

/** The facts each test moves. `scope` is where the page was opened;
 *  `editorScope` is where the Customize tab happens to point. */
export type PageWorld = {
  scope: unknown;
  editorScope: unknown;
  rows: unknown[];
  saved: Record<string, unknown>;
  held: Record<string, unknown>;
  meta: unknown;
  versions: unknown[];
  /** A newer check on its way, which the Update button waits for. */
  checking: boolean;
};

/** Enough for the Update button to be offered: a newer version exists and
 *  the package's own record was read. */
export const freshWorld = (): PageWorld => ({
  scope: VG,
  editorScope: HYPR,
  rows: [],
  saved: { "/work/vg": {}, "/work/hyprtrade": {} },
  held: {},
  meta: { rev: null, fork: null },
  checking: false,
  versions: [
    {
      id: "b".repeat(40),
      label: "v2",
      date: "2026-08-01",
      summary: "newer",
      installed: false,
      newerThanInstalled: true,
    },
    {
      id: "a".repeat(40),
      label: "v1",
      date: "2026-07-01",
      summary: "installed",
      installed: true,
      newerThanInstalled: false,
    },
  ],
});

/** The same package installed at both places, which is what makes the
 *  question "which place is this page about" answerable at all. */
export const scanned = () => ({
  items: [
    observedItem({ name: "gh", scope: VG, path: "/work/vg/gh" }),
    observedItem({ name: "gh", scope: HYPR, path: "/work/hyprtrade/gh" }),
  ],
});

/** Wrap a store hook so a static render reads these facts instead of the
 *  store's initial snapshot. */
export const stubbed = <S extends { getState: () => object }>(
  store: S,
  patch: () => object,
): S =>
  Object.assign((selector?: (state: unknown) => unknown) => {
    const state = { ...store.getState(), ...patch() };
    return selector ? selector(state) : state;
  }, store) as unknown as S;
