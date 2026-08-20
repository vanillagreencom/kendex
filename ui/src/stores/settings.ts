import { toast } from "sonner";
import { create } from "zustand";
import {
  type Appearance,
  type AppSettings,
  type CapabilityRow,
  commands,
} from "@/bindings";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { type ZoomSlice, zoomActions } from "./settings-zoom";

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
    const [settings, capabilities] = await Promise.all([
      commands.getSettings(),
      commands.capabilityTable(),
    ]);
    if (settings.status === "ok") {
      set({ settings: settings.data, capabilities });
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
