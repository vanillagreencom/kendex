import { create } from "zustand";
import {
  type Appearance,
  type AppSettings,
  type CapabilityRow,
  type CommitOffer,
  commands,
  type SettingsRead,
  ZOOM,
} from "@/bindings";
import { refusalKind, refusalWords } from "@/lib/refusal";
import { rescanEverything } from "@/lib/rescan";
import { useProblemsStore } from "./problems";
import { type ProjectsSlice, projectActions } from "./settings-projects";
import { type ZoomSlice, zoomActions } from "./settings-zoom";

interface SettingsState extends ZoomSlice, ProjectsSlice {
  settings: AppSettings | null;
  /** What the settings file was when `settings` was read from it — sent
   *  back with every whole-settings write, so a copy of a file something
   *  else has since written is refused instead of putting the older file
   *  back over it. */
  base: string | null;
  capabilities: CapabilityRow[];
  load: () => Promise<void>;
  /** The settings file alone, read again.
   *
   *  The file is machine-local and two programs write it: this window, and
   *  the CLI, which registers the project a `kendex add` installed into.
   *  So a window that has been away can be looking at a registry that has
   *  since gained a project, and the Projects page would go on drawing the
   *  old list until the app was restarted.
   *
   *  Only the file. [`load`] also reads the capability table and asks the
   *  window what size it opened at, and it reports a launch that would not
   *  take the saved zoom — a session-long fact, so running that again on
   *  every focus would re-open a dialog about a launch the person has
   *  already answered for.
   *
   *  Nothing unsaved is lost to it: the reply is held under the store's own
   *  ticket order, so a write issued after this read landed first keeps the
   *  file it wrote, and this reply is dropped as the older view it is. */
  reload: () => Promise<void>;
  setAppearance: (appearance: Appearance) => Promise<void>;
  setCommitOffer: (commitOffer: CommitOffer) => Promise<void>;
  setHarnessRoot: (harness: string, root: string) => Promise<void>;
}

type WriteOutcome = { ok: true } | { ok: false; message: string };

