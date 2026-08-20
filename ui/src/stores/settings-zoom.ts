import { type AppSettings, commands, ZOOM } from "@/bindings";
import { useProblemsStore } from "./problems";

interface ZoomSlice {
  settings: AppSettings | null;
}

export interface ZoomActions {
  /** Resize the window to follow the input. Nothing is written. */
  setZoom: (percent: number) => Promise<void>;
  /** The commit boundary: remember the size now on screen. */
  saveZoom: () => Promise<void>;
}

/**
 * Zoom is two moves, not one. The window follows every step of a drag or a
 * held key so the control feels live, and the size is written once, when the
 * input settles — a save per step rewrites the whole settings file dozens of
 * times for one gesture.
 */
export function zoomActions(
  set: (slice: ZoomSlice) => void,
  get: () => ZoomSlice,
): ZoomActions {
  // At most one save in flight. Two overlapping writes of one file race each
  // other, and their replies can land in the wrong order and put a size back
  // that the person has already moved past.
  let saving: Promise<void> | null = null;
  let again = false;

  function report(title: string, message: string, retry: () => void) {
    useProblemsStore.getState().showError({
      title,
      message,
      steps: ["Try again"],
      actions: [{ label: "Retry", onClick: retry }],
    });
  }

  async function setZoom(percent: number) {
    const before = get().settings;
    if (!before || before.zoom === percent) return;
    set({ settings: { ...before, zoom: percent } });
    const shown = await commands.windowSetZoom(percent);
    if (shown.status === "ok") return;
    // A size the window refused is not offered to the settings file. Put
    // the old one back only if nothing newer has landed meanwhile: during a
    // drag this reply can already be about a step the person has passed.
    if (get().settings?.zoom === percent) set({ settings: before });
    report(
      "Couldn't change the zoom",
      shown.error,
      () => void setZoom(percent),
    );
  }

  async function write() {
    const current = get().settings;
    if (!current) return;
    const percent = current.zoom ?? ZOOM.default;
    const response = await commands.updateSettings(current);
    if (response.status === "ok") {
      // The reply describes the size that was on screen when the save
      // started; a newer one may have replaced it since.
      if (get().settings?.zoom === percent) set({ settings: response.data });
      return;
    }
    // The size stays on screen: taking it away would cost the person the
    // size they are using to fix the problem the message names.
    report("Couldn't save the zoom", response.error, () => void saveZoom());
  }

  async function saveZoom() {
    if (saving) {
      // One more write follows the one running, and it writes whatever is
      // on screen by then — which covers this ask and any made meanwhile.
      again = true;
      return saving;
    }
    saving = (async () => {
      await write();
      while (again) {
        again = false;
        await write();
      }
    })();
    try {
      await saving;
    } finally {
      saving = null;
    }
  }

  return { setZoom, saveZoom };
}
