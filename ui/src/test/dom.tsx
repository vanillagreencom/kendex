// The DOM harness for tests that read a zustand store through a component.
//
// `renderToStaticMarkup` is a server render: zustand's `useSyncExternalStore`
// serves the store's initial snapshot, so a test that sets store state and
// then renders sees none of it — and passes, against an empty page. A test
// of store wiring needs a mounted tree, which is what this gives it.
//
// Prop-driven tests stay the default. Reach for this only where the thing
// under test is the wiring itself: which scope a page passes, what a click
// lands on, what a store change puts on screen.
//
// Every file that imports this carries `// @vitest-environment jsdom` on
// its first line — the environment is chosen per file before any import
// runs, so nothing here can choose it.
//
// A base-ui menu trigger does not open on `userEvent.click` under jsdom;
// focus it and press Enter. Tooltips open on focus.
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach } from "vitest";

if (typeof document === "undefined") {
  throw new Error(
    "@/test/dom needs a DOM: put `// @vitest-environment jsdom` on the test file's first line",
  );
}

// React warns, and runs effects late, unless told the test drives it.
(
  globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Root[] = [];

// A popup, tooltip, or menu left open by one test is in the document the
// next one reads: every mount comes down, and the body is emptied, after
// each test in the importing file.
afterEach(() => {
  try {
    act(() => {
      for (const root of mounted) root.unmount();
    });
  } finally {
    // An unmount that throws must not leave its tree, or the list that
    // would throw again, for the next test to fail on.
    mounted.length = 0;
    document.body.replaceChildren();
  }
});

/** Mount a tree into the document and return the element it sits in.
 *
 *  `host` is the element the tree renders into. It defaults to a `div`;
 *  a component that renders a `tr` takes a `table`, so the mounted tree
 *  is the HTML the component was written for rather than a row sitting
 *  under a block. */
export function mount(
  element: ReactNode,
  { host = "div" }: { host?: keyof HTMLElementTagNameMap } = {},
): HTMLElement {
  const container = document.body.appendChild(document.createElement(host));
  const root = createRoot(container);
  mounted.push(root);
  act(() => root.render(element));
  return container;
}

/** Let every effect that awaits a promise land and re-render. A mount
 *  runs effects synchronously, but an effect that calls a mocked command
 *  resolves on the microtask queue, and the state it sets is not on
 *  screen until that has drained. */
export const settle = (): Promise<void> => act(async () => {});

// jsdom lays nothing out and ships no ResizeObserver, so a component that
// sizes itself from its own room gets neither. This is the browser's
// contract filled in: observing an element reports a width at once, as a
// browser does on the first observation, and [roomIs] re-reports it the way
// a resize would. The width starts at zero — what an element that has not
// been laid out reports — so a test that never sets one sees exactly what
// the unmeasured case renders.
const observing = new Map<ResizeObserverCallback, Set<Element>>();
let room = 0;

function report(
  callback: ResizeObserverCallback,
  targets: Iterable<Element>,
): void {
  const entries = [...targets].map(
    (target) =>
      ({
        target,
        contentRect: { width: room, height: 0 } as DOMRectReadOnly,
      }) as ResizeObserverEntry,
  );
  if (entries.length > 0)
    callback(entries, undefined as unknown as ResizeObserver);
}

class StubResizeObserver implements ResizeObserver {
  private readonly targets = new Set<Element>();

  constructor(private readonly callback: ResizeObserverCallback) {
    observing.set(callback, this.targets);
  }

  observe(target: Element): void {
    this.targets.add(target);
    report(this.callback, [target]);
  }

  unobserve(target: Element): void {
    this.targets.delete(target);
  }

  disconnect(): void {
    this.targets.clear();
    observing.delete(this.callback);
  }
}

globalThis.ResizeObserver = StubResizeObserver;

/** Report `width` as the room every observed element has, and tell the
 *  observers, the way a browser does when the window changes size. */
export function roomIs(width: number): void {
  room = width;
  act(() => {
    for (const [callback, targets] of observing) report(callback, targets);
  });
}

afterEach(() => {
  observing.clear();
  room = 0;
});
