import { expect, vi } from "vitest";
import type { AppSettings, SettingsRead, WriteRefused } from "@/bindings";
import { commands } from "@/bindings";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { currentZoom } from "./zoom";

/** Shared by the two zoom suites: the same store, mocked the same way. Each
 *  suite still declares its own `vi.mock`, which vitest hoists per file. */
export const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

export type Reply =
  | { status: "ok"; data: SettingsRead }
  | { status: "error"; error: WriteRefused };
export type WindowReply =
  | { status: "ok"; data: null }
  | { status: "error"; error: string };
export type ZoomReply =
  | { status: "ok"; data: number }
  | { status: "error"; error: string };

export const ok = <T>(data: T) => ({ status: "ok" as const, data });
export const failed = (error: string) => ({ status: "error" as const, error });

/** Let everything already queued run before carrying on. */
export const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A promise whose settling the test decides. */
export function deferred<T>() {
  let settle: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });
  return { promise, settle };
}

/** What the app is showing, which a press moves ahead of the window. */
export const zoom = () => currentZoom();
/** What a save would carry: the size the shared settings object holds. */
export const stored = () => useSettingsStore.getState().settings?.zoom;
export const dialog = () => useProblemsStore.getState().dialog;

/** The size the stand-in webview is at. It keeps its own, the way the real
 *  one does: the zoom outlives the page, so a reload has to read it back. */
let webviewAt = settings.zoom ?? 100;

/** Put the stand-in webview at a size, as a launch or an accepted resize
 *  would. A test that seeds the store away from full size moves the window
 *  with it — the store's copy is what is being drawn, and the window is
 *  what a refusal reads the real size back from. */
export function windowAt(percent: number) {
  webviewAt = percent;
}

/** A window that takes every size it is asked for, and remembers it. */
export function windowTakes() {
  vi.mocked(commands.windowSetZoom).mockImplementation(async (percent) => {
    webviewAt = percent;
    return ok(null);
  });
}

/** One resize the test settles by hand, with a stand-in window that moves
 *  when the reply lands rather than when the call is made.
 *
 *  The distinction is the whole of the commit boundary. A window already at
 *  the new size answers `showing()` with it whether or not the commit
 *  waited for the resize, so a fixture that moves at call time cannot tell
 *  a commit that waits from one that does not. */
export function pendingResize(percent: number) {
  const out = deferred<WindowReply>();
  vi.mocked(commands.windowSetZoom).mockReturnValueOnce(out.promise);
  return {
    /** The window takes the size, and is at it from here on. */
    takes: () => {
      windowAt(percent);
      out.settle(ok(null));
    },
    /** The window refuses, and stays where it was. */
    refuses: (why: string) => out.settle(failed(why)),
  };
}

/** A store at 100%, a closed dialog, and a window that takes every size —
 *  including at launch, so the store opens where the stored size is. */
export function freshZoomStore() {
  webviewAt = settings.zoom ?? 100;
  useSettingsStore.setState({
    settings,
    zoom: webviewAt,
    capabilities: [],
  });
  useProblemsStore.setState({
    dialog: { open: false, title: "", steps: [], actions: [] },
  });
  vi.clearAllMocks();
  windowTakes();
  vi.mocked(commands.windowZoomState).mockImplementation(async () => ({
    percent: webviewAt,
    launchRefused: false,
  }));
  vi.mocked(commands.updateSettings).mockImplementation(async (next, base) =>
    ok({ settings: next, base }),
  );
  vi.mocked(commands.saveZoom).mockImplementation(async (percent) =>
    ok(percent),
  );
  expect(zoom()).toBe(100);
}
