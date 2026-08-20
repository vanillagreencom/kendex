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
  // What the window is showing, which is what a refusal falls back to. With
  // no resize outstanding the store agrees with the window, so this is read
  // back from it then; while resizes are in flight the store is running
  // ahead and only a reply can move this.
  let showing: number = ZOOM.default;
  let outstanding = 0;

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

  /** Why the window did not take the size, or null when it did. A bridge
   *  that throws and a reply that says no are the same answer here: the
   *  window is not showing what the store says it is. */
  async function refused(percent: number): Promise<string | null> {
    try {
      const shown = await commands.windowSetZoom(percent);
      return shown.status === "ok" ? null : shown.error;
    } catch (error: unknown) {
      return String(error);
    }
  }

  async function resize(percent: number) {
    const before = get().settings;
    if (!before || before.zoom === percent) return;
    if (outstanding === 0) showing = before.zoom ?? ZOOM.default;
    outstanding += 1;
    showZoom(percent);
    const problem = await refused(percent);
    outstanding -= 1;
    if (problem === null) {
      showing = percent;
      return;
    }
    // A size the window did not take is not offered to the settings file,
    // and putting back what it is showing is what keeps the commit from
    // writing it. Read now, not when this call started: with two presses in
    // flight the size the store had then is the other press's, which the
    // window may be about to refuse as well, and an earlier press may have
    // been accepted since. Only if nothing newer has landed meanwhile —
    // this reply can already be about a step the person has pressed past.
    if (get().settings?.zoom === percent) showZoom(showing);
    report("Couldn't change the zoom", problem, () => void retry(percent));
  }

  function setZoom(percent: number): Promise<void> {
    // Joined, not replaced: a repeat of the size already on screen returns
    // at once, and replacing would drop the earlier resize still in flight
    // from what the commit waits for.
    const run = resize(percent).catch((error: unknown) => {
      report(
        "Couldn't change the zoom",
        String(error),
        () => void retry(percent),
      );
    });
    resizing = Promise.all([resizing, run]).then(() => {});
    return run;
  }

  /** A retry has to store what it manages to show: an accepted second try
   *  that nothing writes is gone again on the next launch. */
  async function retry(percent: number) {
    await setZoom(percent);
    await saveZoom();
  }

  async function write() {
    try {
      // The size on screen is settled only once every resize has replied.
      // `resizing` is a closure variable `setZoom` reassigns, and awaiting
      // it hands control back, which is exactly when a new resize can start
      // — so the identity check asks again until nothing new began while we
      // waited. It terminates because every caller arrives through a settle
      // timer that has already outlasted the input stream; wire `saveZoom`
      // to something that fires mid-drag and this becomes an unbounded wait
      // holding the one-save-at-a-time slot.
      let awaited: Promise<void>;
      do {
        awaited = resizing;
        await awaited;
      } while (resizing !== awaited);

      const current = get().settings;
      if (!current) return;
      const percent = current.zoom ?? ZOOM.default;
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
