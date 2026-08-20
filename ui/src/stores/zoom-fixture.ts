import { expect, vi } from "vitest";
import type { AppSettings } from "@/bindings";
import { commands } from "@/bindings";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { currentZoom } from "./zoom";

/** Shared by the two zoom suites: the same store, mocked the same way. Each
 *  suite still declares its own `vi.mock`, which vitest hoists per file. */
export const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  safety: { "warn-below": 80, "block-below": 60 },
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

export type Reply =
  | { status: "ok"; data: AppSettings }
  | { status: "error"; error: string };
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

/** A store at 100%, a closed dialog, and a window that takes every size. */
export function freshZoomStore() {
  useSettingsStore.setState({
    settings,
    shownZoom: null,
    tookZoom: null,
    capabilities: [],
  });
  useProblemsStore.setState({
    dialog: { open: false, title: "", steps: [], actions: [] },
  });
  vi.clearAllMocks();
  vi.mocked(commands.windowSetZoom).mockResolvedValue(ok(null));
  vi.mocked(commands.updateSettings).mockImplementation(async (next) =>
    ok(next),
  );
  vi.mocked(commands.saveZoom).mockImplementation(async (percent) =>
    ok(percent),
  );
  expect(zoom()).toBe(100);
}
