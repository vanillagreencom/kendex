import { type AppSettings, commands, ZOOM } from "@/bindings";
import { useProblemsStore } from "./problems";

export interface ZoomFields {
  settings: AppSettings | null;
  zoom: number | null;
}

export interface ZoomSlice {
  /**
   * The size on screen — one value, because the window is the authority on
   * it and a second copy could only ever disagree. Seeded at load with the
   * size the launch actually opened at, moved ahead by a press so the
   * control feels live, and put back from the window when it refuses one.
   *
   * Deliberately not `settings.zoom`: the file holds the size the person
   * asked for, which survives a session the window would not honour it in,
   * and every settings reply carries the whole file.
   *
   * Null until the first load. Readers want `onScreen()`.
   */
  zoom: number | null;
  /** The size the app is showing, or full size before the first load. */
  onScreen: () => number;
  /** Resize the window to follow the input. Nothing is written. */
  setZoom: (percent: number) => Promise<void>;
  /** The commit boundary: wait for every resize still out, then remember
   *  the size the window says it is at. Never the size on screen, which a
   *  press moves ahead of the window and the window may yet refuse. */
  saveZoom: () => Promise<void>;
}

/**
 * Zoom is two moves, not one. The window follows every step of a held key
 * or a repeatedly clicked button so the control feels live, and the size is
 * written once, when the input settles — a save per step rewrites the whole
 * settings file dozens of times for one gesture.
 *
 * Neither action ever rejects. Both talk to the window over an IPC bridge
 * that throws when the bridge itself fails rather than replying with an
 * error, and every call site here is a fire-and-forget handler where a
 * rejection would reach nobody.
 */
export function zoomActions(
  set: (fields: Partial<ZoomFields>) => void,
  get: () => ZoomFields,
): ZoomSlice {
  // At most one save in flight. Two overlapping writes of one file race each
  // other, and their replies can land in the wrong order and put back a size
  // the person has already moved past.
  let saving: Promise<void> | null = null;
  let again = false;
  // Every resize still out, as one promise. Not a queue — the window takes
  // requests one at a time on its own main thread and nothing here has to
  // order them — but the commit has to wait for them: the display moves
  // ahead of the window on every press, and committing that is committing a
  // size the window may be about to refuse.
  let resizes: Promise<unknown> = Promise.resolve();

  function report(title: string, message: string, retry: () => void) {
    useProblemsStore.getState().showError({
      title,
      message,
      steps: ["Try again"],
      actions: [{ label: "Retry", onClick: retry }],
    });
  }

  function onScreen(): number {
    return get().zoom ?? ZOOM.default;
  }

  /** Take the size the file now holds into the settings object — the size
   *  and nothing else, so a change made to another setting while the write
   *  was in flight survives it. */
  function storedZoom(percent: number) {
    const current = get().settings;
    if (current) set({ settings: { ...current, zoom: percent } });
  }

  /** What the window is showing, asked of the window. Null when even that
   *  could not be read, which is the one case nothing here can correct. */
  async function showing(): Promise<number | null> {
    try {
      return (await commands.windowZoomState()).percent;
    } catch {
      return null;
    }
  }

  /** Why the window did not take the size, or null when it did. A bridge
   *  that throws and a reply that says no are the same answer here: the
   *  window is not showing what the display says it is. */
  async function refused(percent: number): Promise<string | null> {
    try {
      const shown = await commands.windowSetZoom(percent);
      return shown.status === "ok" ? null : shown.error;
    } catch (error: unknown) {
      return String(error);
    }
  }

  function setZoom(percent: number): Promise<void> {
    if (!get().settings || onScreen() === percent) return Promise.resolve();
    // The size shows at once and the window is asked afterwards, so a held
    // key redraws at every step instead of once the last reply lands.
    set({ zoom: percent });
    const run = ask(percent);
    resizes = Promise.all([resizes, run]);
    return run;
  }

  async function ask(percent: number): Promise<void> {
    const problem = await refused(percent);
    if (problem === null) return;
    // A size the window did not take is not the size the app is showing, so
    // the display goes back to what the window says it is at — asked of the
    // window, never guessed. Only while this press is still the one on
    // display: a press made since has already moved past it, and the
    // display belongs to that one.
    if (get().zoom === percent) {
      const shown = await showing();
      if (shown !== null) set({ zoom: shown });
    }
    report("Couldn't change the zoom", problem, () => void retry(percent));
  }

  /** A retry has to store what it manages to show: an accepted second try
   *  that nothing writes is gone again on the next launch. */
  async function retry(percent: number) {
    await setZoom(percent);
    await saveZoom();
  }

  async function write() {
    try {
      if (!get().settings) return;
      // Every resize has to have been answered first. Awaiting hands
      // control back, which is exactly when a new press can join, so the
      // identity check asks again until nothing new arrived while we
      // waited. It terminates because every caller comes through a settle
      // timer that has already outlasted the input stream; wire `saveZoom`
      // to something that fires mid-gesture and this becomes an unbounded
      // wait holding the one-save-at-a-time slot.
      let awaited: Promise<unknown>;
      do {
        awaited = resizes;
        await awaited;
      } while (resizes !== awaited);

      // The size the window is at, asked of the window. The display is
      // where a press put it, and a press the window refused while even the
      // rollback's read failed leaves it ahead of the window — written,
      // that size outlives the session and asks for the same refusal at
      // every launch. The window is the authority on this value, so a run
      // that cannot read it has nothing to write and says so.
      const confirmed = await showing();
      if (confirmed === null) {
        report(
          "Couldn't save the zoom",
          "kendex couldn't read the size the window is at, so it did not write one.",
          () => void saveZoom(),
        );
        return;
      }
      // The rollback that could not run: the display follows the window
      // here too, so the size on screen is the size in the file.
      if (get().zoom !== confirmed) set({ zoom: confirmed });

      // Written on its own: a whole-settings write would carry fields read
      // before this size was chosen, and would be carrying them back.
      const response = await commands.saveZoom(confirmed);
      if (response.status === "ok") {
        storedZoom(response.data);
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
      // One more write follows the one running, and it waits for every
      // resize still out and then asks the window, the way any other does
      // — which covers this ask and any made meanwhile.
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

  return { zoom: null, onScreen, setZoom, saveZoom };
}
