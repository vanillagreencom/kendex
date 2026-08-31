import { toast } from "sonner";
import { create } from "zustand";
import {
  type Appearance,
  type AppSettings,
  type CapabilityRow,
  commands,
  type SettingsRead,
  ZOOM,
} from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { useProblemsStore } from "./problems";
import { type ZoomSlice, zoomActions } from "./settings-zoom";

interface ProjectFields {
  settings: AppSettings | null;
}

interface ProjectsSlice {
  registerProject: (path: string) => Promise<boolean>;
  unregisterProject: (path: string) => Promise<void>;
  discoverProjects: (root: string) => Promise<string[]>;
}

/** The project registry's actions. Registration and removal are targeted
 *  server-side writes, so they carry no base — but each reply is a written
 *  settings-plus-base pair, and holding it keeps the store's copy current
 *  for the next whole-file save. The hold comes from the store so every
 *  settings-holding reply shares one ticket order: a reply older than the
 *  newest one held is dropped, wherever it came from. */
function projectActions(
  get: () => ProjectFields,
  ordered: {
    ticket: () => number;
    hold: (read: SettingsRead, at: number) => void;
  },
): ProjectsSlice {
  return {
    registerProject: async (path) => {
      const before = get().settings?.projects ?? [];
      const at = ordered.ticket();
      const response = await commands.registerProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        // Registration is where the drift report is offered: agents in this
        // project start blind until the session-start hook is installed. An
        // offer, never an auto-install — it injects into agent context.
        const root =
          (response.data.settings.projects ?? []).find(
            (p) => !before.includes(p),
          ) ?? path;
        toast.success(`Added ${path.split("/").pop()}`, {
          action: {
            label: "Add session drift report",
            onClick: () => {
              void commands
                .installDriftHook({ scope: "project", root })
                .then((result) => {
                  if (result.status === "ok") {
                    // False: the scope had other pending changes, so only the
                    // declaration landed — nothing is applied unseen.
                    toast.success(
                      result.data
                        ? "Drift report installed"
                        : "Drift report added — run kendex apply in that project to install it",
                    );
                    void rescanEverything();
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
        await rescanEverything();
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
      const at = ordered.ticket();
      const response = await commands.unregisterProject(path);
      if (response.status === "ok") {
        ordered.hold(response.data, at);
        await rescanEverything();
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
  };
}

interface SettingsState extends ZoomSlice, ProjectsSlice {
  settings: AppSettings | null;
  /** What the settings file was when `settings` was read from it — sent
   *  back with every whole-settings write, so a copy of a file something
   *  else has since written is refused instead of putting the older file
   *  back over it. */
  base: string | null;
  capabilities: CapabilityRow[];
  load: () => Promise<void>;
  setAppearance: (appearance: Appearance) => Promise<void>;
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

  /** One change, written as the whole file with the base its copy was read
   *  from. A stale refusal means something else wrote the file since the
   *  copy was read — a resize, another window. The change is a field-level
   *  intent, so it is carried onto a freshly read copy and written once
   *  more; that reverts nothing, because the fresh copy holds everything
   *  the stale one predated. Only a second refusal reaches the person. */
  const write = async (
    change: (current: AppSettings) => AppSettings,
  ): Promise<WriteOutcome> => {
    const { settings, base } = get();
    // A write with no copy in hand never happened; reporting it saved
    // would teach a caller to trust a change that was dropped.
    if (!settings)
      return { ok: false, message: "Your settings haven't loaded yet." };
    let at = ticket();
    let response = await commands.updateSettings(change(settings), base);
    if (response.status === "error" && response.error.kind === "stale") {
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
    if (response.error.kind === "failed")
      return { ok: false, message: response.error.message };
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

  return {
    settings: null,
    base: null,
    capabilities: [],
    ...zoomActions(set, get),
    ...projectActions(get, { ticket, hold }),

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
      if (settings.status === "ok") {
        hold(settings.data, at);
        set({ capabilities, zoom: webview.percent });
        // The opening had no UI to say this in, so it is said here rather
        // than leaving the person with an app that quietly ignored their
        // size. Both halves are needed: the refusal stands for the whole
        // session, so on its own it would go on complaining after a resize
        // put the person back where they wanted to be.
        const asked = settings.data.settings.zoom ?? ZOOM.default;
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
