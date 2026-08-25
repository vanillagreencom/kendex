import { toast } from "sonner";
import { create } from "zustand";
import {
  type Appearance,
  type AppSettings,
  type CapabilityRow,
  commands,
  ZOOM,
} from "@/bindings";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

interface ZoomFields {
  settings: AppSettings | null;
  shownZoom: number | null;
  tookZoom: number | null;
}

interface ZoomSlice {
  /**
   * The size on screen while it is ahead of the window. A press shows at
   * once and the window is asked afterwards, so until the reply lands this
   * is a size nothing has confirmed — and it stays out of `settings` for
   * exactly that reason: every other settings action writes the whole
   * object, so one that ran now would faithfully persist a size the window
   * may be about to refuse.
   *
   * Null until the first press, when the window is showing the size it
   * last confirmed. Readers want `onScreen()`.
   */
  shownZoom: number | null;
  /**
   * The size the window has taken, and the only size ever written. What the
   * settings object says is not evidence of this: it holds the size the
   * person asked for, which survives a session the window would not honour
   * it in, and every settings action replies with the whole file, so a
   * reply read before the person last resized puts an older size back. Only
   * the window moves this, so nothing else can undo a resize.
   *
   * Seeded at load from the size the launch actually opened at.
   */
  tookZoom: number | null;
  /** The size the app is showing, which a press moves ahead of the window. */
  onScreen: () => number;
  /** Resize the window to follow the input. Nothing is written. */
  setZoom: (percent: number) => Promise<void>;
  /** The commit boundary: remember the size now on screen. */
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
function zoomActions(
  set: (fields: Partial<ZoomFields>) => void,
  get: () => ZoomFields,
): ZoomSlice {
  // At most one save in flight. Two overlapping writes of one file race each
  // other, and their replies can land in the wrong order and put back a size
  // the person has already moved past.
  let saving: Promise<void> | null = null;
  let again = false;
  // One request to the window at a time, each queued behind the last, so
  // there is never a second reply to interleave with: a queue removes the
  // orderings rather than reconciling them. The commit waits on the tail of
  // this, so a size the window refused cannot reach the file.
  let asking: Promise<void> = Promise.resolve();

  function report(title: string, message: string, retry: () => void) {
    useProblemsStore.getState().showError({
      title,
      message,
      steps: ["Try again"],
      actions: [{ label: "Retry", onClick: retry }],
    });
  }

  /** The size the window has taken. The launch reports what it opened at,
   *  so this is true from the first frame — including when the window
   *  refused the stored size and full size is what is really on screen. */
  function confirmedZoom(): number {
    return get().tookZoom ?? ZOOM.default;
  }

  /** The size the app is showing, which a press moves ahead of the window. */
  function onScreen(): number {
    return get().shownZoom ?? confirmedZoom();
  }

  /** Show a size the window has not answered for. Nowhere that writes the
   *  settings file reads this, which is what keeps an unanswered size from
   *  being persisted by an unrelated save. */
  function preview(percent: number) {
    set({ shownZoom: percent });
  }

  /** Take the size the file now holds into the settings object — the size
   *  and nothing else, so a change made to another setting while the write
   *  was in flight survives it. */
  function storedZoom(percent: number) {
    const current = get().settings;
    if (current) set({ settings: { ...current, zoom: percent } });
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

  /// Its turn in the queue: ask the window, and put the display back if it
  /// says no.
  async function ask(percent: number) {
    const problem = await refused(percent);
    if (problem === null) {
      set({ tookZoom: percent });
      return;
    }
    // A size the window did not take is not the size the app is showing, so
    // put the display back. Only if nothing newer has landed meanwhile: a
    // press made while this one waited its turn has already moved past it.
    if (get().shownZoom === percent) preview(confirmedZoom());
    report("Couldn't change the zoom", problem, () => void retry(percent));
  }

  function setZoom(percent: number): Promise<void> {
    if (!get().settings || onScreen() === percent) return Promise.resolve();
    // The size shows at once and the window is asked in turn, so a second
    // press reads a display that has already moved and cannot collapse into
    // the first.
    preview(percent);
    const run = asking
      .then(() => ask(percent))
      .catch((error: unknown) => {
        report(
          "Couldn't change the zoom",
          String(error),
          () => void retry(percent),
        );
      });
    asking = run;
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
      // The size on screen is settled only once the queue has drained.
      // `asking` is a closure variable `setZoom` reassigns, and awaiting it
      // hands control back, which is exactly when a new press can join — so
      // the identity check asks again until nothing new arrived while we
      // waited. It terminates because every caller comes through a settle
      // timer that has already outlasted the input stream; wire `saveZoom`
      // to something that fires mid-gesture and this becomes an unbounded
      // wait holding the one-save-at-a-time slot.
      let awaited: Promise<void>;
      do {
        awaited = asking;
        await awaited;
      } while (asking !== awaited);

      // Every request has been answered by now, so this is a size the
      // window took — never one it refused or has not seen. It goes to the
      // file on its own: a whole-settings write would carry fields read
      // before this size was chosen, and would be carrying them back.
      if (!get().settings) return;
      const response = await commands.saveZoom(confirmedZoom());
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

  return { shownZoom: null, tookZoom: null, onScreen, setZoom, saveZoom };
}

interface SettingsState extends ZoomSlice {
  settings: AppSettings | null;
  capabilities: CapabilityRow[];
  load: () => Promise<void>;
  setAppearance: (appearance: Appearance) => Promise<void>;
  setSafety: (warnBelow: number, blockBelow: number) => Promise<void>;
  setHarnessRoot: (harness: string, root: string) => Promise<void>;
  registerProject: (path: string) => Promise<boolean>;
  unregisterProject: (path: string) => Promise<void>;
  discoverProjects: (root: string) => Promise<string[]>;
}

async function rescan() {
  await useScanStore.getState().refresh();
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  settings: null,
  capabilities: [],
  ...zoomActions(set, get),

  load: async () => {
    // The size comes from the window, not from the file: the file holds
    // what the person asked for, and the zoom outlives the page, so a page
    // that has just reloaded is the one least able to work it out itself.
    const [settings, capabilities, webview] = await Promise.all([
      commands.getSettings(),
      commands.capabilityTable(),
      commands.windowZoomState(),
    ]);
    if (settings.status === "ok") {
      set({
        settings: settings.data,
        capabilities,
        tookZoom: webview.percent,
      });
      // The opening had no UI to say this in, so it is said here rather
      // than leaving the person with an app that quietly ignored their
      // size. Both halves are needed: the refusal stands for the whole
      // session, so on its own it would go on complaining after a resize
      // put the person back where they wanted to be.
      const asked = settings.data.zoom ?? ZOOM.default;
      if (webview.launchRefused && webview.percent !== asked) {
        useProblemsStore.getState().showError({
          title: "Couldn't open at your saved zoom",
          message: `kendex is at ${webview.percent}% instead of the ${asked}% you saved. Your saved zoom is unchanged.`,
          steps: ["Try again", "If it keeps happening, restart kendex"],
          actions: [
            { label: "Retry", onClick: () => void get().setZoom(asked) },
          ],
        });
      }
    } else {
      useProblemsStore.getState().showError({
        title: "Couldn't load your settings",
        message: settings.error,
        steps: ["Try again", "If it keeps happening, restart kendex"],
        actions: [{ label: "Retry", onClick: () => void get().load() }],
      });
    }
  },

  // Theme, safety threshold, and tool folder saves are instant and their
  // effect is visible immediately on screen — a toast on top would just be
  // noise, so success here stays silent and only failure speaks up.
  setAppearance: async (appearance) => {
    const current = get().settings;
    if (!current) return;
    const response = await commands.updateSettings({ ...current, appearance });
    if (response.status === "ok") set({ settings: response.data });
    else
      useProblemsStore.getState().showError({
        title: "Couldn't change the appearance",
        message: response.error,
        steps: ["Try again"],
        actions: [
          {
            label: "Retry",
            onClick: () => void get().setAppearance(appearance),
          },
        ],
      });
  },

  setSafety: async (warnBelow, blockBelow) => {
    const current = get().settings;
    if (!current) return;
    const response = await commands.updateSettings({
      ...current,
      safety: { "warn-below": warnBelow, "block-below": blockBelow },
    });
    if (response.status === "ok") set({ settings: response.data });
    else
      useProblemsStore.getState().showError({
        title: "Couldn't update safety settings",
        message: response.error,
        steps: ["Try again"],
        actions: [
          {
            label: "Retry",
            onClick: () => void get().setSafety(warnBelow, blockBelow),
          },
        ],
      });
  },

  setHarnessRoot: async (harness, root) => {
    const current = get().settings;
    if (!current) return;
    const roots = { ...current["harness-roots"] };
    if (root.trim() === "") delete roots[harness];
    else roots[harness] = root;
    const response = await commands.updateSettings({
      ...current,
      "harness-roots": roots,
    });
    if (response.status === "ok") {
      set({ settings: response.data });
      await rescan();
    } else {
      useProblemsStore.getState().showError({
        title: "Couldn't update the tool folder",
        message: response.error,
        steps: [
          "Check that the folder exists and kendex can read it",
          "Try again",
        ],
        actions: [
          {
            label: "Retry",
            onClick: () => void get().setHarnessRoot(harness, root),
          },
        ],
      });
    }
  },

  registerProject: async (path) => {
    const before = get().settings?.projects ?? [];
    const response = await commands.registerProject(path);
    if (response.status === "ok") {
      set({ settings: response.data });
      // Registration is where the drift report is offered: agents in this
      // project start blind until the session-start hook is installed. An
      // offer, never an auto-install — it injects into agent context.
      const root =
        (response.data.projects ?? []).find((p) => !before.includes(p)) ?? path;
      toast.success(`Added ${path.split("/").pop()}`, {
        action: {
          label: "Add session drift report",
          onClick: () => {
            void commands
              .installDriftHook({ scope: "project", root })
              .then((result) => {
                if (result.status === "ok") {
                  // False: the scope had other pending changes, so only the
                  // declaration landed — nothing is applied unreviewed.
                  toast.success(
                    result.data
                      ? "Drift report installed"
                      : "Drift report added — finish by applying changes in Review",
                  );
                  void rescan();
                } else {
                  useProblemsStore.getState().showError({
                    title: "Couldn't install the drift report",
                    message: result.error,
                  });
                }
              });
          },
        },
      });
      await rescan();
      return true;
    }
    useProblemsStore.getState().showError({
      title: "Couldn't add the project",
      message: response.error,
      steps: [
        "Check the folder path is correct",
        "Make sure it isn't already added",
      ],
    });
    return false;
  },

  unregisterProject: async (path) => {
    const response = await commands.unregisterProject(path);
    if (response.status === "ok") {
      set({ settings: response.data });
      await rescan();
    } else {
      useProblemsStore.getState().showError({
        title: "Couldn't stop tracking the project",
        message: response.error,
        steps: ["Try again"],
      });
    }
  },

  discoverProjects: async (root) => {
    const response = await commands.discoverProjects(root);
    if (response.status === "ok") return response.data;
    useProblemsStore.getState().showError({
      title: "Couldn't search that folder",
      message: response.error,
      steps: [
        "Check the folder path is correct",
        "Make sure kendex can read it",
      ],
    });
    return [];
  },
}));
