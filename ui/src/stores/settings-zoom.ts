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
 *
 * Neither action ever rejects. Both talk to the window over an IPC bridge
 * that throws when the bridge itself fails rather than replying with an
 * error, and every call site here is a fire-and-forget handler where a
 * rejection would reach nobody.
 */
export function zoomActions(
  set: (slice: ZoomSlice) => void,
  get: () => ZoomSlice,
): ZoomActions {
  // At most one save in flight. Two overlapping writes of one file race each
  // other, and their replies can land in the wrong order and put back a size
  // the person has already moved past.
  let saving: Promise<void> | null = null;
  let again = false;
  // The resize a commit has to wait for: a size the window refused must
  // never reach the file, and the refusal can outlive the input that asked.
  let resizing: Promise<void> = Promise.resolve();

  function report(title: string, message: string, retry: () => void) {
    useProblemsStore.getState().showError({
      title,
      message,
      steps: ["Try again"],
      actions: [{ label: "Retry", onClick: retry }],
    });
  }

  /** Change the size and nothing else, so a change made to another setting
   *  while a zoom save was in flight survives this one. */
  function showZoom(percent: number) {
    const current = get().settings;
    if (current) set({ settings: { ...current, zoom: percent } });
  }

  async function resize(percent: number) {
    const before = get().settings;
    if (!before || before.zoom === percent) return;
    showZoom(percent);
    const shown = await commands.windowSetZoom(percent);
    if (shown.status === "ok") return;
    // A size the window refused is not offered to the settings file. Put the
    // old one back only if nothing newer has landed meanwhile: during a drag
    // this reply can already be about a step the person has passed.
    if (get().settings?.zoom === percent) showZoom(before.zoom ?? ZOOM.default);
    report("Couldn't change the zoom", shown.error, () => void retry(percent));
  }

  function setZoom(percent: number): Promise<void> {
    const run = resize(percent).catch((error: unknown) => {
      report(
        "Couldn't change the zoom",
        String(error),
        () => void retry(percent),
      );
    });
    resizing = run;
    return run;
  }

  /** A retry has to store what it manages to show: an accepted second try
   *  that nothing writes is gone again on the next launch. */
  async function retry(percent: number) {
    await setZoom(percent);
    await saveZoom();
  }

  async function write() {
    // The size on screen is settled only once every resize has replied.
    let awaited: Promise<void>;
    do {
      awaited = resizing;
      await awaited;
    } while (resizing !== awaited);

    const current = get().settings;
    if (!current) return;
    const percent = current.zoom ?? ZOOM.default;
    try {
      const response = await commands.updateSettings(current);
      if (response.status === "ok") {
        // The reply describes the size that was on screen when the save
        // started; a newer one may have replaced it since.
        if (get().settings?.zoom === percent) {
          showZoom(response.data.zoom ?? percent);
        }
        return;
      }
      // The size stays on screen: taking it away would cost the person the
      // size they are using to read the message.
      report("Couldn't save the zoom", response.error, () => void saveZoom());
    } catch (error: unknown) {
      report("Couldn't save the zoom", String(error), () => void saveZoom());
    }
  }

  async function saveZoom() {
    if (saving) {
      // One more write follows the one running, and it writes whatever is
      // on screen by then — which covers this ask and any made meanwhile.
      again = true;
      return saving;
    }
    saving = (async () => {
      try {
        await write();
        while (again) {
          again = false;
          await write();
        }
      } finally {
        // Never leave the queue armed: a run that ended early would other-
        // wise make the next save do a second, pointless write forever.
        again = false;
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