export const useSettingsStore = create<SettingsState>((set, get) => {
  // The backend serializes the writes; the replies arrive in any order. A
  // ticket taken as each request leaves orders them again on arrival: a
  // reply whose ticket predates the newest one held is a view of the file
  // something newer has already replaced, and holding it would walk the
  // store backwards until the next reload.
  let issued = 0;
  let newest = 0;
  const ticket = () => ++issued;

  /** Keep the copy and its base together — one never moves without the
   *  other, or the next save would present a base for bytes it does not
   *  hold. Held only while `at` is the newest ticket seen: an older
   *  request's late reply is dropped, not applied. */
  const hold = (read: SettingsRead, at: number) => {
    if (at < newest) return;
    newest = at;
    set({ settings: read.settings, base: read.base });
  };

  /** How many writes are still to answer.
   *
   *  The ticket order alone cannot place a read against a write: it orders
   *  by when a request left, and a read that left later can still answer
   *  first — the backend serializes writes under the settings lock, a read
   *  waits on nothing. Its newer ticket then becomes the newest held, and
   *  the write's own reply, carrying the file it had just made, is dropped
   *  as an older view. The person's change is on disk and off the screen.
   *
   *  So a read only speaks for the file while no write is outstanding.
   *  Every write goes through [`writing`]; a read that finds a write still
   *  out keeps the rows it had, and the write's reply is what moves the
   *  store. */
  let writesOutstanding = 0;
  const writing = async <T>(run: () => Promise<T>): Promise<T> => {
    writesOutstanding += 1;
    try {
      return await run();
    } finally {
      writesOutstanding -= 1;
    }
  };

  /** One change, written as the whole file with the base its copy was read
   *  from. A stale refusal means something else wrote the file since the
   *  copy was read — a resize, another window. The change is a field-level
   *  intent, so it is carried onto a freshly read copy and written once
   *  more; that reverts nothing, because the fresh copy holds everything
   *  the stale one predated. Only a second refusal reaches the person. */
  const write = (
    change: (current: AppSettings) => AppSettings,
  ): Promise<WriteOutcome> => writing(() => writeOnce(change));

  const writeOnce = async (
    change: (current: AppSettings) => AppSettings,
  ): Promise<WriteOutcome> => {
    const { settings, base } = get();
    // A write with no copy in hand never happened; reporting it saved
    // would teach a caller to trust a change that was dropped.
    if (!settings)
      return { ok: false, message: "Your settings haven't loaded yet." };
    let at = ticket();
    let response = await commands.updateSettings(change(settings), base);
    if (
      response.status === "error" &&
      refusalKind(response.error) === "stale"
    ) {
      const reread = ticket();
      const fresh = await commands.getSettings();
      // The re-read is the way out of a stale refusal. Failing, the fault
      // to name is the read itself — the contention wording would send
      // the person retrying a path that cannot progress, and would claim
      // a refresh that never happened.
      if (fresh.status === "error")
        return {
          ok: false,
          message: `Couldn't re-read your settings to retry: ${fresh.error}`,
        };
      hold(fresh.data, reread);
      at = ticket();
      response = await commands.updateSettings(
        change(fresh.data.settings),
        fresh.data.base,
      );
    }
    if (response.status === "ok") {
      hold(response.data, at);
      return { ok: true };
    }
    const said = refusalWords(response.error);
    if (said !== null) return { ok: false, message: said };
    // A second stale refusal means the file moved again after the re-read,
    // so the copy in hand is behind it. One read-only refresh earns the
    // claim that the latest settings are shown; when even that read fails,
    // the claim goes with it.
    const refresh = ticket();
    const last = await commands.getSettings();
    if (last.status === "ok") {
      hold(last.data, refresh);
      return {
        ok: false,
        message:
          "Your settings changed in another window while this was saving. The change wasn't applied — the latest settings are shown now.",
      };
    }
    return {
      ok: false,
      message: `Your settings changed in another window while this was saving. The change wasn't applied, and re-reading the file failed: ${last.error}`,
    };
  };

  // Registering and dropping a project are writes of this file like any
  // other, so a read must not outrank one still in flight. Wrapped here
  // rather than inside the slice: the outstanding count belongs to the
  // store that owns the ticket order, and the slice keeps its signature.
  const projects = projectActions({ ticket, hold });

  return {
    settings: null,
    base: null,
    capabilities: [],
    ...zoomActions(set, get),
    ...projects,
    registerProject: (path) => writing(() => projects.registerProject(path)),
    unregisterProject: (path) =>
      writing(() => projects.unregisterProject(path)),

    load: async () => {
      // The size comes from the window, not from the file: the file holds
      // what the person asked for, and the zoom outlives the page, so a page
      // that has just reloaded is the one least able to work it out itself.
      const at = ticket();
      const [settings, capabilities, webview] = await Promise.all([
        commands.getSettings(),
        commands.capabilityTable(),
        commands.windowZoomState(),
      ]);
      // All three or none. The page gates its actions on the capability
      // table and draws its slider from the window, so one built out of
      // whichever two answered would be a page quietly claiming it can do
      // things it cannot. A read that failed is the transport rather than
      // anything any of the three refuses, and to the person it is the one
      // page that would not load — so it is said in one set of words.
      const couldNotLoad = (message: string) =>
        useProblemsStore.getState().showError({
          title: "Couldn't load your settings",
          message,
          steps: ["Try again", "If it keeps happening, restart kendex"],
          actions: [{ label: "Retry", onClick: () => void get().load() }],
        });
      if (settings.status === "error") return couldNotLoad(settings.error);
      if (capabilities.status === "error")
        return couldNotLoad(capabilities.error);
      if (webview.status === "error") return couldNotLoad(webview.error);

      hold(settings.data, at);
      set({ capabilities: capabilities.data, zoom: webview.data.percent });
      // The opening had no UI to say this in, so it is said here rather
      // than leaving the person with an app that quietly ignored their
      // size. Both halves are needed: the refusal stands for the whole
      // session, so on its own it would go on complaining after a resize
      // put the person back where they wanted to be.
      const asked = settings.data.settings.zoom ?? ZOOM.default;
      if (webview.data.launchRefused && webview.data.percent !== asked) {
        useProblemsStore.getState().showError({
          title: "Couldn't open at your saved zoom",
          message: `kendex is at ${webview.data.percent}% instead of the ${asked}% you saved. Your saved zoom is unchanged.`,
          steps: ["Try again", "If it keeps happening, restart kendex"],
          actions: [
            { label: "Retry", onClick: () => void get().setZoom(asked) },
          ],
        });
      }
    },

    reload: async () => {
      const at = ticket();
      const settings = await commands.getSettings();
      // A read that failed answers for nothing: the rows in hand stay,
      // and the next focus tries again. Nothing on screen is waiting on
      // it, so there is no one to tell.
      if (settings.status !== "ok") return;
      // Nor does a read speak while a write is still to answer. A read
      // waits on nothing and a write waits on the settings lock, so this
      // one can be a view of the file from before a save the person has
      // already made — and its newer ticket would drop that save's own
      // reply. The write is what moves the store; the next focus reads
      // again.
      if (writesOutstanding > 0) return;
      hold(settings.data, at);
    },

    // Theme and tool folder saves are instant and their
    // effect is visible immediately on screen — a toast on top would just be
    // noise, so success here stays silent and only failure speaks up.
    setAppearance: async (appearance) => {
      const result = await write((current) => ({ ...current, appearance }));
      if (!result.ok)
        useProblemsStore.getState().showError({
          title: "Couldn't change the appearance",
          message: result.message,
          steps: ["Try again"],
          actions: [
            {
              label: "Retry",
              onClick: () => void get().setAppearance(appearance),
            },
          ],
        });
    },

    // Whether kendex asks is machine-local and takes effect on the next
    // write; nothing on screen changes with it, so only a failure speaks.
    setCommitOffer: async (commitOffer) => {
      const result = await write((current) => ({
        ...current,
        "commit-offer": commitOffer,
      }));
      if (!result.ok)
        useProblemsStore.getState().showError({
          title: "Couldn't change the commit offer",
          message: result.message,
          steps: ["Try again"],
          actions: [
            {
              label: "Retry",
              onClick: () => void get().setCommitOffer(commitOffer),
            },
          ],
        });
    },

    setHarnessRoot: async (harness, root) => {
      const result = await write((current) => {
        const roots = { ...current["harness-roots"] };
        if (root.trim() === "") delete roots[harness];
        else roots[harness] = root;
        return { ...current, "harness-roots": roots };
      });
      if (result.ok) {
        await rescanEverything();
      } else {
        useProblemsStore.getState().showError({
          title: "Couldn't update the tool folder",
          message: result.message,
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
  };
});
